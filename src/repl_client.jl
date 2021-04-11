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

function comm_pipeline(cmd::Cmd)
    errbuf = IOBuffer()
    proc = run(pipeline(cmd, stdout=errbuf, stderr=errbuf),
               wait=false)
    atexit() do
        kill(proc)
    end
    @async begin
        # Attempt to log any connection errors to the user
        wait(proc)
        errors = String(take!(errbuf))
        if !isempty(errors) || !success(proc)
            @warn "Tunnel output" errors=Text(errors)
        end
    end
    proc
end

function ssh_tunnel(host, port, tunnel_interface, tunnel_port; ssh_opts=``)
    OpenSSH_jll.ssh() do ssh_exe
        # Tunnel binds locally to $tunnel_interface:$tunnel_port
        # The other end jumps through $host using the provided identity,
        # and forwards the data to $port on *itself* (this is the localhost:$port
        # part - "localhost" being resolved relative to $host)
        ssh_cmd = `$ssh_exe $ssh_opts -o ExitOnForwardFailure=yes -o ServerAliveInterval=60
                            -N -L $tunnel_interface:$tunnel_port:localhost:$port $host`
        @debug "Connecting SSH tunnel to remote address $host via ssh tunnel to $port" ssh_cmd
        comm_pipeline(ssh_cmd)
    end
end

function aws_tunnel(instance_id, port, tunnel_port; region=nothing)
    region = region === nothing ? `` : `--region $region`
    aws_cmd = `aws ssm start-session $region --target $instance_id --document-name AWS-StartPortForwardingSession --parameters "{\"portNumber\":[\"$port\"],\"localPortNumber\":[\"$tunnel_port\"]}"`
    @debug "Connecting AWS session manager tunnel to EC2 instance $instance_id via port $port" aws_cmd
    comm_pipeline(aws_cmd)
end

function k8s_tunnel(host, port, tunnel_port; namespace=nothing)
    namespace = namespace === nothing ? `` : `-n $namespace`
    k8s_cmd = `kubectl port-forward $namespace $host $tunnel_port:$port`
    @debug "Connecting through kubectl to resource $host via port $port" k8s_cmd
    comm_pipeline(k8s_cmd)
end

function connect_via_tunnel(host, port; retry_timeout,
        tunnel=:ssh, ssh_opts=``, region=nothing, namespace=nothing)
    # We assume the remote server is only listening for local connections.
    tunnel_interface = Sockets.localhost
    tunnel_port = find_free_port(tunnel_interface)
    comm_proc = if tunnel == :ssh
            ssh_tunnel(host, port, tunnel_interface, tunnel_port; ssh_opts=ssh_opts)
        elseif tunnel == :aws
            aws_tunnel(host, port, tunnel_port; region=region)
        elseif tunnel == :k8s
            k8s_tunnel(host, port, tunnel_port; namespace=namespace)
        end

    # Retry loop to wait for the connection.
    for i=1:retry_timeout
        try
            return connect(tunnel_interface, tunnel_port)
        catch exc
            if (exc isa Base.IOError) && process_running(comm_proc) && i < retry_timeout
                sleep(1)
            else
                kill(comm_proc)
                wait(comm_proc)
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
                          tunnel = (host!=Sockets.localhost) ? :ssh : :none,
                          ssh_opts=``, region=nothing, namespace=nothing)
    socket = if tunnel == :none
            connect(host, port)
        else
            connect_via_tunnel(host, port; retry_timeout=5,
                tunnel=tunnel, ssh_opts=ssh_opts, region=region,
                namespace=namespace)
        end

    try
        verify_header(socket)
    catch exc
        close(socket)
        rethrow()
    end

    atexit() do
        close_connection(socket)
    end

    return socket
end

function close_connection(socket)
    if isopen(socket)
        serialize(socket, (:exit,nothing))
        close(socket)
    end
end

"""
    connect_repl([host=localhost,] port::Integer=27754;
                 use_ssh_tunnel = (host != localhost),
                 ssh_opts = ``)

Connect client REPL to a remote `host` on `port`. This is then accessible as a
remote sub-repl of the current Julia session.

For security, `connect_repl()` uses an ssh tunnel for remote hosts. This means
that `host` needs to be running an ssh server and you need ssh credentials set
up for use on that host. For secure networks this can be disabled by setting
`tunnel=:none`.

To provide extra options to SSH, you may use the `ssh_opts` keyword, for example an identity file may be set with  `` ssh_opts = `-i /path/to/identity.pem` ``.
Alternatively, you may want to set this up permanently using a `Host` section in your ssh config file.

You can also use the following technologies for tunneling in place of SSH:
1) AWS Session Manager: set `tunnel=:aws`. The optional `region` keyword argument can be used to specify the AWS Region of your server.
2) kubectl: set `tunnel=:k8s`. The optional `namespace` keyword argument can be used to specify the namespace of your Kubernetes resource.

See README.md for more information.
"""
function connect_repl(host=Sockets.localhost, port::Integer=27754;
                      tunnel::Symbol = host!=Sockets.localhost ? :ssh : :none,
                      ssh_opts=``, region=nothing, namespace=nothing)
    socket = setup_connection(host, port, tunnel=tunnel, ssh_opts=ssh_opts,
                 region=region, namespace=namespace)
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

#-------------------------------------------------------------------------------
"""
    remote_eval(cmdstr)
    remote_eval(host, port, cmdstr)

Parse a string `cmdstr`, evaluate it in the remote REPL server's `Main` module,
then close the connection.

For example, to cause the remote Julia instance to exit, you could use

```
using RemoteREPL
RemoteREPL.remote_eval("exit()")
```
"""
function remote_eval(host, port::Integer, cmdstr::AbstractString;
                     tunnel::Symbol = host!=Sockets.localhost ? :ssh : :none)
    socket = setup_connection(host, port, tunnel=tunnel)
    io = IOBuffer()
    run_remote_repl_command(socket, io, cmdstr)
    close_connection(socket)
    String(take!(io))
end

function remote_eval(cmdstr::AbstractString)
    remote_eval(Sockets.localhost, 27754, cmdstr)
end
