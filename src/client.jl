using ReplMaker
using REPL
using Serialization
using Sockets

struct RemoteException <: Exception
    msg::String
end

function Base.showerror(io::IO, e::RemoteException)
    # Here, we presume that e.msg is fully formatted.
    indented_msg = join("  " .* split(e.msg, '\n'), '\n')
    print(io, "RemoteException:\n", indented_msg)
end

# Super dumb macro expander which expands calls to only a single macro
# `macro_name` which is implemented as `func` taking the expressions passed to
# the macro. Complexities which are ignored:
#   * Hygiene / scoping - all symbols are non-hygenic
#   * Nesting of macro expansions - `macro_name` is expanded first regardless
#     of how it's nested within other macros in the source.
function simple_macro_expand!(func, ex, macro_name)
    if Meta.isexpr(ex, :macrocall) && ex.args[1] == macro_name
        return func(ex.args[3:end]...)
    elseif Meta.isexpr(ex, (:quote, :inert, :meta))
        # pass
    elseif ex isa Expr
        map!(ex.args, ex.args) do x
            simple_macro_expand!(func, x, macro_name)
        end
    end
    return ex
end

# Read and verify header bytes on initializing the connection
function verify_header(io, ser_version=Serialization.ser_version)
    magic = String(read(io, length(PROTOCOL_MAGIC)))
    if magic != PROTOCOL_MAGIC
        if !isopen(io)
            error("RemoteREPL stream was closed while reading header")
        else
            error("RemoteREPL protocol magic number mismatch: $(repr(magic)) != $(repr(PROTOCOL_MAGIC))")
        end
    end
    version = read(io, typeof(PROTOCOL_VERSION))
    if version != PROTOCOL_VERSION
        error("RemoteREPL protocol version number mismatch: $version != $PROTOCOL_VERSION")
    end
    # Version 1: We rely on the standard Serialization library for simplicity;
    # that's backward but not forward compatible depending on
    # Serialization.ser_version, so we check for an exact match
    remote_ser_version = read(io, UInt32)
    if remote_ser_version != ser_version
        error("""
              RemoteREPL Julia Serialization format version mismatch: $remote_ser_version != $ser_version
              Try using the same version of Julia on the server and client.
              """)
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

function Connection(; host=Sockets.localhost, port::Integer=DEFAULT_PORT,
                    tunnel::Symbol = host!=Sockets.localhost ? :ssh : :none,
                    ssh_opts=``, region=nothing, namespace=nothing)
    conn = Connection(host, port, tunnel, ssh_opts, region, namespace, nothing)
    setup_connection!(conn)
    finalizer(close, conn)
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

function Base.close(conn::Connection)
    try
        if !isnothing(conn.socket) && isopen(conn.socket)
            serialize(conn.socket, (:exit,nothing))
            close(conn.socket)
        end
    finally
        conn.socket = nothing
    end
end

function ensure_connected!(f::Function, conn::Connection; retries=1)
    n_try = 1
    while true
        try
            ensure_connected!(conn)
            return f()
        catch exc
            if exc isa RemoteException || exc isa InterruptException
                rethrow()
            end
            try
                close(conn)
            catch
                exc isa Base.IOError || rethrow()
            end
            if n_try == retries+1
                @error "Network or internal error running remote repl" exception=exc,catch_backtrace()
                return nothing
            end
            n_try += 1
        end
    end
end

function send_message(conn::Connection, message; read_response=true)
    serialize(conn.socket, message)
    flush(conn.socket)
    return read_response ? deserialize(conn.socket) : (:nothing, nothing)
end

#-------------------------------------------------------------------------------
# REPL integration
function parse_input(str)
    Base.parse_input_line(str)
end

function match_magic_syntax(str)
    if startswith(str, '?')
        return "?", str[2:end]
    end
    # We previously matched %get and %put RemoteREPL magics, but those were
    # removed in favour of `@remote`. Keeping `match_magic_syntax` for now in
    # case we want other magic syntax in the future.
end

function valid_input_checker(prompt_state)
    cmdstr = String(take!(copy(REPL.LineEdit.buffer(prompt_state))))
    magic = match_magic_syntax(cmdstr)
    if !isnothing(magic)
        cmdstr = magic[2]
    end
    ex = parse_input(cmdstr)
    return !Meta.isexpr(ex, :incomplete)
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
    result = ensure_connected!(provider.connection) do
        send_message(provider.connection, (:repl_completion, (partial, full)))
    end
    if isnothing(result) || result[1] != :completion_result
        return ([], "", false)
    end
    return result[2]
