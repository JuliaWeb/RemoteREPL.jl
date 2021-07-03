# RemoteREPL

![Version](https://juliahub.com/docs/RemoteREPL/version.svg)
[![docs latest](https://img.shields.io/badge/docs-latest-blue.svg)](https://juliahub.com/docs/RemoteREPL)

`RemoteREPL` allows you to connect your local julia REPL to a separate Julia
process and run commands interactively:

* Run code in the `Main` module of a remote Julia process
* Standard REPL tab completion and help mode with `?`
* Transfer variables between processes with `%get` and `%put`
* Automatic ssh tunnel for network security. Reconnects dropped connections.

Read [**the latest documentation**](https://c42f.github.io/RemoteREPL.jl/dev) more information.

(See [**docs on juliahub.com**](https://juliahub.com/docs/RemoteREPL)).

## Demo

[<img src="https://asciinema.org/a/422428.svg" width=50%>](https://asciinema.org/a/422428)

## Development

[![Build Status](https://github.com/c42f/RemoteREPL.jl/workflows/CI/badge.svg)](https://github.com/c42f/RemoteREPL.jl/actions)
[![docs-dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://c42f.github.io/RemoteREPL.jl/dev)

