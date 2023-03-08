module RemoteREPL

export connect_repl, serve_repl, @remote, connect_remote, putmodule!

const DEFAULT_PORT = 27754
const PROTOCOL_MAGIC = "RemoteREPL"
const PROTOCOL_VERSION = UInt32(1)

const STDOUT_PLACEHOLDER = Symbol("#RemoteREPL_STDOUT_PLACEHOLDER")
const NEWMODULE_CHANNEL = Channel{Module}(1)

include("tunnels.jl")
include("server.jl")
include("client.jl")

end
