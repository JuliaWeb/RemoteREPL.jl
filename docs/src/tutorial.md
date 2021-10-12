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

## Transferring variables

Normally RemoteREPL shows you a string-based summary of variables, but the
actual Julia values are held in the remote process. Sometimes it's useful to
transfer these to the client to make use of graphical utilities like plotting
or other resources which you need a local copy of the object for. This can be
done with the RemoteREPL [`@remote`](@ref) macro which executes an expression
on the "other side" of the current remote connection.

Transfer the value from a variable `x` on the client to the variable `y` on the
server:

```julia
julia> x = [1,2];

remote> y = @remote(x)
2-element Vector{Int64}:
 1
 2
```

Transfer arrays `x` and `y` from the server and plot them on the client:

```julia
remote> x = 1:42; y = x.^2;

julia> a, b = @remote (x,y)
       plot(a, b)
```
