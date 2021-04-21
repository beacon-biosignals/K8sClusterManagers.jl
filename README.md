# K8sClusterManagers.jl

[![CI](https://github.com/beacon-biosignals/K8sClusterManagers.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/beacon-biosignals/K8sClusterManagers.jl/actions/workflows/CI.yml)
[![codecov](https://codecov.io/gh/beacon-biosignals/K8sClusterManagers.jl/branch/master/graph/badge.svg?token=MG8ZO4APDI)](https://codecov.io/gh/beacon-biosignals/K8sClusterManagers.jl)
[![Docs: stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://beacon-biosignals.github.io/K8sClusterManagers.jl/stable)
[![Docs: development](https://img.shields.io/badge/docs-dev-blue.svg)](https://beacon-biosignals.github.io/K8sClusterManagers.jl/dev)

A Julia cluster manager for provisioning workers in a Kubernetes (k8s) cluster.

## K8sClusterManager

This is a `ClusterManager` for usage from a driver Julia session that:
- is running on the cluster already.
- has access to a working `kubectl` (from the julia-running-in-k8s-container context)

Assuming you have `kubectl` installed locally and configured to connect to a cluster in namespace "my-namespace",
you can easily set yourself up with just such a julia session by running for example `kubectl run example-driver-pod -it --image julia:1.5.3 -n my-namespace`.

Or equivalently, the following `driver.yaml` file containing a pod spec

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: example-driver-pod
spec:
  containers:
    - name: driver
      image: julia:1.5.3
      stdin: true
      tty: true
```

Running the following will drop you into a Julia REPL running Kubernetes pod:

```sh
kubectl apply -f driver.yaml

# Once the pod is running
kubectl attach -it pod/example-driver-pod -c driver
```

Now in this Julia REPL session, you can do:

```julia
julia> using Pkg; Pkg.add("K8sClusterManagers")

julia> using K8sClusterManagers

julia> addprocs(K8sClusterManager(2))
```

### Advanced configuration

`K8sClusterManager` exposes a `configure` keyword argument that can be used to make
modifications to the pod spec defining workers.

When launching the cluster the function `configure(pod)` will be called where `pod` is a
`Kuber.jl` object representing a pod spec. The function must return an object of the same
type. `Kuber.jl` makes it convenient to manipulate this `pod`, by letting you do things such
as:

```julia
function my_configurator(pod)
    push!(pod.spec.tolerations,
          Dict("key" => "gpu",
               "operator" => "Equal",
               "value" => "true"))
    return pod
end
```

To get an example instance of `pod` that might be passed into the `configure`, call

```julia
using K8sClusterManagers, Kuber
pod = K8sClusterManagers.worker_pod_spec(KuberContext(), port=0, cmd=`julia`, driver_name="driver", image="julia")
```


## Useful Commands

Monitor the status of all your pods
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
It may be convenient to set a common label in your worker podspecs, so that you can select them all with `-l='...'` by label, and kill all the worker pods in a single invocation.

Display info about a pod -- this is especially useful to troubleshoot a pod that is taking longer than expected to get up and running.
```sh
kubectl describe pod/example-driver-pod
```

## Troubleshooting

If you get `deserialize` errors during interations between driver and worker processes, make sure you are using the same version of Julia on the driver as on all the workers!

If you aren't sure what went wrong, check the logs! The syntax is
```bash
kubectl logs -f pod/pod_name
```
where the pod name `pod_name` you can get from `kubectl get pods`.

## Testing

The K8sClusterManagers package includes tests that are expect to have access to a Kubernetes
cluster. The tests should be able to be run in any Kubernetes cluster but have only been
run with [minikube](https://minikube.sigs.k8s.io/).

### Minikube

1. [Install Docker or Docker Desktop](https://docs.docker.com/get-docker/)
2. If using Docker Desktop: set the resources to a minimum of 3 CPUs and 2.25 GB Memory
3. [Install minikube](https://minikube.sigs.k8s.io/docs/start/)
4. Start the Kubernetes cluster: `minikube start`
5. Use the in-cluster Docker daemon for image builds: `eval $(minikube docker-env)` (Note: only works with single-node clusters)
6. Run the K8sClusterManagers.jl tests
