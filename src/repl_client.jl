using ReplMaker
using REPL
using Serialization
using Sockets

using OpenSSH_jll

function connect_via_tunnel(host, port; local_tunnel_port, retry_timeout)
    local_tunnel_port = 27755
    ssh_proc = OpenSSH_jll.ssh() do ssh_exe
        # Tunnel binds locally to 127.0.0.1:$local_tunnel_port
        # The other end jumps through $host using the provided identity,
        # and forwards the data to $port on *itself* (this is the localhost:$port
        # part - "localhost" being resolved relative to $host)
        ssh_cmd = `$ssh_exe -o ExitOnForwardFailure=yes -N -L 127.0.0.1:$local_tunnel_port:localhost:$port $host`
        @debug """Connecting to remote host $host:$port on
                 its internal loopback interface""" ssh_cmd
        ssh_errbuf = IOBuffer()
        ssh_proc = run(pipeline(ssh_cmd, stdout=ssh_errbuf, stderr=ssh_errbuf),
                       wait=false)
        atexit() do
            kill(ssh_proc)
        end
        @async begin
            # Attempt to log any ssh connection errors to the user
            wait(ssh_proc)
            ssh_errors = String(take!(ssh_errbuf))
            if !isempty(ssh_errors) || !success(ssh_proc)
                @warn "SSH tunnel output" ssh_errors=Text(ssh_errors)
            end
        end
        ssh_proc
    end
    # Retry loop to give the SSH server time to come up.
    for i=1:retry_timeout
        try
            return connect(Sockets.localhost, local_tunnel_port)
        catch exc
            if (exc isa Base.IOError) && process_running(ssh_proc) && i < retry_timeout
                sleep(1)
            else
                kill(ssh_proc)
                wait(ssh_proc)
                @error "Exceeded maximum socket connection attempts"
                rethrow()
            end
        end
    end
end

function valid_input_checker(prompt_state)
    ast = Base.parse_input_line(String(take!(copy(REPL.LineEdit.buffer(prompt_state)))),
                                depwarn=false)
    return !Meta.isexpr(ast, :incomplete)
end

struct RemoteCompletionProvider <: REPL.LineEdit.CompletionProvider
    socket
end

function REPL.complete_line(c::RemoteCompletionProvider, state::REPL.LineEdit.PromptState)
    # See REPL.jl complete_line(c::REPLCompletionProvider, s::PromptState)
    partial = REPL.beforecursor(state.input_buffer)
    full = REPL.LineEdit.input_string(state)
    serialize(c.socket, (:repl_completion, (partial, full)))
    messageid, value = deserialize(c.socket)
    if messageid != :completion_result
        @warn "Completion failure" messageid
        return ([], "", false)
    end
    return value
end

function run_remote_repl_command(socket, out_stream, cmdstr)
    ast = Base.parse_input_line(cmdstr, depwarn=false)
    messageid=nothing
    value=nothing
    try
        # See REPL.jl: display(d::REPLDisplay, mime::MIME"text/plain", x)
        display_props = Dict(
            :displaysize=>displaysize(out_stream),
            :color=>get(out_stream, :color, false),
            :limit=>true,
            :module=>Main,
        )
        serialize(socket, (:display_properties, display_props))
        serialize(socket, (:eval, ast))
        flush(socket)
        response = deserialize(socket)
        messageid, value = response isa Tuple && length(response) == 2 ?
                           response : (nothing,nothing)
    catch exc
        if exc isa Base.IOError
            messageid = :error
            value = "IOError - Remote Julia exited or is inaccessible"
        else
            rethrow()
        end
    end
    if messageid == :eval_result || messageid == :error
        if !isnothing(value) && !REPL.ends_with_semicolon(cmdstr)
            println(out_stream, value)
        end
    else
        @error "Unexpected response from server" messageid
    end
end

"""
    connect_repl([host=localhost,] port::Integer=27754;
                 use_ssh_tunnel = (host != localhost))

Connect client REPL to a remote `host` on `port`. This is then accessible as a
remote sub-repl of the current Julia session.

For security, `connect_repl()` uses an ssh tunnel for remote hosts. This means
that `host` needs to be running an ssh server and you need ssh credentials set
up for use on that host. For secure networks this can be disabled by setting
`use_ssh_tunnel=false`.
"""
function connect_repl(host=Sockets.localhost, port::Integer=27754;
                      use_ssh_tunnel::Bool = host!=Sockets.localhost)
    socket = use_ssh_tunnel ?
             connect_via_tunnel(host, port; local_tunnel_port=27755, retry_timeout=5) :
             connect(host, port)

    # TODO: Do an initial handshake to exchange protocol header
    # - magic bytes
    # - protocol version
    # - julia version

    atexit() do
        if isopen(socket)
            serialize(socket, (:exit,nothing))
            flush(socket)
            close(socket)
        end
    end

    out_stream = stdout
    ReplMaker.initrepl(c->run_remote_repl_command(socket, out_stream, c),
                       repl         = Base.active_repl,
                       valid_input_checker = valid_input_checker,
                       prompt_text  = "remote> ",
                       prompt_color = :magenta,
                       start_key    = '>',
                       sticky_mode  = true,
                       mode_name    = "remote_repl",
                       completion_provider = RemoteCompletionProvider(socket)
                       )
                       # startup_text = false)
    nothing
end

connect_repl(port::Integer) = connect_repl(Sockets.localhost, port)

