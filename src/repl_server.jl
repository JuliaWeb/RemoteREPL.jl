using Sockets
using Serialization
using REPL

function send_header(io, ser_version=Serialization.ser_version)
    write(io, protocol_magic, protocol_version)
    write(io, UInt32(ser_version))
    flush(io)
end

# Format result of arbitrary type as a string for transmission.
# Stringifying everything may seem strange, but is beneficial because
#   * It allows us to show the user-defined types which exist only on the
#     remote server
#   * It allows us to limit the amount of data transmitted (eg, large arrays
#     are truncated when the :limit IOContext property is set)
function format_result(f, display_properties)
    io = IOBuffer()
    ctx = IOContext(io, display_properties...)
    f(ctx)
    String(take!(io))
end

# Serve a remote REPL session to a single client over `socket`.
function serve_repl_session(socket)
    send_header(socket)
    display_properties = Dict()
    while isopen(socket)
        request = deserialize(socket)
        response = nothing
        try
            @debug "Client command" request
            messageid,value = request isa Tuple && length(request) == 2 ?
                            request : (nothing,nothing)
            if messageid == :eval
                result = Main.eval(value)
                resultval = isnothing(result) ? nothing :
                    format_result(display_properties) do io
                        show(io, MIME"text/plain"(), result)
                    end
                response = (:eval_result, resultval)
            elseif messageid == :display_properties
                @debug "Got client display properties" display_properties
                display_properties = value::Dict
            elseif messageid == :repl_completion
                # See REPL.jl complete_line(c::REPLCompletionProvider, s::PromptState)
                partial, full = value
                ret, range, should_complete = REPL.completions(full, lastindex(partial))
                result = (unique!(map(REPL.completion_text, ret)),
                          partial[range], should_complete)
                response = (:completion_result, result)
            elseif messageid == :exit
                break
            end
        catch _
            resultval = format_result(display_properties) do io
                Base.display_error(io, Base.catch_stack())
            end
            response = (:error, resultval)
        end
        if !isnothing(response)
            serialize(socket, response)
        end
    end
end


"""
    serve_repl(server)
    serve_repl([address=Sockets.localhost,] port=27754)

Start a REPL server listening on interface `address` and `port`. By default,
incoming connections are limited to localhost only for security and you
shouldn't change this unless you're on a secure network.

If you're on a secure network and want to incoming connections on all network
interfaces you can use address=`ip"0.0.0.0"`. This is not recommended however —
it's better to instead run an ssh server from the machine which is executing
`serve_repl()` and use `connect_repl()` in the default ssh tunnel mode.
"""
function serve_repl(address=Sockets.localhost, port::Integer=27754)
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
            @info "REPL client opened a connection" peer
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

