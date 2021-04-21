function rdict(args...)
    DefaultOrderedDict{String,Any,typeof(rdict)}(rdict, OrderedDict{String,Any}(args...))
end

const POD_TEMPLATE =
    rdict("kind" => "Pod",
          "metadata" => rdict(),
          "spec" => rdict("restartPolicy" => "Never",
                          "containers" => []))


function _KuberContext(namespace=DEFAULT_NAMESPACE)
    ctx = KuberContext()
    set_ns(ctx, namespace)
    return ctx
end

function _set_api_versions!(ctx::KuberContext)
    isempty(ctx.apis) && Kuber.set_api_versions!(ctx)
    return ctx
end


function get_pod(ctx, pod_name)
    # The following code is equivalent to calling Kuber's `get(ctx, :Pod, pod_name)`
    # but reduces noise by avoiding nested rethrow calls.
    # Fixed in Kuber.jl in: https://github.com/JuliaComputing/Kuber.jl/pull/26
    isempty(ctx.apis) && Kuber.set_api_versions!(ctx)
    api_ctx = Kuber._get_apictx(ctx, :Pod, nothing)
    return Kuber.readNamespacedPod(api_ctx, pod_name, ctx.namespace)
end


"""
    worker_pod_spec(pod=POD_TEMPLATE; kwargs...)

Generate pod specification representing a Julia worker inside a single container.
"""
function worker_pod_spec(pod::AbstractDict=POD_TEMPLATE; kwargs...)
    return worker_pod_spec!(deepcopy(pod); kwargs...)
end

function worker_pod_spec!(pod::AbstractDict;
                          port::Integer,
                          cmd::Cmd,
                          driver_name::String,
                          image::String,
                          cpu=DEFAULT_WORKER_CPU,
                          memory=DEFAULT_WORKER_MEMORY,
                          service_account_name=nothing)
    pod["metadata"]["name"] = "$(driver_name)-worker-$port"

    cmd = `$cmd --bind-to=0:$port`

    worker_container =
        rdict("name" => "worker",
              "image" => image,
              "command" => collect(cmd),
              "resources" => rdict("requests" => rdict("cpu" => cpu,
                                                       "memory" => memory),
                                   "limits"   => rdict("cpu" => cpu,
                                                       "memory" => memory)))

    push!(pod["spec"]["containers"], worker_container)

    if service_account_name !== nothing
        pod["spec"]["serviceAccountName"] = service_account_name
    end

    return pod
end


"""
    isk8s() -> Bool

Predicate for testing if the current process is running within a Kubernetes pod.
"""
function isk8s()
    in_kubepod = false
    @mock(isfile("/proc/self/cgroup")) || return in_kubepod
    @mock open("/proc/self/cgroup") do fp
        while !eof(fp)
            line = chomp(readline(fp))
            path_name = split(line, ':')[3]
            if startswith(path_name, "/kubepods/")
                in_kubepod = true
                break
            end
        end
    end
    return in_kubepod
end
