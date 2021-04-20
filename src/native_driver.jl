
const empty_pod = """{
    "kind": "Pod",
    "metadata": {},
    "spec": {
        "restartPolicy": "Never",
        "tolerations": [],
        "containers": [],
        "affinity": {}
    }
}"""

const DEFAULT_NAMESPACE = "default"
const NAMESPACE_FILE = "/var/run/secrets/kubernetes.io/serviceaccount/namespace"


"""
    config_namespace() -> Union{String,Nothing}

Determine the Kubernetes namespace as specified by the current config context. If the
namespace is not set, the current context is not set, or the current context is not defined
then `nothing` will be returned.
"""
function config_namespace()
    # https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/
    #
    # Equivalent to running `kubectl config view --minify --output='jsonpath={..namespace}'`
    # but improves handling of corner cases.
    kubectl() do exe
        context = read(`$exe config view --output='jsonpath={.current-context}'`, String)
        isempty(context) && return nothing

        # Note: The output from `kubectl config view` reports a missing `namespace` entry,
        # `namespace: null`, and `namespace: ""` as the same.
        output = "jsonpath={.contexts[?(@.name=='$context')].context.namespace}"
        namespace = read(`$exe config view --output=$output`, String)
        return !isempty(namespace) ? namespace : nothing
    end
end


"""
    pod_namespace() -> Union{String,Nothing}

Determine the namespace of the pod if running inside of a Kubernetes pod, otherwise return
`nothing`.
"""
function pod_namespace()
    return if @mock isfile(NAMESPACE_FILE)
        @mock read(NAMESPACE_FILE, String)
    else
        nothing
    end
end


"""
    current_namespace() -> String

Determine the Kubernetes namespace as specified by the current config or, when running
inside a pod, the namespace of the pod. If the namespace is cannot be determined the default
namespace ("$DEFAULT_NAMESPACE") will be returned.
"""
function current_namespace()
    namespace = config_namespace()
    namespace !== nothing && return namespace

    namespace = pod_namespace()
    namespace !== nothing && return namespace

    return DEFAULT_NAMESPACE
end


"""
    self_pod(ctx::KuberContext)

Kuber object representing the pod this julia session is running in.
"""
function self_pod(ctx)
    # The following code is equivalent to calling Kuber's `get(ctx, :Pod, ENV["HOSTNAME"])`
    # but reduces noise by avoiding nested rethrow calls.
    # Fixed in Kuber.jl in: https://github.com/JuliaComputing/Kuber.jl/pull/26
    isempty(ctx.apis) && Kuber.set_api_versions!(ctx)
    api_ctx = Kuber._get_apictx(ctx, :Pod, nothing)
    return Kuber.readNamespacedPod(api_ctx, ENV["HOSTNAME"], ctx.namespace)
end


"""
    default_pod(ctx, port, cmd::Cmd, driver_name::String; image=nothing, memory::String="4Gi", cpu::String="1", base_obj=kuber_obj(ctx, empty_pod))

Kuber object representing a pod with a single worker container.

If `isnothing(image) == true`, the driver pod is required to have a single container, whose image will be used.
"""
function default_pod(ctx, port, cmd::Cmd, driver_name::String; image=nothing, memory::String="4Gi", cpu::String="1", serviceAccountName=nothing, base_obj=kuber_obj(ctx, empty_pod), kwargs...)
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
    push!(ko.spec.containers, """{
        "name": "$(driver_name)-worker-$port",
        "image": "$image",
        "command": $(json(collect(cmdo))),
        "resources": {
            "requests": {
                "memory": "$memory",
                "cpu": "$cpu"
            },
            "limits": {
                "memory": "$memory",
                "cpu": "$cpu"
            }
        },
        "imagePullPolicy": "Always"
    }""")
    if !isnothing(serviceAccountName)
        ko.spec.serviceAccountName = serviceAccountName
    end
    return ko
end

function default_pods_and_context(namespace=current_namespace(); configure, ports, driver_name::String="driver", cmd::Cmd=`julia $(worker_arg())`, kwargs...)
    ctx = KuberContext()
    Kuber.set_api_versions!(ctx; verbose=false)
    set_ns(ctx, namespace)

    # Avoid using a generator with `Dict` as any raised exception would be displayed twice:
    # https://github.com/JuliaLang/julia/issues/33147
    pods = Dict([port => configure(default_pod(ctx, port, cmd, driver_name; kwargs...)) for port in ports])

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
