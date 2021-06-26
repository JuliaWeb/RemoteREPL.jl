# RemoteREPL

[![Build Status](https://github.com/c42f/RemoteREPL.jl/workflows/CI/badge.svg)](https://github.com/c42f/RemoteREPL.jl/actions)

`RemoteREPL` allows you to connect your local julia REPL to a separate Julia
process and run commands interactively. Features include:

* Runs code in the Main module
* Normal REPL tab completion
* Help mode (use the `?` prefix)

## Quick start

### Connecting two Julia processes on the same machine:

First start up a REPL server in process A. This will allow any number of
external clients to connect

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

### Connecting Julia processes on separate machines

This is the same as above, except:

* Ensure you have an ssh server running on `your.host.example` and can login
  normally using ssh. If you've got some particular credentials or ssh options
  needed for `your.host`, you'll probably find it convenient to set these up in
  your openSSH config file (`~/.ssh/config` on unix). For example,
  ```ssh-config
  Host your.host.example
      User ubuntu
      IdentityFile ~/.ssh/some_identity
  ```
* Call `connect_repl("your.host.example")` in process B

### Alternatives to SSH

1) AWS Session Manager

You can use [AWS Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html) instead of SSH to connect to remote hosts. To do this, first setup Session Manager for the EC2 instances you like. See the [docs](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-getting-started.html). Thereafter, install [AWS CLI version 2](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) and then install the [Session Manager plugin for AWS CLI](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) on your local system.

Setup your AWS CLI by running `aws configure` on the command line. You can then connect to the RemoteREPL server on your EC2 instance with `connect_repl("your-instance-id"; tunnel=:aws, region="your-instance-region")`. The `region` argument is only required if the EC2 instance is not in the default region that your CLI was setup with.

2) kubectl

If [kubectl](https://kubernetes.io/docs/reference/kubectl/overview/) is configured on your local system, you can use that to connect to RemoteREPL servers on your Kubernetes cluster. Run the following snippet: `connect_repl("your-pod-name"; tunnel=:k8s, namespace="your-namespace")`. The `namespace` argument is only required if the Pod is not in the default Kubernetes namespace.

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

## Design

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

