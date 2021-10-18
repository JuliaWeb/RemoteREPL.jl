module RemoteREPL

export connect_repl, serve_repl, @remote

const DEFAULT_PORT = 27754
const PROTOCOL_MAGIC = "RemoteREPL"
const PROTOCOL_VERSION = UInt32(1)

include("tunnels.jl")
include("server.jl")
include("client.jl")

end
