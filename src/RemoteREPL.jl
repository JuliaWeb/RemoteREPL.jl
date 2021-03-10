module RemoteREPL

export connect_repl, serve_repl

# Technically, server and client could be completely separate packages, but
# having them together seems simplest for now.

include("repl_server.jl")
include("repl_client.jl")

end
