struct K8sNativeManager <: ClusterManager
    ctx::Any
    pods::Dict{Int, Any}
    retry_seconds::Int
    function K8sNativeManager(ports,
                              driver_name::String,
                              cmd::Cmd;
                              configure=identity,
                              namespace::String=current_namespace(),
                              retry_seconds::Int,
                              kwargs...)
        pods, ctx = default_pods_and_context(namespace; configure=configure, driver_name=driver_name, ports=ports, cmd=cmd, kwargs...)
        return new(ctx, pods, retry_seconds)
    end
end

struct TimeoutException <: Exception
    msg::String
    cause::Exception
end

function wait_for_pod_init(manager::K8sNativeManager, pod)
    status = nothing
    start = time()
    while true
        # try not to overwhelm kubectl proxy; staggered wait
        sleep(1 + rand())
        try
            status = get(manager.ctx, :Pod, pod.metadata.name).status
            if status.phase == "Running"
                @info "$(pod.metadata.name) is up"
                return status
            end
        catch e
            if time() - start > manager.retry_seconds
                throw(TimeoutException("timed out after waiting for worker $(pod.metadata.name) to init for $(manager.retry_seconds) seconds, with status\n $status", e))
            end
        end
    end
    throw(TimeoutException("timed out after waiting for worker $(pod.metadata.name) to init for $(manager.retry_seconds) seconds, with status\n $status", e))
end

function launch(manager::K8sNativeManager, params::Dict, launched::Array, c::Condition)
    errors = Dict()
    # try not to overwhelm kubectl proxy; wait longer if more workers requested
    sleeptime = 0.1 * sqrt(length(manager.pods))
    asyncmap(collect(pairs(manager.pods))) do p
        port, pod = p
        start = time()
        try
            sleep(rand() * sleeptime)
            while time() - start < manager.retry_seconds
                try
                    put!(manager.ctx, pod)
                    break
                catch e
                    sleep(rand() * sleeptime)
                end
            end
            status = wait_for_pod_init(manager, pod)
            sleep(2)
            config = WorkerConfig()
            config.host = status.podIP
            config.port = port
            config.userdata = pod.metadata.name
            push!(launched, config)
            notify(c)
        catch e
            @error "error launching job on port $port, deleting pod and skipping!"
            push!(get!(() -> [], errors, typeof(e)), (e, catch_backtrace()))
            start = time()
            while time() - start < 5
                try
                    delete!(manager.ctx, :Pod, pod.metadata.name)
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

"""
    addprocs_pod(np::Int;
                 configure=identity,
                 namespace::String=current_namespace(),
                 image=nothing,
                 memory::String="4Gi",
                 cpu::String="1",
                 retry_seconds::Int=180,
                 exename=`julia`,
                 exeflags=``,
                 params...)

Launch and connect to `np` worker processes.
This may launch and return fewer pids than requested, if requested workers do not come online within `retry_seconds`.

If `image` is unspecified
- if the julia caller is in a pod containing a single container, its image will be used for the pods as well.
- if there are multiple containers in the driver's pod, an error is thrown.

For more advanced configuration,
`configure` will be applied to the `Kuber.jl` pod specs of worker nodes before applying them.
"""
function addprocs_pod(np::Int;
                      driver_name::String=get(ENV, "HOSTNAME", "localhost"),
                      configure=identity,
                      namespace::String=current_namespace(),
                      image=nothing,
                      serviceAccountName=nothing,
                      memory::String="4Gi",
                      cpu::String="1",
                      retry_seconds::Int=180,
                      exename=`julia`,
                      exeflags=``,
                      params...)
    cmd = `$exename $exeflags $(worker_arg())`
    return addprocs(K8sNativeManager(9000 .+ (1:np),
                                     driver_name,
                                     cmd;
                                     configure=configure,
                                     image=image,
                                     memory=memory,
                                     cpu=cpu,
                                     namespace=namespace,
                                     serviceAccountName=serviceAccountName,
                                     retry_seconds=retry_seconds);
                    merge((exename = exename,), params)...)
end

manage(manager::K8sNativeManager, id::Int64, config::WorkerConfig, op::Symbol) = nothing

function kill(manager::K8sNativeManager, id::Int64, config::WorkerConfig)
    sleeptime = 0.1 * sqrt(length(manager.pods))
    start = time()
    asyncmap(values(manager.pods)) do pod
        sleep(rand() * sleeptime)
        while time() - start < manager.retry_seconds
            try
                delete!(manager.ctx, :Pod, pod.metadata.name)
                break
            catch e
                sleep(rand() * sleeptime)
            end
        end
    end
end
