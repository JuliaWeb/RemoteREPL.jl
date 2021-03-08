using ReplMaker
using REPL
using Serialization
using Sockets

function valid_input_checker(prompt_state)
    ast = Base.parse_input_line(String(take!(copy(REPL.LineEdit.buffer(prompt_state)))),
                                depwarn=false)
    return !Meta.isexpr(ast, :incomplete)
end

function run_remote_repl_command(server, cmdstr)
    ast = Base.parse_input_line(cmdstr, depwarn=false)
    local command, value
    try
        serialize(server, (:evaluate, ast))
        flush(server)
        response = deserialize(server)
        command,value = response isa Tuple && length(response) == 2 ?
                     response : (nothing,nothing)
    catch exc
        if exc isa Base.IOError
            command = :error
            value = "IOError - Remote Julia exited or is inaccessible"
        else
            rethrow()
        end
    end
    if command == :success
        display(value)
    elseif command == :error
        println(value)
    else
        @error "Unexpected response from server" response
    end
end

function connect_remote_repl(host=Sockets.localhost, port=27754)
    server = connect(host, port)
    # config = Dict(:displaysize=>displaysize())
    # serialize(server, (:config, config))
    ReplMaker.initrepl(c->run_remote_repl_command(server, c),
                       repl         = Base.active_repl,
                       valid_input_checker = valid_input_checker,
                       prompt_text  = "remote> ",
                       prompt_color = :red,
                       start_key    = '>',
                       sticky_mode  = true,
                       mode_name    = "remote_repl")
                       # startup_text = false)
    nothing
end

