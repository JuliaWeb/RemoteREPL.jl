using ReplMaker
using REPL
using Serialization
using Sockets

# Read and verify header bytes on initializing the connection
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

#-------------------------------------------------------------------------------
# RemoteREPL connection handling and protocol

mutable struct Connection
    host
    port
    tunnel
    ssh_opts
    region
    namespace
    socket
end

function Connection(; host=Sockets.localhost, port::Integer=27754,
                    tunnel::Symbol = host!=Sockets.localhost ? :ssh : :none,
                    ssh_opts=``, region=nothing, namespace=nothing)
    conn = Connection(host, port, tunnel, ssh_opts, region, namespace, nothing)
    setup_connection!(conn)
    finalizer(close_connection!, conn)
end

Base.isopen(conn::Connection) = !isnothing(conn.socket) && isopen(conn.socket)

function setup_connection!(conn::Connection)
    socket = if conn.tunnel == :none
        connect(conn.host, conn.port)
    else
        connect_via_tunnel(conn.host, conn.port; retry_timeout=5,
            tunnel=conn.tunnel, ssh_opts=conn.ssh_opts, region=conn.region,
            namespace=conn.namespace)
    end
    try
        verify_header(socket)
    catch exc
        close(socket)
        rethrow()
    end
    conn.socket = socket
    conn
end

function ensure_connected!(conn)
    if !isopen(conn)
        @info "Connection dropped, attempting reconnect"
        setup_connection!(conn)
    end
end

function close_connection!(conn::Connection)
    try
        if !isnothing(conn.socket) && isopen(conn.socket)
            serialize(conn.socket, (:exit,nothing))
            close(conn.socket)
        end
    finally
        conn.socket = nothing
    end
end

#-------------------------------------------------------------------------------
# REPL integration
function valid_input_checker(prompt_state)
    ast = Base.parse_input_line(String(take!(copy(REPL.LineEdit.buffer(prompt_state)))),
                                depwarn=false)
    return !Meta.isexpr(ast, :incomplete)
end

struct RemoteCompletionProvider <: REPL.LineEdit.CompletionProvider
    connection
end

function REPL.complete_line(provider::RemoteCompletionProvider,
                            state::REPL.LineEdit.PromptState)::
                            Tuple{Vector{String},String,Bool}
    # See REPL.jl complete_line(c::REPLCompletionProvider, s::PromptState)
    partial = REPL.beforecursor(state.input_buffer)
    full = REPL.LineEdit.input_string(state)
    try
        ensure_connected!(provider.connection)
        serialize(provider.connection.socket, (:repl_completion, (partial, full)))
        messageid, value = deserialize(provider.connection.socket)
        if messageid != :completion_result
            @warn "Completion failure" messageid
            return ([], "", false)
        end
        return value
    catch exc
        try
            close_connection!(provider.connection)
        catch
            exc isa Base.IOError || rethrow()
        end
        @error "Network or internal error running remote repl" exception=exc,catch_backtrace()
        return ([], "", false)
    end
end

function run_remote_repl_command(conn, out_stream, cmdstr)
    ast = Base.parse_input_line(cmdstr, depwarn=false)
    messageid=nothing
    value=nothing
    try
        ensure_connected!(conn)
        # See REPL.jl: display(d::REPLDisplay, mime::MIME"text/plain", x)
        display_props = Dict(
            :displaysize=>displaysize(out_stream),
            :color=>get(out_stream, :color, false),
            :limit=>true,
            :module=>Main,
        )
        serialize(conn.socket, (:display_properties, display_props))
        serialize(conn.socket, (:eval, ast))
        flush(conn.socket)
        response = deserialize(conn.socket)
        messageid, value = response isa Tuple && length(response) == 2 ?
                           response : (nothing,nothing)
    catch exc
        try
            close_connection!(conn)
        catch
            exc isa Base.IOError || rethrow()
        end
        @error "Network or internal error running remote repl" exception=exc,catch_backtrace()
        return
    end
    if messageid == :eval_result || messageid == :error
        if !isnothing(value) && !REPL.ends_with_semicolon(cmdstr)
            println(out_stream, value)
        end
    else
        @error "Unexpected response from server" messageid
    end
end

#-------------------------------------------------------------------------------
# Public client APIs

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
    conn = Connection(host=host, port=port, tunnel=tunnel,
                      ssh_opts=ssh_opts, region=region, namespace=namespace)
    out_stream = stdout
    ReplMaker.initrepl(c->run_remote_repl_command(conn, out_stream, c),
                       repl         = Base.active_repl,
                       valid_input_checker = valid_input_checker,
                       prompt_text  = "remote> ",
                       prompt_color = :magenta,
                       start_key    = '>',
                       sticky_mode  = true,
                       mode_name    = "remote_repl",
                       completion_provider = RemoteCompletionProvider(conn)
                       )
    nothing
end

connect_repl(port::Integer) = connect_repl(Sockets.localhost, port)

#--------------------------------------------------
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
    conn = Connection(; host=host, port=port, tunnel=tunnel)
    setup_connection!(conn)
    io = IOBuffer()
    run_remote_repl_command(conn, io, cmdstr)
    close_connection!(conn)
    String(take!(io))
end

function remote_eval(cmdstr::AbstractString)
    remote_eval(Sockets.localhost, 27754, cmdstr)
end
