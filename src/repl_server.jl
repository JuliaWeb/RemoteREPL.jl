using Sockets
using Serialization

function start_repl_server(host=Sockets.localhost, port=27754)
    try
        server = listen(host, port)
        start_repl_server(server)
    finally
        close(server)
    end
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
        host,port = getpeername(socket)
        @info "REPL client opened a connection" host port=Int(port)
        @async try
            while isopen(socket)
                request = deserialize(socket)
                response = try
                    @debug "Client command" request
                    command,value = request isa Tuple && length(request) == 2 ?
                                    request : (nothing,nothing)
                    if command == :evaluate
                        result = Main.eval(value)
                    elseif command == :exit
                        @info "Client closed the connection"
                        break
                    end
                    (:success, result)
                catch _
                    io = IOBuffer()
                    ctx = IOContext(io, :color=>true)
                    Base.display_error(ctx, Base.catch_stack())
                    (:error, String(take!(io)))
                end
                serialize(socket, response)
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

