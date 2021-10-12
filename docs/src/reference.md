# Reference

## REPL syntax

RemoteREPL syntax is just normal Julia REPL syntax, the only minor difference
is that `?expr` produces help for `expr`, but we don't have a separate help
mode for this.

## API reference

```@docs
connect_repl
serve_repl
RemoteREPL.@remote
RemoteREPL.remote_eval
```

## Security considerations

Note that *any logged-in users on the client or server machines can execute
arbitrary commands in the serve_repl() process*. For this reason, you should
avoid using RemoteREPL on shared infrastructure like compute clusters if you
don't trust other users on the system. (In the future perhaps we can avoid this
by forwarding between socket files?)

This package uses an SSH tunnel by default to forward traffic when `host !=
Sockets.localhost`, so it should be quite secure to use over an open network.
If both client and server are on a secure network, it's possible to skip the
tunnel to avoid setting up SSH. However, if anyone breaks into your network
you'll be left with *no security whatsoever*.

TLDR; this package aims to provide safe defaults for single-user machines.
However, *do not expose the RemoteREPL port to an open network*. Abitrary
remote code execution is the main feature provided by this package!

