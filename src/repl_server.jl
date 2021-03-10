using Sockets
using Serialization
using REPL

function start_repl_server(host=Sockets.localhost, port=27754)
    try
        server = listen(host, port)
        start_repl_server(server)
    finally
        close(server)
    end
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

function start_repl_server(server::Base.IOServer)
    open_sockets = Set()
    atexit() do
        for socket in open_sockets
            @info "Closing socket"
            close(socket)
        end
    end
    @sync while isopen(server)
        socket = accept(server)
        push!(open_sockets, socket)
        peer = getpeername(socket)
        @info "REPL client opened a connection" peer
        @async try
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
                        @info "Client closed the connection" peer
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
        catch exc
            if !(exc isa EOFError)
                @error "Something went wrong evaluating client command" #=
                    =# exception=exc,catch_backtrace()
            end
        finally
            close(socket)
            pop!(open_sockets, socket)
        end
    end
end

