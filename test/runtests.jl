using RemoteREPL
using Test
using Sockets

ENV["JULIA_DEBUG"] = "RemoteREPL"

@testset "Protocol header handshake" begin
    # Happy case
    io = IOBuffer()
    RemoteREPL.send_header(io)
    seek(io, 0)
    @test RemoteREPL.verify_header(io)

    # Broken magic number
    io = IOBuffer()
    write(io, "BrokenMagic", RemoteREPL.protocol_version)
    seek(io, 0)
    @test_throws ErrorException RemoteREPL.verify_header(io)
    # Version mismatch
    io = IOBuffer()
    write(io, RemoteREPL.protocol_version, typemax(UInt32))
    seek(io, 0)
    @test_throws ErrorException RemoteREPL.verify_header(io)

    # ser_version=10 in julia 1.5
    for (local_ver, remote_ver) in [(10,13), (13,10)]
        io = IOBuffer()
        seek(io, 0)
        RemoteREPL.send_header(io, remote_ver)
        @test_throws ErrorException RemoteREPL.verify_header(io, local_ver)
    end
end

# Connect to a non-default loopback address to test SSH integration
test_interface = ip"127.111.111.111"

# Detect whether an ssh server is running on the default port 22
use_ssh = if "use_ssh=true" in ARGS
    true
elseif "use_ssh=false" in ARGS
    false
else
    # Autodetct
    try
        socket = Sockets.connect(test_interface, 22)
        # https://tools.ietf.org/html/rfc4253#section-4.2
        id_string = String(readavailable(socket))
        startswith(id_string, "SSH-")
    catch
        false
    end
end

if !use_ssh
    test_interface = Sockets.localhost
end
@info use_ssh ? "Running tests with SSH tunnel" : "Testing without SSH tunnel - localhost only"

# Use non-default port to avoid clashes with concurrent interactive use or testing.
test_port = RemoteREPL.find_free_port(Sockets.localhost)
server_proc = run(`$(Base.julia_cmd()) -e "using Sockets; using RemoteREPL; serve_repl($test_port)"`, wait=false)

try

@testset "RemoteREPL.jl" begin
    local conn = nothing
    max_tries = 4
    for i=1:max_tries
        try
            conn = RemoteREPL.Connection(host=test_interface, port=test_port,
                                         tunnel=use_ssh ? :ssh : :none,
                                         ssh_opts=`-o StrictHostKeyChecking=no`)
            break
        catch exc
            if i == max_tries
                rethrown()
            end
            # Server not yet started - continue waiting
            sleep(2)
        end
    end
    @assert isopen(conn)

    # Some basic tests of the transport and server side and partial client side.
    #
    # More full testing of the client code would requires some tricky mocking
    # of the REPL environment.
    runcommand(cmdstr) = sprint(io->RemoteREPL.run_remote_repl_command(conn, io, cmdstr))

    @test runcommand("asdf = 42") == "42\n"
    @test runcommand("Main.asdf") == "42\n"
    @test !isdefined(Main, :asdf) # asdf not defined locally

    # Output Limiting
    @test '⋮' in runcommand("ones(1000)")

    # Error formatting
    @test occursin(r"DivideError.*Stacktrace"s, runcommand("1÷0"))

    # Semicolon suppresses output
    @test runcommand("asdf;") == ""

    # Help mode
    @test occursin("helpmodetest documentation!",
        begin
            runcommand("function helpmodetest end")
            runcommand("@doc \"helpmodetest documentation!\" helpmodetest")
            runcommand("?helpmodetest")
        end)

    # Execute a single command on a separate connection
    @test RemoteREPL.remote_eval(test_interface, test_port, "asdf") == "42\n"
end

finally
    kill(server_proc)
end
