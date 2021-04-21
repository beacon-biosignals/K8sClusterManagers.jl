const EMPTY_POD =
    json(Dict("kind" => "Pod",
              "metadata" => Dict(),
              "spec" => Dict("restartPolicy" => "Never",
                             "tolerations" => [],
                             "containers" => [],
                             "affinity" => Dict())))


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
    worker_pod_spec(ctx; kwargs...)

Generate a Kuber object representing pod with a single worker container.
"""
function worker_pod_spec(ctx;
                         port::Integer,
                         cmd::Cmd,
                         driver_name::String,
                         image::String,
                         cpu=DEFAULT_WORKER_CPU,
                         memory=DEFAULT_WORKER_MEMORY,
                         service_account_name=nothing,
                         base_obj=kuber_obj(_set_api_versions!(ctx), EMPTY_POD))
    ko = base_obj
    ko.metadata.name = "$(driver_name)-worker-$port"
    cmdo = `$cmd --bind-to=0:$port`
    push!(ko.spec.containers,
          json(Dict("name" => "$(driver_name)-worker-$port",
                    "image" => image,
                    "command" => collect(cmdo),
                    "resources" => Dict("requests" => Dict("memory" => memory,
                                                           "cpu" => cpu)),
                                        "limit"    => Dict("memory" => memory,
                                                           "cpu" => cpu))))
    if service_account_name !== nothing
        ko.spec.serviceAccountName = service_account_name
    end

    return ko
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
