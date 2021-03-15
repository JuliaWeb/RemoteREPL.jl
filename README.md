# RemoteREPL

[![Build Status](https://github.com/c42f/RemoteREPL.jl/workflows/CI/badge.svg)](https://github.com/c42f/RemoteREPL.jl/actions)

`RemoteREPL` allows you to connect your local julia REPL to a separate Julia
process and run commands interactively.

## Quick start

### Connecting two Julia processes on the same machine:


1. In process A
    ```julia
    julia> using RemoteREPL

    julia> @async serve_repl()
    ┌ Info: REPL client opened a connection
    └   peer = (ip"127.0.0.1", 0xa68e)
    ```
2. In process B
    ```julia
    julia> using RemoteREPL

    julia> connect_repl()
    REPL mode remote_repl initialized. Press > to enter and backspace to exit.

    remote> x = 123
    123
    ```
3. In process A
    ```julia
    julia> x
    123
    ```

### Connecting Julia processes on separate machines

This is the same as above, except:
* Ensure you have an ssh server running on `your.host.example` and can login
  normally using ssh.
* Call `connect_repl("your.host.example")` in process B

## Security considerations

Note that **any logged-in users on the client or server machines can execute
arbitrary commands in the serve_repl() process**. For this reason, you should
avoid using RemoteREPL on shared infrastructure like compute clusters if you
don't trust other users on the system. (In the future perhaps we can avoid this
by forwarding between socket files?)

This package uses an SSH tunnel by default to forward traffic when `host !=
Sockets.localhost`, so it should be quite secure to use over an open network.
If both client and server are on a secure network, it's possible to skip the
tunnel to avoid setting up SSH. However, if anyone breaks into your network
you'll be left with *no security whatsoever*: abitrary remote code execution is
the main feature provided by this package!
