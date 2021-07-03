# How-To

## Connecting to a remote machine

Connecting to a remote machine goes via an SSH tunnel by default.

1. Ensure you have an ssh server running on `your.host.example` and can login
   normally using ssh. If you've got some particular credentials or ssh options
   needed for `your.host`, you'll probably find it convenient to set these up in
   your openSSH config file (`~/.ssh/config` on unix). For example,
   ```ssh-config
   Host your.host.example
       User ubuntu
       IdentityFile ~/.ssh/some_identity
   ```
2. Start a Julia process A on the server and call `serve_repl()`. Use
   `@async serve_repl()` if you'd like to run other work concurrently.
3. Start a separate Julia process B on the client and call
   `connect_repl("your.host.example")`.

## Transfer variables

Variable values can be transferred between server and client with the special
syntax `%put` and `%get`:

* Transfer a value from a variable `x` on the server and assign it to the name
  `x` on the client:
  ```julia
  remote> x = 42;

  remote> %put x
  42

  julia> x
  42
  ```

* Transfer a variable to the server under a new name
  ```julia
  julia> y = 101;

  remote> %get z = y
  101
  ```

* More general expressions on the right and left hand sides also work:
  ```julia
  remote> x = [1,2];

  remote> %put y = x .+ 1
  2-element Vector{Int64}:
   2
   3

  remote> %put a,b = x
  2-element Vector{Int64}:
   1
   2
  ```

## Alternatives to SSH

### AWS Session Manager

You can use [AWS Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html) instead of SSH to connect to remote hosts. To do this, first setup Session Manager for the EC2 instances you like. See the [docs](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-getting-started.html). Thereafter, install [AWS CLI version 2](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) and then install the [Session Manager plugin for AWS CLI](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) on your local system.

Setup your AWS CLI by running `aws configure` on the command line. You can then connect to the RemoteREPL server on your EC2 instance with `connect_repl("your-instance-id"; tunnel=:aws, region="your-instance-region")`. The `region` argument is only required if the EC2 instance is not in the default region that your CLI was setup with.

### Kubernetes `kubectl`

If [kubectl](https://kubernetes.io/docs/reference/kubectl/overview/) is configured on your local system, you can use that to connect to RemoteREPL servers on your Kubernetes cluster. Run the following snippet: `connect_repl("your-pod-name"; tunnel=:k8s, namespace="your-namespace")`. The `namespace` argument is only required if the Pod is not in the default Kubernetes namespace.

