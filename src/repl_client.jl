using ReplMaker
using REPL
using Serialization
using Sockets

function valid_input_checker(prompt_state)
    ast = Base.parse_input_line(String(take!(copy(REPL.LineEdit.buffer(prompt_state)))),
                                depwarn=false)
    return !Meta.isexpr(ast, :incomplete)
end

struct RemoteCompletionProvider <: REPL.LineEdit.CompletionProvider
    server
end

function REPL.complete_line(c::RemoteCompletionProvider, state::REPL.LineEdit.PromptState)
    # See also REPL.jl
    # complete_line(c::REPLCompletionProvider, s::PromptState)
    partial = REPL.beforecursor(state.input_buffer)
    full = REPL.LineEdit.input_string(state)
    serialize(c.server, (:completion_request, (partial, full)))
    command, value = deserialize(c.server)
    if command != :success
        @warn "Completion failure" command
        return ([], "", false)
    end
    return value
end

function run_remote_repl_command(server, cmdstr)
    ast = Base.parse_input_line(cmdstr, depwarn=false)
    command=nothing
    value=nothing
    try
        serialize(server, (:evaluate, ast))
        flush(server)
        response = deserialize(server)
        command, value = response isa Tuple && length(response) == 2 ?
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
        @error "Unexpected response from server" command
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
                       mode_name    = "remote_repl",
                       completion_provider = RemoteCompletionProvider(server)
                       )
                       # startup_text = false)
    nothing
end

