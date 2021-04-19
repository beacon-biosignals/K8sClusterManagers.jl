# K8sClusterManagers

[![CI](https://github.com/beacon-biosignals/K8sClusterManagers.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/beacon-biosignals/K8sClusterManagers.jl/actions/workflows/CI.yml)
[![Docs: stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://beacon-biosignals.github.io/K8sClusterManagers.jl/stable)
[![Docs: development](https://img.shields.io/badge/docs-dev-blue.svg)](https://beacon-biosignals.github.io/K8sClusterManagers.jl/dev)

This repo contains a cluster manager for provisioning julia workers on a k8s cluster, making minimal assumptions about your cluster setup.

## K8sNativeManager

This is a `ClusterManager` for usage from a driver julia session that:
- is running on the cluster already.
- has access to a working `kubectl` (from the julia-running-in-k8s-container context)

Assuming you have `kubectl` installed locally and configured to connect to a cluster in namespace "my-namespace",
you can easily set yourself up with just such a julia session by running for example `kubectl run example-driver-pod -it --image julia:1.5.3 -n my-namespace`.

Or equivlently, the following `driver.yaml` file containing a pod spec

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

will drop you into a julia REPL running in the cluster by doing:

```bash
kubectl apply -f driver.yaml -n my-namespace

#and once the pod is running
kubectl attach pod/example-driver-pod -c driver -it -n my-namespace
```

Now in this julia REPL session, you can do:

```julia
]add K8sClusterManagers

using K8sClusterManagers

pids = K8sClusterManagers.addprocs_pod(2; namespace="my-namespace")
```

#### advanced configuration

`K8sClusterManagers.addprocs_pod` exposes a `configure` kwarg that can be used to make arbitrary modifications to the pod spec defining workers, which defaults to the identity function.

`configure(pod)` will be called on a `Kuber.jl` object `pod` representing a pod spec, and it must return an object of the same type. `Kuber.jl` makes it convenient to manipulate this `pod`, by letting you do things such as:

```julia
function my_configurator(pod)
    push!(pod.spec.tolerations, """
        {
            "key": "gpu",
            "operator": "Equal",
            "value": "true"
        }
    """)
    return pod
end
```

To get an example instance of `pod` that might be passed into the `configure`, call

```julia
pod, ctx = K8sClusterManagers.default_pod_and_context("my-namespace")
```


## useful commands

Monitor the status of all your pods
```bash
watch -n 1 kubectl get pods,services -n my-namespace'
```

tail the stdout of workers `example-driver-pod`
```bash
kubectl logs -f pod/example-driver-pod -c example-driver-pod-worker-9001 -n my-namespace
```

Currently cleaning up after / killing all your pods can be slow / ineffective from a julia context, especially if the driver julia session dies unexpectedly. It may be necessary to kill your workers from the command line.
```bash
kubectl delete pod/example-driver-pod-worker-9001 -n my-namespace --grace-period=0 --force=true
```
It may be convenient to set a common label in your worker podspecs, so that you can select them all with `-l='...'` by label, and kill all the worker pods in one invocation.


Display info about a pod -- this is especially useful to troubleshoot a pod that is taking longer than expected to get up and running.
```bash
kubectl describe pod/example-driver-pod -n my-namespace
```

## troubleshooting

If you get `deserialize` errors during interations between driver and worker processes, make sure you are using the same version of Julia on the driver as on all the workers!

If you aren't sure what went wrong, check the logs! The syntax is
```bash
kubectl logs -f -n my-namespace pod_name -c container_name
```
where the pod name `pod_name` you can get from `kubectl get pods -n my-namespace` and `container_name` from 
```bash
kubectl describe pod pod_name -n my-namespace
```

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
