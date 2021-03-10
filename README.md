# RemoteREPL

[![Build Status](https://github.com/c42f/RemoteREPL.jl/workflows/CI/badge.svg)](https://github.com/c42f/RemoteREPL.jl/actions)

`RemoteREPL` allows you to connect your local julia REPL to a separate Julia
process and run commands interactively.

In order for this to work, the remote julia process should start a REPL server
with `serve_repl()`.

The local instance will then be able to connect with `connect_repl()`.

Host (name / ip) and port numbers can be supplied if desired.

## (In)security NOTE!

No security is provided by this package, so for now it should only be used on
secure local networks, eg inside a docker network, behind a router, on
localhost, etc.

However, you could probably use an SSH tunnel and some firewall rules to make
this usable on an open network. Ideally this package would integrate with
OpenSSH or some such to make the connection secure.
