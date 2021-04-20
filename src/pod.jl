const EMPTY_POD =
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
    # The following code is equivalent to calling Kuber's `get(ctx, :Pod, ENV["HOSTNAME"])`
    # but reduces noise by avoiding nested rethrow calls.
    # Fixed in Kuber.jl in: https://github.com/JuliaComputing/Kuber.jl/pull/26
    isempty(ctx.apis) && Kuber.set_api_versions!(ctx)
    api_ctx = Kuber._get_apictx(ctx, :Pod, nothing)
    return Kuber.readNamespacedPod(api_ctx, ENV["HOSTNAME"], ctx.namespace)
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

function default_pods_and_context(namespace=current_namespace(); configure, ports, driver_name::String="driver", cmd::Cmd=`julia $(worker_arg())`, kwargs...)
    ctx = KuberContext()
    Kuber.set_api_versions!(ctx; verbose=false)
    set_ns(ctx, namespace)

    # Avoid using a generator with `Dict` as any raised exception would be displayed twice:
    # https://github.com/JuliaLang/julia/issues/33147
    pods = Dict([port => configure(default_pod(ctx, port, cmd, driver_name; kwargs...)) for port in ports])

    return pods, ctx
end
