const EMPTY_POD =
    json(Dict("kind" => "Pod",
              "metadata" => Dict(),
              "spec" => Dict("restartPolicy" => "Never",
                             "tolerations" => [],
                             "containers" => [],
                             "affinity" => Dict())))


function kuber_context(namespace=current_namespace())
    ctx = KuberContext()
    Kuber.set_api_versions!(ctx; verbose=false)
    set_ns(ctx, namespace)
    return ctx
end

"""
    self_pod(ctx::KuberContext)

Kuber object representing the pod this julia session is running in.
"""
self_pod(ctx) = get_pod(ctx, ENV["HOSTNAME"])


function get_pod(ctx, pod_name)
    # The following code is equivalent to calling Kuber's `get(ctx, :Pod, ENV["HOSTNAME"])`
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
                         cpu::String=DEFAULT_WORKER_CPU,
                         memory::String=DEFAULT_WORKER_MEMORY,
                         service_account_name=nothing,
                         base_obj=kuber_obj(ctx, EMPTY_POD))
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
