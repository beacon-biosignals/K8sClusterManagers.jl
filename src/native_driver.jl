const DEFAULT_WORKER_CPU = 1
const DEFAULT_WORKER_MEMORY = "4Gi"

# Notifies tasks that the abnormal worker deregistration warning has been emitted
const DEREGISTER_ALERT = Condition()

struct K8sClusterManager <: ClusterManager
    np::Int
    worker_prefix::String
    image::String
    cpu::String
    memory::String

    pending_timeout::Int
    configure::Function
end

"""
    K8sClusterManager(np::Integer; kwargs...)

A cluster manager using Kubernetes (k8s) which spawns additional pods as workers. Attempts
to spawn `np` workers but may launch with less workers if the cluster has less resources
available.

## Arguments

- `np`: Desired number of worker pods to be launched.

## Keywords

- `namespace`: the Kubernetes namespace to launch worker pods within. Defaults to
  `current_namespace()`.
- `manager_pod_name`: the name of the manager pod. Defaults to `gethostname()` which is
  the name of the pod when executed inside of a Kubernetes pod.
- `worker_prefix`: the prefix given to spawned workers. Defaults to
  `"\$(manager_pod_name)-worker"` when the manager is running inside of K8s otherwise
  defaults to `"$(gethostname())-worker`.
- `image`: Docker image to use for the workers. Defaults to the image used by the manager
  when running inside of a K8s pod otherwise defaults to "julia:\$VERSION".
- `cpu`: [CPU resources requested](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/#meaning-of-cpu)
  for each worker. Defaults to `$(repr(DEFAULT_WORKER_CPU))`,
- `memory`: [Memory resource requested](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/#meaning-of-memory)
  for each worker in bytes. Requests may provide a unit suffix (e.g. "G" for Gigabytes and
  "Gi" for Gibibytes). Defaults to `$(repr(DEFAULT_WORKER_MEMORY))`.
- `pending_timeout`: The maximum number of seconds to wait for a "Pending" worker pod to
  enter the "Running" phase. Once the timeout has been reached the manager will continue
  with the number of workers available (`<= np`). Defaults to `180` (3 minutes).
- `configure`: A function which allows modification of the worker pod specification before
  their creation. Defaults to `identity`.
"""
function K8sClusterManager(np::Integer;
                           namespace::AbstractString=current_namespace(),
                           manager_pod_name=isk8s() ? gethostname() : nothing,
                           worker_prefix::AbstractString="$(@something(manager_pod_name, gethostname()))-worker",
                           image=nothing,
                           cpu=DEFAULT_WORKER_CPU,
                           memory=DEFAULT_WORKER_MEMORY,
                           pending_timeout::Real=180,
                           configure=identity)
    if image === nothing
        if manager_pod_name !== nothing
            pod = get_pod(manager_pod_name)
            images = map(c -> c["image"], pod["spec"]["containers"])

            if length(images) == 1
                image = first(images)
            elseif length(images) > 0
                error("Unable to determine image from pod \"$manager_pod_name\" which uses multiple containers")
            else
                error("Unable to find any images for pod \"$manager_pod_name\"")
            end
        else
            image = "julia:$VERSION"
        end
    end

    return K8sClusterManager(np, worker_prefix, image, string(cpu), string(memory), pending_timeout, configure)
end

struct TimeoutException <: Exception
    msg::String
end

Base.showerror(io::IO, e::TimeoutException) = print(io, "TimeoutException: ", e.msg)

function worker_pod_spec(manager::K8sClusterManager; kwargs...)
    pod = worker_pod_spec(; worker_prefix=manager.worker_prefix,
                          image=manager.image,
                          cpu=manager.cpu,
                          memory=manager.memory,
                          kwargs...)

    return pod
end

function Distributed.launch(manager::K8sClusterManager, params::Dict, launched::Array, c::Condition)
    exename = params[:exename]
    exeflags = params[:exeflags]

    # When using a standard Julia Docker image we can safely set the Julia executable name
    # Alternatively, we could extend `Distributed.default_addprocs_params`.
    if startswith(manager.image, "julia:")
        exename = "julia"
    end

    # Using `--bind-to=0.0.0.0` to force the worker to listen to all interfaces instead
    # of only a single external interface. This is required for `kubectl port-forward`.
    # TODO: Should file against the Julia repo about this issue.
    cmd = `$exename $exeflags --worker=$(cluster_cookie()) --bind-to=0.0.0.0`

    worker_manifest = worker_pod_spec(manager; cmd, cluster_cookie=cluster_cookie())

    # Note: User-defined `configure` function may or may-not be mutating
    worker_manifest = manager.configure(worker_manifest)

    # Trigger any TOTP requests before the async loop
    # TODO: Verify this is working correctly
    success(`$(kubectl()) get pods -o 'jsonpath={.items[*].metadata.null}'`)

    @sync for i in 1:manager.np
        @async begin
            pod_name = create_pod(worker_manifest)

            # TODO: Add notice about having to pull an image. On a slow internet connection
            # this can make it appear that the cluster start is hung

            pod = try
                wait_for_running_pod(pod_name; timeout=manager.pending_timeout)
            catch e
                e isa TimeoutException || rethrow()

                delete_pod(pod_name; wait=false)
                @warn sprint(showerror, e)
                nothing
            end

            if pod !== nothing
                @info "$pod_name is up"

                # Redirect any stdout/stderr from the worker to be displayed on the manager.
                # Note: `start_worker` (via `--worker`) automatically redirects stderr to
                # stdout.
                p = open(detach(`$(kubectl()) logs -f pod/$pod_name`), "r+")

                config = WorkerConfig()
                config.io = p.out
                config.userdata = (; pod_name, port_forward=Ref{Base.Process}())

                push!(launched, config)
                notify(c)
            end
        end
    end