end

function run_remote_repl_command(conn, out_stream, cmdstr)
    ensure_connected!(conn) do
        # Set terminal properties for formatting result
        display_props = Dict(
            :displaysize=>displaysize(out_stream),
            :color=>get(out_stream, :color, false),
            :limit=>true,
            :module=>Main,
        )
        send_message(conn, (:display_properties, display_props), read_response=false)

        # Send actual command
        magic = match_magic_syntax(cmdstr)
        if isnothing(magic)
            # Normal remote evaluation
            ex = parse_input(cmdstr)

            ex = simple_macro_expand!(ex, Symbol("@remote")) do clientside_ex
                try
                    x = Main.eval(clientside_ex)
                    if x === Base.stdout
                        # The local stdout cannot be serialized in any sensible way,
                        # but we store a placeholder for it which will be transformed
                        # into a serverside approximation of the client stream.
                        return STDOUT_PLACEHOLDER
                    else
                        # Any expressions wrapped in `@remote` need to be executed
                        # on the client and wrapped in a QuoteNode to prevent them
                        # being eval'd again in the expression on the server side.
                        QuoteNode(x)
                    end
                catch _
                    error("Error while evaluating `@remote($clientside_ex)` before passing to the server")
                end
            end

            cmd = (:eval, ex)
        else
            # Magic prefixes
            if magic[1] == "?"
                # Help mode
                cmd = (:help, magic[2])
            end
        end
        # Big hack: we enable raw mode while sending the eval command, so we
        # can intercept control-C interrupts
        terminal = Base.active_repl.t
        messageid, value = @sync begin
            response = Channel(1)
            @async try
                put!(response, send_message(conn, cmd))
                lock(terminal.in_stream.cond) do
                    notify(terminal.in_stream.cond)
                end
            catch exc
                @error "" exception=exc,catch_backtrace()
                close(response)
            finally
                close(response)
            end
            REPL.Terminals.raw!(terminal, true)
            try
                read_terminating_char = false
                while Base.n_avail(response) == 0 && isopen(response)
                    try_wait_readnb(terminal.in_stream, 1)
                    if bytesavailable(terminal) > 0
                        byte = only(read(terminal, 1))
                        Core.println("Read byte:", byte)
                        if byte == 0x03 # control-C
                            # FIXME: locks?
                            send_message(conn, (:interrupt, nothing), read_response=false)
                        elseif byte == 0x64
                            read_terminating_char = true
                        end
                    end
                end
            finally
                REPL.Terminals.raw!(terminal, false)
            end
            take!(response)
        end
        result_for_display = nothing
        if messageid in (:eval_result, :help_result, :error)
            if !isnothing(value)
                if messageid != :eval_result || !REPL.ends_with_semicolon(cmdstr)
                    result_for_display = Text(value)
                end
            end
        else
            @error "Unexpected response from server" messageid
        end
        return result_for_display
    end
end

remote_eval_and_fetch(::Nothing, ex) = error("No remote connection is active")

function remote_eval_and_fetch(conn::Connection, ex)
    ensure_connected!(conn) do
        cmd = (:eval_and_get, ex)
        messageid, value = send_message(conn, cmd)
        if messageid == :eval_and_get_result
            logstring = value[2]
            if !isempty(logstring)
                # TODO: Improve this with an async remote logger
                @info Text("Remote logs\n" * logstring)
            end
            return value[1]
        elseif messageid == :error
            throw(RemoteException(value))
        else
            error("Unexpected response message id $messageid from server")
        end
    end
end

function repl_prompt_text(conn::Connection)
    host = conn.host == Sockets.localhost ? "localhost" : conn.host
    port = conn.port == DEFAULT_PORT ? "" : ":$(conn.port)"
    disconnected = isopen(conn) ? "" : " [disconnected]"
    return "julia@$host$port$disconnected> "
end

#-------------------------------------------------------------------------------
# Public client APIs

# Connection which is currently attached to the REPL mode.
_repl_client_connection = nothing

