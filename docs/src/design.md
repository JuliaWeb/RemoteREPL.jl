# Design

RemoteREPL formats results as text (using `show(io, "text/plain", result)`) for
communication back to the client terminal. This is helpful because:
* The result of a computation might be large, and it should be summarized
  before sending back.
* The remote machine may be a separate application with different modules
  loaded; it may not be possible to deserialize the results in the local Julia
  session.

Currently RemoteREPL uses the standard Serialization library to format messages
on the wire, but this isn't bidirectionally compatible between Julia versions
so we'll probably move to something else in the future.
