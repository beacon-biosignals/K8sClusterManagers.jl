const DEFAULT_WORKER_CPU = 1
const DEFAULT_WORKER_MEMORY = "4Gi"

struct K8sClusterManager <: ClusterManager
    ports::Vector{UInt16}
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

    ports = 9000 .+ (1:np)
    return K8sClusterManager(ports, driver_name, image, string(cpu), string(memory), retry_seconds, configure)
end

struct TimeoutException <: Exception
    msg::String
    cause::Exception
end

function wait_for_pod_init(manager::K8sClusterManager, pod_name::AbstractString)
    status = nothing
    start = time()
    while true
        # try not to overwhelm kubectl proxy; staggered wait
        sleep(1 + rand())
        try
            status = get_pod(pod_name)["status"]
            if status["phase"] == "Running"
                @info "$pod_name is up"
                return status
            end
        catch e
            if time() - start > manager.retry_seconds
                throw(TimeoutException("timed out after waiting for worker $(pod_name) to init for $(manager.retry_seconds) seconds, with status\n $status", e))
            end
        end
    end
    throw(TimeoutException("timed out after waiting for worker $(pod_name) to init for $(manager.retry_seconds) seconds, with status\n $status", e))
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

    cmd = `$exename $exeflags --worker=$(cluster_cookie())`

    errors = Dict()
    # try not to overwhelm kubectl proxy; wait longer if more workers requested
    sleeptime = 0.1 * sqrt(length(manager.ports))
    asyncmap(manager.ports) do port
        worker_manifest = @static if VERSION >= v"1.5"
            worker_pod_spec(manager; port, cmd)
        else
            worker_pod_spec(manager; port=port, cmd=cmd)
        end

        # Note: User-defined `configure` function may or may-not be mutating
        worker_manifest = manager.configure(worker_manifest)

        pod_name = nothing
        start = time()
        try
            sleep(rand() * sleeptime)
            while time() - start < manager.retry_seconds
                try
                    pod_name = create_pod(worker_manifest)
                    break
                catch e
                    @error sprint(Base.showerror, e)
                    sleep(rand() * sleeptime)
                end
            end
            status = wait_for_pod_init(manager, pod_name)
            sleep(2)
            config = WorkerConfig()
            config.host = status["podIP"]
            config.port = port
            config.userdata = (; pod_name=pod_name)
            push!(launched, config)
            notify(c)
        catch e
            @error "error launching job on port $port, deleting pod and skipping!"
            push!(get!(() -> [], errors, typeof(e)), (e, catch_backtrace()))
            start = time()
            while time() - start < 5
                try
                    delete_pod(pod_name)
                    break
                catch e
                    sleep(rand())
                end
            end
        end
    end
    for erray in values(errors)
        e, backtrace = first(erray)
        @warn "$(length(erray)) errors with the same type as" exception=(e, backtrace)
    end
end

function Distributed.manage(manager::K8sClusterManager, id::Integer, config::WorkerConfig, op::Symbol)
    return nothing
end
