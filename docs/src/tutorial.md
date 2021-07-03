## Connecting two Julia processes

Let's connect two separate Julia processes on the same machine. First start up
a REPL server in process A. This will allow any number of external clients to
connect:

```julia
julia> using RemoteREPL

julia> @async serve_repl()
```

Now start a *separate* Julia session B, connect to process A and execute
some command:

```julia
julia> using RemoteREPL

julia> connect_repl()
REPL mode remote_repl initialized. Press > to enter and backspace to exit.

remote> x = 123
123
```

Back in the REPL of process A you'll now see that a client has connected, and
the variable `x` has been set in the `Main` module:

```julia
┌ Info: REPL client opened a connection
└   peer = (ip"127.0.0.1", 0xa68e)

julia> x
123
```

## Transfer variables between client and server

Normally RemoteREPL shows you a string-based summary of variables, but the
actual Julia values are held in the remote process. Sometimes it's useful to
transfer these to the client to make use of graphical utilities like plotting
or other resources which you need a local copy of the object for. This can be
done with the RemoteREPL `%get` and `%put` syntax:

Transfer the value from a variable `x` on the server and assign it to the name
`x` on the client. In process B from the previous tutorial, run

```julia
remote> y = 42;

remote> %put y
42
```

Now switching back to the local REPL (press backspace), you can see the value
of `y` has been set locally.

```julia
julia> y
42
```
