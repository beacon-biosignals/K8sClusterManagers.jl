Examples
========

The `K8sClusterManager` can be used both inside and outside of a Kubernetes cluster.

## Launching an interactive session

The following manifest will create a Kubernetes [Job](https://kubernetes.io/docs/concepts/workloads/controllers/job/)
named "interactive-session". This Job will spawn a [Pod](https://kubernetes.io/docs/concepts/workloads/pods/)
(see `spec.template.spec`) which will run an interactive Julia session with the latest
release of K8sClusterManagers.jl installed. Be sure to create the required [ServiceAccount
and associated permissions](../patterns/#required-permissions) before proceeding.

````@eval
using Markdown
Markdown.parse("""
```yaml
$(read("interactive-session.yaml", String))
```
""")
````

To start the Job and attach to the interactive Julia session you can run the following:

```sh
# Executed from the K8sClusterManager.jl root directory
kubectl apply -f docs/src/interactive-session.yaml

# Determine the generated pod name from the job
manager_pod=$(kubectl get pods -l job-name=interactive-session --output=jsonpath='{.items[*].metadata.name}')
echo $manager_pod

# Attach to the interactive Julia session running in the pod.
# Note: You may need to wait for K8sClusterManagers.jl to finish installing
kubectl attach -it pod/${manager_pod?}
```

## Launching workers

You can use [`K8sClusterManager`](@ref) to spawn workers within the K8s cluster. The cluster
manager can be used both inside/outside of the K8s cluster. In the following example we'll
be using a small amount of CPU/Memory to ensure workers can be spawned even on clusters with
limited resources:

```julia
julia> using Distributed, K8sClusterManagers

julia> addprocs(K8sClusterManager(3, cpu=0.2, memory="300Mi", pending_timeout=30))
[ Info: interactive-example-sp28h-worker-7dvpt is up
[ Info: interactive-example-sp28h-worker-vvrwm is up
[ Info: interactive-example-sp28h-worker-bczm5 is up
3-element Vector{Int64}:
 2
 3
 4

julia> pmap(x -> myid(), 1:nworkers())  # Each worker reports its worker ID
3-element Vector{Int64}:
 3
 4
 2
```

## Pending workers

A worker created via `addprocs` may not necessarily be available right away, as K8s must
schedule the worker's Pod to a Node before the corresponding Julia process can start.
If K8s can't schedule the worker's Pod to a Node right away (e.g. not enough resources are
available), then that Pod will sit around in the "Pending" phase until it can be scheduled.
Since a worker Pod may be stuck in this "Pending" phase for an indefinite amount of time,
[`K8sClusterManager`](@ref) includes the `pending_timeout` keyword that may used to specify
how long you are willing to wait for pending workers. Once this timeout has been reached,
the manager will continue with the subset of workers which have reported in and delete any
workers that are stuck in the "Pending" phase.

```julia
julia> addprocs(K8sClusterManager(1, memory="1Pi", pending_timeout=10))  # Request 1 pebibyte of memory
┌ Warning: TimeoutException: timed out after waiting for worker interactive-session-d7jfb-worker-ffvnm to start for 10 seconds, with status:
│ {
│     "conditions": [
│         {
│             "lastProbeTime": null,
│             "lastTransitionTime": "2021-05-04T19:07:19Z",
│             "message": "0/1 nodes are available: 1 Insufficient memory.",
│             "reason": "Unschedulable",
│             "status": "False",
│             "type": "PodScheduled"
│         }
│     ],
│     "phase": "Pending",
│     "qosClass": "Guaranteed"
│ }
└ @ K8sClusterManagers ~/.julia/dev/K8sClusterManagers/src/native_driver.jl:113
Int64[]
```

## Termination Reason

When Julia workers [exceed the specified memory limit](https://kubernetes.io/docs/tasks/configure-pod-container/assign-memory-resource/#exceed-a-container-s-memory-limit)
the worker Pod will be automatically killed by Kubernetes (OOMKilled). In such a
scenario the worker will be reported as terminated by Distributed.jl without details.
K8sClusterManagers.jl will provide the reason, as reported by K8s, for the termination of
the worker:

```julia
julia> @everywhere begin
           function oom(T=Int64)
               max_elements = Sys.total_memory() ÷ sizeof(T)
               fill(zero(T), max_elements + 1)
           end
       end

julia> remotecall_fetch(oom, last(workers()))
Worker 4 terminated.ERROR:
ProcessExitedException(4)
Stacktrace:
  [1] try_yieldto(undo::typeof(Base.ensure_rescheduled))
    @ Base ./task.jl:705
  [2] wait
    @ ./task.jl:764 [inlined]
  [3] wait(c::Base.GenericCondition{ReentrantLock})
    @ Base ./condition.jl:106
  [4] take_buffered(c::Channel{Any})
    @ Base ./channels.jl:389
  [5] take!(c::Channel{Any})
    @ Base ./channels.jl:383
  [6] take!(::Distributed.RemoteValue)
    @ Distributed /buildworker/worker/package_linuxaarch64/build/usr/share/julia/stdlib/v1.6/Distributed/src/remotecall.jl:599
  [7] #remotecall_fetch#143
    @ /buildworker/worker/package_linuxaarch64/build/usr/share/julia/stdlib/v1.6/Distributed/src/remotecall.jl:390 [inlined]
  [8] remotecall_fetch(::Function, ::Distributed.Worker)
    @ Distributed /buildworker/worker/package_linuxaarch64/build/usr/share/julia/stdlib/v1.6/Distributed/src/remotecall.jl:386
  [9] remotecall_fetch(::Function, ::Int64; kwargs::Base.Iterators.Pairs{Union{}, Union{}, Tuple{}, NamedTuple{(), Tuple{}}})
    @ Distributed /buildworker/worker/package_linuxaarch64/build/usr/share/julia/stdlib/v1.6/Distributed/src/remotecall.jl:421
 [10] remotecall_fetch(::Function, ::Int64)
    @ Distributed /buildworker/worker/package_linuxaarch64/build/usr/share/julia/stdlib/v1.6/Distributed/src/remotecall.jl:421
 [11] top-level scope
    @ REPL[4]:1

julia> ┌ Warning: Worker 4 on pod interactive-session-nfz6j-worker-2hzsd was terminated due to: OOMKilled
└ @ K8sClusterManagers ~/.julia/packages/K8sClusterManagers/hUL5i/src/native_driver.jl:171
```
