# K8sClusterManagers.jl

[![CI](https://github.com/beacon-biosignals/K8sClusterManagers.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/beacon-biosignals/K8sClusterManagers.jl/actions/workflows/CI.yml)
[![codecov](https://codecov.io/gh/beacon-biosignals/K8sClusterManagers.jl/branch/main/graph/badge.svg?token=MG8ZO4APDI)](https://codecov.io/gh/beacon-biosignals/K8sClusterManagers.jl)
[![Docs: stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://beacon-biosignals.github.io/K8sClusterManagers.jl/stable)
[![Docs: development](https://img.shields.io/badge/docs-dev-blue.svg)](https://beacon-biosignals.github.io/K8sClusterManagers.jl/dev)

A Julia cluster manager for provisioning workers in a Kubernetes (K8s) cluster.

## K8sClusterManager

The `K8sClusterManager` can be used both inside and outside of a Kubernetes cluster.
To get started you'll need access to a K8s cluster and have configured your machine with
access to the cluster. If you're new to K8s we recommend you use use [minikube](https://minikube.sigs.k8s.io)
to quickly setup a local Kubernetes cluster.

### Running outside K8s

A distributed Julia cluster where the manager runs outside of K8s while the workers run in
the cluster can quickly be created via:

```julia
julia> using K8sClusterManagers, Distributed

julia> addprocs(K8sClusterManager(2))
```

When using the manager outside of Kubernetes cluster the manager will connect to workers
within the cluster using port-forwarding. Performance between the manager and workers will
be impacted by the network connection between the manager and the cluster.

### Running inside K8s

A Julia process running within a K8s cluster can also be used as a Julia distributed
manager.

To see this in action we'll create an interactive Julia REPL session running within the
cluster by executing:

```sh
kubectl run -it example-manager-pod --image julia:1
```

or equivalently, using a K8s manifest named `example-manager-pod.yaml` containing:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: example-manager-pod
spec:
  containers:
  - name: manager
    image: julia:1
    stdin: true
    tty: true
```

and running the following commands will also create a Julia REPL running inside a Kubernetes
Pod:

```sh
kubectl apply -f example-manager-pod.yaml

# Once the pod is running
kubectl attach -it pod/example-driver-pod
```

Now in this Julia REPL session, you can do add two workers via:

```julia
julia> using Pkg; Pkg.add("K8sClusterManagers")

julia> using K8sClusterManagers, Distributed

julia> addprocs(K8sClusterManager(2))
```

### Advanced configuration

`K8sClusterManager` exposes a `configure` keyword argument that can be used to make
modifications to the Pod manifest when defining workers.

When launching the cluster the function `configure(pod)` will be called where `pod` is an
dict-object representing the YAML/JSON Pod manifest. The function must return an object of
the same type. For example if you wanted to change the workers to require GPU resources you
could write the following:

```julia
function my_gpu_configurator(pod)
    worker_container = pod["spec"]["containers"][1]
    worker_container["resources"]["limits"]["nvidia.com/gpu"] = 1
    return pod
end
```

To get an example instance of `pod` objects that might be passed into the `configure`, call

```julia
using K8sClusterManagers, JSON
pod = K8sClusterManagers.worker_pod_spec(manager_name="example", image="julia", cmd=`julia`)
JSON.print(pod, 4)
```

## Useful Commands

Monitor the status of all your Pods
```sh
watch kubectl get pods,services
```

Stream the stdout of the worker "example-driver-pod-worker-9001":
```sh
kubectl logs -f pod/example-driver-pod-worker-9001
```

Currently cleaning up after / killing all your pods can be slow / ineffective from a Julia
context, especially if the driver Julia session dies unexpectedly. It may be necessary to
kill your workers from the command line.
```sh
kubectl delete pod/example-driver-pod-worker-9001 --grace-period=0 --force=true
```
It may be convenient to set a common label in your worker podspecs, so that you can select
them all with `-l='...'` by label, and kill all the worker Pods in a single invocation.

Display info about a Pod -- this is especially useful to troubleshoot a Pod that is taking
longer than expected to get up and running.
```sh
kubectl describe pod/example-driver-pod
```

## Troubleshooting

If you get `deserialize` errors during interations between driver and worker processes, make
sure you are using the same version of Julia on the driver as on all the workers!

If you aren't sure what went wrong, check the logs! The syntax is
```bash
kubectl logs -f pod/pod_name
```
where the Pod name `pod_name` you can get from `kubectl get pods`.

## Testing

The K8sClusterManagers package includes tests that are expect to have access to a Kubernetes
cluster. The tests should be able to be run in any Kubernetes cluster but have only been
run with [minikube](https://minikube.sigs.k8s.io/).

### Minikube

1. [Install Docker or Docker Desktop](https://docs.docker.com/get-docker/)
2. If using Docker Desktop: set the resources to a minimum of 3 CPUs and 2.25 GB Memory
3. [Install minikube](https://minikube.sigs.k8s.io/docs/start/)
4. Start the Kubernetes cluster: `minikube start`
5. Use the in-cluster Docker daemon for image builds: `eval $(minikube docker-env)`
   (Note: only works with single-node clusters)
6. Run the K8sClusterManagers.jl tests
