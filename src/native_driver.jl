const DEFAULT_WORKER_CPU = 1
const DEFAULT_WORKER_MEMORY = "4Gi"

# Port number listened to by workers. The port number was randomly chosen from the ephemeral
# port range: 49152-65535.
const WORKER_PORT = 51400

struct K8sClusterManager <: ClusterManager
    np::Int
    driver_name::String
    image::String
    cpu::String
    memory::String

    retry_seconds::Int
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
- `retry_seconds`: The maximum number of seconds to wait for a worker pod to enter the
  "Running" phase. Once the time limit has been reached the manager will continue with the
  number of workers available (`<= np`). Defaults to `180` (3 minutes).
- `configure`: A function which allows modification of the worker pod specification before
  their creation. Defaults to `identity`.
"""
function K8sClusterManager(np::Integer;
                           namespace::String=current_namespace(),
                           driver_name::String=get(ENV, "HOSTNAME", "localhost"),
                           image=nothing,
                           cpu=DEFAULT_WORKER_CPU,
                           memory=DEFAULT_WORKER_MEMORY,
                           retry_seconds::Int=180,
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

    return K8sClusterManager(np, driver_name, image, string(cpu), string(memory), retry_seconds, configure)
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

    # Note: We currently use the same port number for all workers but this isn't strictly
    # required.
    cmd = `$exename $exeflags --worker=$(cluster_cookie()) --bind-to=0:$WORKER_PORT`

    worker_manifest = worker_pod_spec(manager; cmd=cmd)

    # Note: User-defined `configure` function may or may-not be mutating
    worker_manifest = manager.configure(worker_manifest)

    asyncmap(1:manager.np) do i
        pod_name = nothing
        start = time()
        try
            pod_name = create_pod(worker_manifest)
            status = wait_for_running_pod(pod_name; timeout=manager.retry_seconds)
            @info "$pod_name is up"

            sleep(2)

            config = WorkerConfig()
            config.host = status["podIP"]
            config.port = WORKER_PORT
            config.userdata = (; pod_name=pod_name)
            push!(launched, config)
            notify(c)
        catch e
            delete_pod(pod_name; wait=false)
            rethrow()
        end
    end
end

function Distributed.manage(manager::K8sClusterManager, id::Integer, config::WorkerConfig, op::Symbol)
    return nothing
end
