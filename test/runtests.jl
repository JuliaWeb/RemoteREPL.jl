using RemoteREPL
using Test
using Sockets
using RemoteREPL: repl_prompt_text, DEFAULT_PORT

ENV["JULIA_DEBUG"] = "RemoteREPL"

@testset "Protocol header handshake" begin
    # Happy case
    io = IOBuffer()
    RemoteREPL.send_header(io)
    seek(io, 0)
    @test RemoteREPL.verify_header(io)

    # Broken magic number
    io = IOBuffer()
    write(io, "BrokenMagic", RemoteREPL.PROTOCOL_VERSION)
    seek(io, 0)
    @test_throws ErrorException RemoteREPL.verify_header(io)
    # Version mismatch
    io = IOBuffer()
    write(io, RemoteREPL.PROTOCOL_VERSION, typemax(UInt32))
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

@testset "Prompt text" begin
    function fake_conn(host, port; is_open=true)
        io = IOBuffer()
        is_open || close(io)
        RemoteREPL.Connection(host, port, nothing, nothing, nothing, nothing, io)
    end
    @test repl_prompt_text(fake_conn(Sockets.localhost, DEFAULT_PORT)) == "julia@localhost> "
    @test repl_prompt_text(fake_conn("localhost",       DEFAULT_PORT)) == "julia@localhost> "
    @test repl_prompt_text(fake_conn(ip"192.168.1.1",   DEFAULT_PORT)) == "julia@192.168.1.1> "

    @test repl_prompt_text(fake_conn("ABC", DEFAULT_PORT)) == "julia@ABC> "
    @test repl_prompt_text(fake_conn("ABC", 12345))        == "julia@ABC:12345> "
    @test repl_prompt_text(fake_conn("ABC", DEFAULT_PORT, is_open=false)) == "julia@ABC [disconnected]> "
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
    function runcommand(cmdstr)
        result = RemoteREPL.run_remote_repl_command(conn, IOBuffer(), cmdstr)
        # Unwrap Text for testing purposes
        return result isa Text ? result.content : result
    end

    @test runcommand("asdf = 42") == "42"
    @test runcommand("Main.asdf") == "42"
    @test !isdefined(Main, :asdf) # asdf not defined locally

    # Output Limiting
    @test '⋮' in runcommand("ones(1000)")

    # Error formatting
    @test occursin(r"DivideError.*Stacktrace"s, runcommand("1÷0"))

    # Logging
    @test occursin(r"Info:.*xxx"s, runcommand("""@info "hi" xxx=[1,2]"""))

    # Semicolon suppresses output
    @test isnothing(runcommand("asdf;"))

    # Help mode
    @test occursin("helpmodetest documentation!",
        begin
            runcommand("function helpmodetest end")
            runcommand("@doc \"helpmodetest documentation!\" helpmodetest")
            runcommand("?helpmodetest")
        end)

    # Test the @remote macro
    Main.eval(:(clientside_var = 0:41))
    @test runcommand("serverside_var = 1 .+ @remote clientside_var") == "1:42"
    @test Main.clientside_var == 0:41
    @test @remote(conn, serverside_var) == 1:42
    @test_throws RemoteREPL.RemoteException @remote(conn, error("hi"))

    # Special case handling of stdout
    @test runcommand("println(@remote(stdout), \"hi\")") == "hi\n"

    # Issue #26: world age errors showing output
    @test runcommand("""
        struct A
        end

        Base.show(io::IO, a::A) = print(io, "Surprise")

        A()
        """) == "Surprise"
    @test occursin("Surprise", runcommand("""
        struct MyExc <: Exception
        end

        Base.showerror(io::IO, e::MyExc) = print(io, "Surprise")

        throw(MyExc())
        """))

    # Execute a single command on a separate connection
    @test (RemoteREPL.remote_eval(test_interface, test_port, "asdf")::Text).content == "42"

    # Test interrupts
    # 1. The straightforward reliable way, based on directly sending an
    # interrupt message to the server
    @sync begin
        # Interrupt after 0.5 seconds
        @async begin
            sleep(0.5)
            RemoteREPL.send_interrupt(conn)
        end
        # Remote command which attempts to sleep for 10 seconds and returns the
        # actual time spent sleeping
        @test @remote(conn, (@timed try sleep(10) ; catch ; end).time) < 1
    end
    # 2. Approximately simulate the way that a user-driven ^C gets delivered to
    # the task waiting on the socket
    @sync begin
        task = current_task()
        @async begin
            sleep(0.5)
            schedule(task, InterruptException(), error=true)
        end
        # Remote command which attempts to sleep for 10 seconds and returns the
        # actual time spent sleeping
        @test @remote(conn, (@timed try sleep(10) ; catch ; end).time) < 1
    end
    # 3. Test that we disconnect from the server when trying to interrupt
    #    non-interruptable code
    @sync begin
        task = @async try
            # Execute some non-interruptable code on the server.
            #
            # Normally this would be a compute-heavy task which doesn't yield,
            # but a non-interruptable sleep which catches InterruptException is
            # a more controlled way to simulate this.
            @remote(conn, begin
                t0 = time()
                sleep_time = 5
                while true
                    dt = sleep_time + t0 - time()
                    if dt < 0
                        break
                    end
                    try
                        sleep(dt)
                    catch exc
                        if exc isa InterruptException
                            continue
                        else
                            rethrow()
                        end
                    end
                end
            end)
        catch exc
            exc
        end
        # Three attempts to interrupt will result in the connection being
        # closed to allow the client to recover.
        sleep(0.5)
        schedule(task, InterruptException(), error=true)
        @test !istaskdone(task)
        sleep(0.5)
        schedule(task, InterruptException(), error=true)
        @test !istaskdone(task)
        sleep(0.5)
        schedule(task, InterruptException(), error=true)
        @test fetch(task) == RemoteREPL.RemoteException("ERROR: Failed to interrupt server, connection closed!")
    end
end

finally
    kill(server_proc)
end
