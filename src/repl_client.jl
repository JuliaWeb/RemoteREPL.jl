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

function connect_remote_repl(host=Sockets.localhost, port=27754)
    socket = connect(host, port)
    atexit() do
        serialize(socket, (:exit,nothing))
        flush(socket)
        close(socket)
    end
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