end

function Distributed.manage(manager::K8sClusterManager, id::Integer, config::WorkerConfig, op::Symbol)
    pod_name = config.userdata.pod_name

    if op === :register
        # Note: Labelling the pod with the worker ID is only a nice-to-have. We may want to
        # make this fail gracefully if "patch" access is unavailable.
        label_pod(pod_name, "worker-id" => id)

    elseif op === :interrupt
        os_pid = config.ospid
        if os_pid !== nothing
            try
                exec_pod(pod_name, `bash -c "kill -2 $os_pid"`)
            catch e
                @error "Error sending a Ctrl-C to julia worker $id on pod $pod_name:\n" * sprint(showerror, e)
            end
        else
            # This state can happen immediately after an addprocs
            @error "Worker $id cannot be presently interrupted."
        end

    elseif op === :deregister
        # Terminate the port-forward process. Without this these processes may
        # persist until terminated by the cluster (e.g. `minikube stop`).
        pf = config.userdata.port_forward
        if isassigned(pf)
            kill(pf[])
        end

        # As the deregister `manage` call occurs before remote workers are told to
        # deregister we should avoid unnecessarily blocking.
        @async begin
            # In the event of a worker pod failure Julia may notice the worker socket
            # close before Kubernetes has the pod's final status available.
            #
            # Note: The wait duration of 30 seconds was picked as it's the default
            # "grace period" used for pod termination.
            # https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-termination
            state = reason = nothing
            timedwait(30.0, pollint=1.0) do
                state, reason = pod_status(pod_name)
                state == "terminated"
            end

            # Report any abnormal terminations of worker pods
            if state == "terminated" && reason != "Completed"
                @warn "Worker $id on pod $pod_name was terminated due to: $reason"
            end

            notify(DEREGISTER_ALERT; all=true)
        end
    end

    return nothing
end

# Stripped down and modified version of:
# https://github.com/JuliaLang/julia/blob/844c20dd63870aa5b369b85038f0523d7d79308a/stdlib/Distributed/src/managers.jl#L567-L632
function Distributed.connect(manager::K8sClusterManager, pid::Int, config::WorkerConfig)
    # Note: This method currently doesn't implement support for worker-to-worker
    # connections and instead relies on the `Distributed.connect(::DefaultClusterManager, ...)`
    # for this. If we did need to perform special logic for worker-to-worker connections
    # we would need to modify how `init_worker` is called via `start_worker`:
    # https://github.com/JuliaLang/julia/blob/f7554b5c9f0f580a9fcf5c7b8b9a83b678e2f48a/stdlib/Distributed/src/cluster.jl#L375-L378

    # master connecting to workers
    if config.io !== nothing
        # Not truly needed as we already know this information but since we are using `--worker`
        # we may as well follow the standard protocol
        bind_addr, port = Distributed.read_worker_host_port(config.io)
    else
        error("I/O not setup")
    end

    pod_name = config.userdata.pod_name

    # As we've forced the worker to listen to all interfaces the reported `bind_addr` will
    # be a non-routable address. We'll need to determine the in cluster IP address another
    # way.
    intra_addr = get_pod(pod_name)["status"]["podIP"]
    intra_port = port

    bind_addr, port = if !isk8s()
        # When the manager running outside of the K8s cluster we need to establish
        # port-forward connections from the manager to the workers.
        pf = open(`$(kubectl()) port-forward --address localhost pod/$pod_name :$intra_port`, "r")
        fwd_addr, fwd_port = parse_forward_info(readline(pf.out))

        # Retain a reference to the port forward
        config.userdata.port_forward[] = pf

        fwd_addr, fwd_port
    else
        intra_addr, intra_port
    end

    s, bind_addr = Distributed.connect_to_worker(bind_addr, port)
    config.bind_addr = bind_addr

    # write out a subset of the connect_at required for further worker-worker connection setups
    config.connect_at = (intra_addr, Int(intra_port))

    if config.io !== nothing
        let pid = pid
            Distributed.redirect_worker_output(pid, Base.notnothing(config.io))
        end
    end

    return (s, s)
end

function parse_forward_info(str)
    m = match(r"^Forwarding from (.*):(\d+) ->", str)
    if m !== nothing
        return (m.captures[1], parse(UInt16, m.captures[2]))
    else
        error("Unable to parse port-forward response")
    end
end
