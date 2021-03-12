# RemoteREPL

[![Build Status](https://github.com/c42f/RemoteREPL.jl/workflows/CI/badge.svg)](https://github.com/c42f/RemoteREPL.jl/actions)

`RemoteREPL` allows you to connect your local julia REPL to a separate Julia
process and run commands interactively.

In order for this to work, the remote julia process should start a REPL server
with `serve_repl()`.

The local instance will then be able to connect with `connect_repl()`.

Host (name / ip) and port numbers can be supplied if desired.

## Security and SSH

When connecting to a remote host with `connect_repl(host)`, this package
uses an SSH tunnel by default when `host != Sockets.localhost`. This provides
excellent security but it means an SSH server also needs to be running on the
machine where `serve_repl()` is called and you need SSH credentials set up for
that machine (such that `ssh your_host` works for the appropriate `your_host`).

If both machines are on a secure network, you could consider skipping this step
and directly using the RemoteREPL protocol. Note that in this configuration
there is *no security whatsoever* and that abitrary remote code execution is
the main feature provided by this package!

