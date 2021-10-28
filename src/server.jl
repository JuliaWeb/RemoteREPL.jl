using Sockets
using Serialization
using REPL
using Logging

function send_header(io, ser_version=Serialization.ser_version)
    write(io, PROTOCOL_MAGIC, PROTOCOL_VERSION)
    write(io, UInt32(ser_version))
    flush(io)
end

# Like `sprint()`, but uses IOContext properties `ctx_properties`
#
# This is used to stringify results before sending to the client. This is
# beneficial because:
#   * It allows us to show the user-defined types which exist only on the
#     remote server
#   * It allows us to limit the amount of data transmitted (eg, large arrays
#     are truncated when the :limit IOContext property is set)
function sprint_ctx(f, ctx_properties)
    io = IOBuffer()
    ctx = IOContext(io, ctx_properties...)
    f(ctx)
    String(take!(io))
end

# Server-side expression processing
function preprocess_expression!(ex, new_stdout)
    if ex isa Expr
        if ex.head ∉ (:quote, :inert)
            map!(e->preprocess_expression!(e, new_stdout), ex.args, ex.args)
        end
    elseif ex === STDOUT_PLACEHOLDER
        ex = new_stdout
    end
    return ex
end

function eval_message(display_properties, messageid, messagebody)
    try
        if messageid in (:eval, :eval_and_get)
            result = nothing
            resultstr = sprint_ctx(display_properties[]) do io
                with_logger(ConsoleLogger(io)) do
                    expr = preprocess_expression!(messagebody, io)
                    result = Main.eval(expr)
                    if messageid === :eval && !isnothing(result)
                        show(io, MIME"text/plain"(), result)
                    end
                end
            end
            return messageid === :eval ?
                (:eval_result, resultstr) :
                (:eval_and_get_result, (result, resultstr))
        elseif messageid === :help
            resultstr = sprint_ctx(display_properties[]) do io
                md = Main.eval(REPL.helpmode(io, messagebody))
                show(io, MIME"text/plain"(), md)
            end
            return (:help_result, resultstr)
        elseif messageid === :display_properties
            display_properties[] = messagebody::Dict
            return nothing
        elseif messageid === :repl_completion
            # See REPL.jl complete_line(c::REPLCompletionProvider, s::PromptState)
            partial, full = messagebody
            ret, range, should_complete = REPL.completions(full, lastindex(partial))
            result = (unique!(map(REPL.completion_text, ret)),
                      partial[range], should_complete)
            return (:completion_result, result)
        else
            return (:error, "Unknown message id: $messageid")
        end
    catch _
        resultstr = sprint_ctx(display_properties[]) do io
            Base.display_error(io, Base.catch_stack())
        end
        return (:error, resultstr)
    end
end

function evaluate_requests(request_chan, response_chan)
    # Use a Ref so that display properties can be persistent between messages
    display_properties = Ref(Dict())

    while true
        try
            request = take!(request_chan)
            result = eval_message(display_properties, request...)
            if !isnothing(result)
                put!(response_chan, result)
            end
        catch exc
            if exc isa InvalidStateException && !isopen(request_chan)
                break
            elseif exc isa InterruptException
                # Ignore any interrupts which are sent while we're not
                # evaluating a command.
                continue
            else
                rethrow()
            end
        end
    end
end

function deserialize_requests(socket, repl_backend, request_chan, response_chan)
    while isopen(socket)
        request = nothing
        try
            request = deserialize(socket)
        catch exc
            resultstr = sprint() do io
                if exc isa UndefVarError
                    Base.display_error(io, exc, nothing)

                    print(io, """
                        This can happen when you try to pass a custom type
                        from the client which doesn't exist on the server""")
                else
                    Base.display_error(io, Base.catch_stack())
                    println(io, """
                        Unexpected error deserializing RemoteREPL message""")
                end
            end
            put!(response_chan, (:error, resultstr))
            continue
        end
        @debug "Client command" request
        if request isa Tuple && length(request) == 2 && request[1] isa Symbol
            messageid, messagebody = request
            # Handle flow control messages in the RemoteREPL frontend, here.
            if messageid === :exit
                break
            elseif messageid == :interrupt
                # Soft interrupt - this will only work if the
                # `repl_backend` task yields.  It won't work if
                # `repl_backend` is executing a compute-heavy task
                # which doesn't yield to the scheduler.
                schedule(repl_backend, InterruptException(); error=true)
            else
                # All other messages are handled by the evaluator
                put!(request_chan, request)
            end
        else
            put!(response_chan, (:error, "Invalid message of type: $(typeof(request))"))
        end
    end
end

function serialize_responses(socket, response_chan)
    try
        while true
            response = take!(response_chan)
            serialize(socket, response)
        end
    catch exc
        if isopen(response_chan) && isopen(socket)
            rethrow()
        end
    end
end

# Serve a remote REPL session to a single client over `socket`.
function serve_repl_session(socket)
    send_header(socket)
    @sync begin
        request_chan = Channel(1)
        response_chan = Channel(1)

        repl_backend = @async try
            evaluate_requests(request_chan, response_chan)
        catch exc
            @error "RemoteREPL backend crashed" exception=exc,catch_backtrace()
        finally
            close(response_chan)
        end

        @async try
            serialize_responses(socket, response_chan)
        catch exc
            @error "RemoteREPL responder crashed" exception=exc,catch_backtrace()
        finally
            close(socket)
        end

        try
            deserialize_requests(socket, repl_backend, request_chan, response_chan)
        catch exc
            @error "RemoteREPL frontend crashed" exception=exc,catch_backtrace()
            rethrow()
        finally
            close(socket)
            close(request_chan)
        end
    end
end

"""
    serve_repl([address=Sockets.localhost,] port=$DEFAULT_PORT)
    serve_repl(server)

Start a REPL server listening on interface `address` and `port`. In normal
operation `serve_repl()` serves REPL clients indefinitely (ie., it does not
return), so you will generally want to launch it using `@async serve_repl()` to
do other useful work at the same time.

If you want to be able to stop the server you can pass an already-listening
`server` object (the result of `Sockets.listen()`). The server can then be
cancelled from another task using `close(server)` as necessary to control the
server lifetime.

## Security

`serve_repl()` uses an *unauthenticated, unecrypted protocol* so it should not
be used on open networks or multi-user machines where other users aren't
trusted. For open networks, use the default `address=Sockets.localhost` and the
automatic ssh tunnel support provided by the client-side `connect_repl()`.
"""
function serve_repl(address=Sockets.localhost, port::Integer=DEFAULT_PORT)
    server = listen(address, port)
    try
        serve_repl(server)
    finally
        close(server)
    end
end
serve_repl(port::Integer) = serve_repl(Sockets.localhost, port)

function serve_repl(server::Base.IOServer)
    open_sockets = Set()
    @sync try
        while isopen(server)
            socket = accept(server)
            push!(open_sockets, socket)
            peer=getpeername(socket)
            @async try
                serve_repl_session(socket)
            catch exc
                if !(exc isa EOFError && !isopen(socket))
                    @warn "Something went wrong evaluating client command" #=
                        =# exception=exc,catch_backtrace()
                end
            finally
                @info "REPL client exited" peer
                close(socket)
                pop!(open_sockets, socket)
            end
            @info "REPL client opened a connection" peer
        end
    catch exc
        if exc isa Base.IOError && !isopen(server)
            # Ok - server was closed
            return
        end
        @error "Unexpected server failure" isopen(server) exception=exc,catch_backtrace()
        rethrow()
    finally
        for socket in open_sockets
            close(socket)
        end
    end
end

