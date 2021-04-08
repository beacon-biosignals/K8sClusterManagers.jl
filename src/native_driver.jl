const EMPTY_POD = \
    json(Dict("kind" => "Pod",
              "metadata" => Dict(),
              "spec" => Dict("restartPolicy" => "Never",
                             "tolerations" => [],
                             "containers" => [],
                             "affinity" => Dict())))

"""
    self_pod(ctx::KuberContext)

Kuber object representing the pod this julia session is running in.
"""
function self_pod(ctx)
    return get(ctx, :Pod, ENV["HOSTNAME"])
end


"""
    default_pod(ctx, port, cmd::Cmd, driver_name::String; image=nothing, memory::String="4Gi", cpu::String="1", base_obj=kuber_obj(ctx, EMPTY_POD))

Kuber object representing a pod with a single worker container.

If `isnothing(image) == true`, the driver pod is required to have a single container, whose image will be used.
"""
function default_pod(ctx, port, cmd::Cmd, driver_name::String; image=nothing, memory::String="4Gi", cpu::String="1", serviceAccountName=nothing, base_obj=kuber_obj(ctx, EMPTY_POD), kwargs...)
    ko = base_obj
    ko.metadata.name = "$(driver_name)-worker-$port"
    cmdo = `$cmd --bind-to=0:$port`
    if isnothing(image)
        self = self_pod(ctx)
        if length(self.spec.containers) > 1
            error("`default_pod` called with `image = nothing`, driver pod must contain a single container: use `configure` closure kwarg to set worker images manually.")
        end
        image = last(self.spec.containers).image
    end
    push!(ko.spec.containers,
          json(Dict("name" => "$(driver_name)-worker-$port",
                    "image" => image,
                    "command" => collect(cmdo),
                    "resources" => Dict("requests" => Dict("memory" => memory,
                                                           "cpu" => cpu)),
                                        "limit"    => Dict("memory" => memory,
                                                           "cpu" => cpu))))
    if !isnothing(serviceAccountName)
        ko.spec.serviceAccountName = serviceAccountName
    end
    return ko
end

function default_pods_and_context(namespace="default"; configure, ports, driver_name::String="driver", cmd::Cmd=`julia $(worker_arg())`, kwargs...)
    ctx = KuberContext()
    Kuber.set_api_versions!(ctx; verbose=false)
    set_ns(ctx, namespace)
    pods = Dict(port => configure(default_pod(ctx, port, cmd, driver_name; kwargs...)) for port in ports)
    return pods, ctx
end

struct K8sNativeManager <: ClusterManager
    ctx::Any
    pods::Dict{Int, Any}
    retry_seconds::Int
    function K8sNativeManager(ports,
                              driver_name::String,
                              cmd::Cmd;
                              configure=identity,
                              namespace::String="default",
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
    start = now()
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
            if now() - start > Second(manager.retry_seconds)
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
        start = now()
        try
            sleep(rand() * sleeptime)
            while now() - start < Second(manager.retry_seconds)
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
            start_delete = now()
            while now() - start_delete < Second(5)
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
                 namespace::String="default",
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
                      namespace::String="default",
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
    start = now()
    asyncmap(values(manager.pods)) do pod
        sleep(rand() * sleeptime)
        while now() - start < Second(manager.retry_seconds)
            try
                delete!(manager.ctx, :Pod, pod.metadata.name)
                break
            catch e
                sleep(rand() * sleeptime)
            end
        end
    end
end
