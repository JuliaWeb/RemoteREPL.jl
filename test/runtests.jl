using RemoteREPL
using Test
using Sockets

# Use non-default port to avoid clashes with concurrent interactive use or testing.
test_port = RemoteREPL.find_free_port(Sockets.localhost)
server_proc = run(`$(Base.julia_cmd()) -e "using RemoteREPL; serve_repl($test_port)"`, wait=false)

try

@testset "RemoteREPL.jl" begin
    local socket = nothing
    for i=1:10
        try
            socket = connect(Sockets.localhost, test_port)
            break
        catch
            # Server not yet started - continue waiting
            sleep(0.5)
        end
    end
    !isnothing(socket) && isopen(socket) || error("Server didn't come up after polling")

    # Some basic tests of the transport and server side and partial client side.
    #
    # More full testing of the client code would requires some tricky mocking
    # of the REPL environment.
    runcommand(cmdstr) = sprint(io->RemoteREPL.run_remote_repl_command(socket, io, cmdstr))

    @test runcommand("asdf = 42") == "42\n"
    @test runcommand("Main.asdf") == "42\n"
    @test !isdefined(Main, :asdf) # asdf not defined locally

    # Output Limiting
    @test '⋮' in runcommand("ones(1000)")

    # Error formatting
    @test occursin(r"DivideError.*Stacktrace"s, runcommand("1÷0"))

    # Semicolon suppresses output
    @test runcommand("asdf;") == ""
end

finally
    kill(server_proc)
end