"""
    connect_repl([host=localhost,] port::Integer=$DEFAULT_PORT;
                 use_ssh_tunnel = (host != localhost) ? :ssh : :none,
                 ssh_opts = ``)

Connect client REPL to a remote `host` on `port`. This is then accessible as a
remote sub-repl of the current Julia session.

For security, `connect_repl()` uses an ssh tunnel for remote hosts. This means
that `host` needs to be running an ssh server and you need ssh credentials set
up for use on that host. For secure networks this can be disabled by setting
`tunnel=:none`.

To provide extra options to SSH, you may use the `ssh_opts` keyword, for
example an identity file may be set with ```ssh_opts = `-i /path/to/identity.pem` ```.
Alternatively, you may want to set this up permanently using a `Host` section
in your ssh config file.

You can also use the following technologies for tunneling in place of SSH:
1) AWS Session Manager: set `tunnel=:aws`. The optional `region` keyword
   argument can be used to specify the AWS Region of your server.
2) kubectl: set `tunnel=:k8s`. The optional `namespace` keyword argument can be
   used to specify the namespace of your Kubernetes resource.

See README.md for more information.
"""
function connect_repl(host=Sockets.localhost, port::Integer=DEFAULT_PORT;
                      tunnel::Symbol = host!=Sockets.localhost ? :ssh : :none,
                      ssh_opts=``, region=nothing, namespace=nothing,
                      startup_text=true)
    global _repl_client_connection

    if !isnothing(_repl_client_connection)
        try
            close(_repl_client_connection)
        catch exc
            @warn "Exception closing connection" exception=(exc,catch_backtrace())
        end
    end

    conn = Connection(host=host, port=port, tunnel=tunnel,
                      ssh_opts=ssh_opts, region=region, namespace=namespace)
    out_stream = stdout
    ReplMaker.initrepl(c->run_remote_repl_command(conn, out_stream, c),
                       repl         = Base.active_repl,
                       valid_input_checker = valid_input_checker,
                       prompt_text  = ()->repl_prompt_text(conn),
                       prompt_color = :magenta,
                       start_key    = '>',
                       sticky_mode  = true,
                       mode_name    = "remote_repl",
                       completion_provider = RemoteCompletionProvider(conn),
                       startup_text = startup_text
                       )
    # Record the connection which is attached to the REPL
    _repl_client_connection = conn

    nothing
end

connect_repl(port::Integer) = connect_repl(Sockets.localhost, port)

"""
    @remote ex

Execute expression `ex` on the other side of the current RemoteREPL connection
and return the value.

This can be used in both directions:
1. From the normal `julia>` prompt, execute `ex` on the remote server and
   return the value to the client.
2. From a remote prompt, execute `ex` on the *client* and push the
   resulting value to the remote server.

# Examples

Push a value from the client to the server:

```
julia> client_val = 1:100;

julia@localhost> server_val = @remote client_val
1:100
```

Fetch a pair of variables `(x,y)` from the server, and plot them on the client
with a single line:
```
# In two lines
julia> x,y = @remote (x, y)
       plot(x, y)

# Or as a single expression
julia> plot(@remote((x, y))...)
```
"""
macro remote(ex)
    _remote_expr(:_repl_client_connection, ex)
end

macro remote(conn, ex)
    _remote_expr(esc(conn), ex)
end

_remote_expr(conn, ex) = :(remote_eval_and_fetch($conn, $(QuoteNode(ex))))

#--------------------------------------------------
"""
    remote_eval(cmdstr)
    remote_eval(host, port, cmdstr)

Parse a string `cmdstr`, evaluate it in the remote REPL server's `Main` module,
then close the connection. Returns the result which the REPL would normally
pass to `show()` (likely a `Text` object).

For example, to cause the remote Julia instance to exit, you could use

```
using RemoteREPL
RemoteREPL.remote_eval("exit()")
```
"""
function remote_eval(host, port::Integer, cmdstr::AbstractString;
                     tunnel::Symbol = host!=Sockets.localhost ? :ssh : :none)
    conn = Connection(; host=host, port=port, tunnel=tunnel)
    local result
    try
        setup_connection!(conn)
        result = run_remote_repl_command(conn, IOBuffer(), cmdstr)
    finally
        close(conn)
    end
    return result
end

function remote_eval(cmdstr::AbstractString)
    remote_eval(Sockets.localhost, DEFAULT_PORT, cmdstr)
end
