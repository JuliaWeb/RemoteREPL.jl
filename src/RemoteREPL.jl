module RemoteREPL

export connect_repl, serve_repl

# Technically, server and client could be completely separate packages, but
# having them together seems simplest for now.

const protocol_magic = "RemoteREPL"
const protocol_version = UInt32(1);

include("server.jl")
include("client.jl")

end
