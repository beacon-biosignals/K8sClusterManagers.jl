const DEFAULT_WORKER_CPU = 1
const DEFAULT_WORKER_MEMORY = "4Gi"

# Notifies tasks that the abnormal worker deregistration warning has been emitted
const DEREGISTER_ALERT = Condition()

struct K8sClusterManager <: ClusterManager
    np::Int
    pod_name::String
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
- `manager_pod_name`: the name of the manager pod. Defaults to `ENV["HOSTNAME"]` which is
  the name of the pod when executed inside of a Kubernetes pod.
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
                           manager_pod_name::String=get(ENV, "HOSTNAME", "localhost"),
                           image="julia:$VERSION",
                           cpu=DEFAULT_WORKER_CPU,
                           memory=DEFAULT_WORKER_MEMORY,
                           pending_timeout::Real=180,
                           configure=identity)

    # Default to using the image of the pod if possible
    if image === nothing
        pod = get_pod(manager_pod_name)
        images = map(c -> c["image"], pod["spec"]["containers"])

        if length(images) == 1
            image = first(images)
        elseif length(images) > 0
            error("Unable to determine image from pod \"$manager_pod_name\" which uses multiple containers")
        else
            error("Unable to find any images for pod \"$manager_pod_name\"")
        end
    end

    return K8sClusterManager(np, manager_pod_name, image, string(cpu), string(memory), pending_timeout, configure)
end

struct TimeoutException <: Exception
    msg::String
end

Base.showerror(io::IO, e::TimeoutException) = print(io, "TimeoutException: ", e.msg)

function worker_pod_spec(manager::K8sClusterManager; kwargs...)
    pod = worker_pod_spec(; manager_name=manager.pod_name,
                          image=manager.image,
                          cpu=manager.cpu,
                          memory=manager.memory,
                          kwargs...)

    return pod
end

function Distributed.launch(manager::K8sClusterManager, params::Dict, launched::Array, c::Condition)
    exename = params[:exename]
    exeflags = params[:exeflags]

    if startswith(manager.image, "julia:")
        exename = "julia"
    end

    cmd = `$exename $exeflags --worker=$(cluster_cookie()) --bind-to=0.0.0.0:9050`

    worker_manifest = worker_pod_spec(manager; cmd)

    # Note: User-defined `configure` function may or may-not be mutating
    worker_manifest = manager.configure(worker_manifest)

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

                # Using `--bind-to` to set the port requires us to also specify the hostname
                # to listen to. This command allows determine the IP address of the worker
                # from within the K8s cluster
                io = open(`$(kubectl()) exec pod/$pod_name -- $exename -e 'using Sockets; println(join(getipaddrs(), "\n"))'`)
                intra_addr = readline(io)

                # Redirect any stdout/stderr from the worker to be displayed on the manager.
                # Note: `start_worker` (via `--worker`) automatically redirects stderr to
                # stdout.
                p = open(detach(`$(kubectl()) logs -f pod/$pod_name`), "r+")

                # TODO: Seems weird to have this here but this is just a PoC
                pf = open(detach(`$(kubectl()) port-forward --address 127.0.0.1 $pod_name :9050`), "r+")
                local_addr, local_port = parse_forward_info(readline(pf.out))

                config = WorkerConfig()
                config.host = local_addr
                config.port = local_port
                config.io = p.out
                config.userdata = (; pod_name=pod_name, port_forward=pf, intra_addr)

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

function Distributed.connect(manager::K8sClusterManager, pid::Int, config::WorkerConfig)
    if config.connect_at !== nothing
        # this is a worker-to-worker setup call.
        return Distributed.connect_w2w(pid, config)
    end

    # master connecting to workers
    if config.io !== nothing
        # Not truly needed as we already know this information but since we are using `--worker`
        # we may as well follow the standard protocol
        intra_addr, intra_port = Distributed.read_worker_host_port(config.io)
    else
        error("I/O not setup")
    end

    if intra_addr == "0.0.0.0"
        intra_addr = config.userdata.intra_addr
    end

    local_addr = Base.notnothing(config.host)
    local_port = Base.notnothing(config.port)

    s, bind_addr = Distributed.connect_to_worker(local_addr, local_port)
    config.bind_addr = bind_addr

    # write out a subset of the connect_at required for further worker-worker connection setups
    config.connect_at = (intra_addr, Int(intra_port))

    if config.io !== nothing
        let pid = pid
            Distributed.redirect_worker_output(pid, Base.notnothing(config.io))
        end
    end

    (s, s)
end

function parse_forward_info(str)
    m = match(r"^Forwarding from (.*):(\d+) ->", str)
    if m !== nothing
        return (m.captures[1], parse(UInt16, m.captures[2]))
    else
        error("Unable to parse port-forward response")
    end
end

# remotecall_fetch(() -> remotecall_fetch(myid, 3), 2)
