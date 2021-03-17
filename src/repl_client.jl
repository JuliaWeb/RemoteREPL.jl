using ReplMaker
using REPL
using Serialization
using Sockets

using OpenSSH_jll

function verify_header(io, ser_version=Serialization.ser_version)
    magic = String(read(io, length(protocol_magic)))
    if magic != protocol_magic
        error("RemoteREPL protocol magic number mismatch: $(repr(magic)) != $(repr(protocol_magic))")
    end
    version = read(io, typeof(protocol_version))
    if version != protocol_version
        error("RemoteREPL protocol version number mismatch: $version != $protocol_version")
    end
    # Version 1: We rely on the standard Serialization library for simplicity;
    # that's backward but not forward compatible depending on
    # Serialization.ser_version, so we check for an exact match
    remote_ser_version = read(io, UInt32)
    if remote_ser_version != ser_version
        error("RemoteREPL Julia Serialization format version mismatch: $remote_ser_version != $ser_version")
    end
    return true
end

# Find a free port on `network_interface`
function find_free_port(network_interface)
    # listen on port 0 => kernel chooses a free port. See, for example,
    # https://stackoverflow.com/questions/44875422/how-to-pick-a-free-port-for-a-subprocess
    server = listen(network_interface, 0)
    _, free_port = getsockname(server)
    close(server)
    # The kernel can reuse free_port here after $some_time_delay, but apprently
    # this is large enough for Selenium to have used this technique for ten
    # years...
    return free_port
end

function connect_via_tunnel(host, port; retry_timeout, ssh_opts)
    # We assume the remote server is only listening for local connections.
    tunnel_interface = Sockets.localhost
    tunnel_port = find_free_port(tunnel_interface)
    ssh_proc = OpenSSH_jll.ssh() do ssh_exe
        # Tunnel binds locally to $tunnel_interface:$tunnel_port
        # The other end jumps through $host using the provided identity,
        # and forwards the data to $port on *itself* (this is the localhost:$port
        # part - "localhost" being resolved relative to $host)
        ssh_cmd = `$ssh_exe $ssh_opts -o ExitOnForwardFailure=yes -o ServerAliveInterval=60
                            -N -L $tunnel_interface:$tunnel_port:localhost:$port $host`
        @debug "Connecting SSH tunnel to remote address $host via ssh tunnel to $port" ssh_cmd
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
            return connect(tunnel_interface, tunnel_port)
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

function setup_connection(host, port;
                          use_ssh_tunnel = (host!=Sockets.localhost),
                          ssh_opts=``)
    socket = use_ssh_tunnel ?
             connect_via_tunnel(host, port; retry_timeout=5, ssh_opts=ssh_opts) :
             connect(host, port)

    try
        verify_header(socket)
    catch exc
        close(socket)
        rethrow()
    end

    atexit() do
        if isopen(socket)
            serialize(socket, (:exit,nothing))
            flush(socket)
            close(socket)
        end
    end

    return socket
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
    socket = setup_connection(host, port, use_ssh_tunnel=use_ssh_tunnel)
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

