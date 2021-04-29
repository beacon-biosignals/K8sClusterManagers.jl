const DEFAULT_WORKER_CPU = 1
const DEFAULT_WORKER_MEMORY = "4Gi"

# Notifies tasks that the abnormal worker deregistration warning has been emitted
const DEREGISTER_ALERT = Condition()

struct K8sClusterManager <: ClusterManager
    np::Int
    driver_name::String
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
- `image`: Docker image to use for the workers. Defaults to using the image of the Julia
  caller if running within a pod using a single container otherwise is a required argument.
- `cpu`: [CPU resources requested](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/#meaning-of-cpu)
  for each worker. Defaults to `$(repr(DEFAULT_WORKER_CPU))`,
- `memory`: [Memory resource requested](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/#meaning-of-memory)
  for each worker in bytes. Requests may provide a unit suffix (e.g. "G" for Gigabytes and
  "GiB" for Gibibytes). Defaults to `$(repr(DEFAULT_WORKER_MEMORY))`.
- `pending_timeout`: The maximum number of seconds to wait for a "Pending" worker pod to
  enter the "Running" phase. Once the timeout has been reached the manager will continue
  with the number of workers available (`<= np`). Defaults to `180` (3 minutes).
- `configure`: A function which allows modification of the worker pod specification before
  their creation. Defaults to `identity`.
"""
function K8sClusterManager(np::Integer;
                           namespace::String=current_namespace(),
                           driver_name::String=get(ENV, "HOSTNAME", "localhost"),
                           image=nothing,
                           cpu=DEFAULT_WORKER_CPU,
                           memory=DEFAULT_WORKER_MEMORY,
                           pending_timeout::Real=180,
                           configure=identity)

    # Default to using the image of the pod if possible
    if image === nothing
        pod = get_pod(driver_name)
        images = map(c -> c["image"], pod["spec"]["containers"])

        if length(images) == 1
            image = first(images)
        elseif length(images) > 0
            error("Unable to determine image from pod \"$driver_name\" which uses multiple containers")
        else
            error("Unable to find any images for pod \"$driver_name\"")
        end
    end

    return K8sClusterManager(np, driver_name, image, string(cpu), string(memory), pending_timeout, configure)
end

struct TimeoutException <: Exception
    msg::String
end

function worker_pod_spec(manager::K8sClusterManager; kwargs...)
    pod = worker_pod_spec(; driver_name=manager.driver_name,
                          image=manager.image,
                          cpu=manager.cpu,
                          memory=manager.memory,
                          kwargs...)

    return pod
end

function Distributed.launch(manager::K8sClusterManager, params::Dict, launched::Array, c::Condition)
    exename = params[:exename]
    exeflags = params[:exeflags]

    cmd = `$exename $exeflags --worker`

    worker_manifest = @static if VERSION >= v"1.5"
        worker_pod_spec(manager; cmd)
    else
        worker_pod_spec(manager; cmd=cmd)
    end

    # Note: User-defined `configure` function may or may-not be mutating
    worker_manifest = manager.configure(worker_manifest)

    # Without stdin the `kubectl attach -i` process will be unable to send the cluster
    # cookie to the worker.
    # Note: Assumes worker pod uses only a single container
    if !get(worker_manifest["spec"]["containers"][1], "stdin", false)
        error("Worker pod container must enable support for stdin")
    end

    @sync for i in 1:manager.np
        @async begin
            pod_name = create_pod(worker_manifest)


            pod = try
                wait_for_running_pod(pod_name; timeout=manager.pending_timeout)
            catch e
                delete_pod(pod_name; wait=false)
                rethrow()
            end

            @info "$pod_name is up"

            # We'll ignore stderr as `kubectl attach` always outputs:
            # "If you don't see a command prompt, try pressing enter."
            # TODO: Ideally we would just ignore this line and report anything else but
            # unfortunately using an `IOBuffer` here never seems to capture any output.
            #
            # Note: The `start_worker` function by default redirects stderr to stdout which
            # means the stderr captured here should entirely be from `kubectl` (or possibly
            # from the worker if an error occurred before `start_worker`).
            p = kubectl() do exe
                attach_cmd = `$exe attach -i pod/$pod_name -c=worker`
                open(pipeline(detach(attach_cmd), stderr=stderr), "r+")
            end

            write_cookie(p)

            config = WorkerConfig()
            config.io = p.out
            config.userdata = (; pod_name=pod_name)

            push!(launched, config)
            notify(c)
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
end
