# Design

## REPL wire protocol

Currently RemoteREPL uses the standard `Serialization` library to format
messages on the wire because this is simple to use.  However, this is not
bidirectionally compatible between Julia versions so we'll probably move to a
different message container format in the future.

RemoteREPL formats results as text (using `show(io, "text/plain", result)`) for
communication back to the client. This is helpful because:
* The result of a computation might be large, and it should be summarized
  before sending back. `show` is an excellent tool for this.
* The remote machine may be a separate application with different modules
  loaded; it may not be possible to deserialize the results in the local Julia
  session when custom types are involved.

## The standard streams

`RemoteREPL` doesn't interact with the standard streams `stdout`,`stderr` and
`stdin` on the server. This avoids unexpected side effects such as interfereing
with the server's normal logging and clashing with any concurrent `RemoteREPL`
sessions.

However this means that `RemoteREPL` misses out on some behavior you'd expect
from the normal `REPL`:
1. Functions like `println()` have side effects on the server which are not
   visible on the client. See the howto for how `@remote(stdout)` helps with
   this.
1. Interactive utilities like `Cthulhu.jl` — which reads from `stdin` and
   writes to `stdout` — don't work.

In future I hope to improve this situation with better stream forwarding utilities.
