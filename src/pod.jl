function rdict(args...)
    DefaultOrderedDict{String,Any,typeof(rdict)}(rdict, OrderedDict{String,Any}(args...))
end

const POD_TEMPLATE =
    rdict("apiVersion" => "v1",
          "kind" => "Pod",
          "metadata" => rdict(),
          "spec" => rdict("restartPolicy" => "Never",
                          "containers" => []))


struct KubeError <: Exception
    msg::String
end

KubeError(io::IO) = KubeError(String(take!(io)))

Base.showerror(io::IO, e::KubeError) = print(io, "KubeError: ", e.msg)


"""
    get_pod(name::AbstractString) -> AbstractDict

Retrieve details about the specified pod as a JSON-compatible dictionary. If their is no
pod with the given `name` then a `$KubeError` will be raised.
"""
function get_pod(name::AbstractString)
    kubectl_cmd = `$(kubectl()) get pod/$name -o json`
    err = IOBuffer()
    out = read(pipeline(ignorestatus(kubectl_cmd), stderr=err), String)

    err.size > 0 && throw(KubeError(err))
    return JSON.parse(out; dicttype=OrderedDict)
end


"""
    create_pod(manifest::AbstractDict) -> String

Create a pod based upon the JSON-compatible `manifest`. Returns the name of the pod created.
"""
function create_pod(manifest::AbstractDict)
    # As `kubectl create` can create any resource we'll restrict this function to only
    # creating "Pod" resources.
    kind = manifest["kind"]
    if kind != "Pod"
        throw(ArgumentError("Manifest expected to be of kind \"Pod\" and not \"$kind\""))
    end

    kubectl_cmd = `$(kubectl()) create -f -`
    out = IOBuffer()
    err = IOBuffer()
    open(pipeline(ignorestatus(kubectl_cmd), stdout=out, stderr=err), "w") do p
        write(p.in, JSON.json(manifest))
    end

    err.size > 0 && throw(KubeError(err))

    # Extract the pod name from the output. Needed when using "generateName".
    out_str = String(take!(out))
    m = match(r"pod/(?<name>.*?) created", out_str)
    if m !== nothing
        return m[:name]
    else
        error("Unable to determine the pod name from: \"$out_str\"")
    end
end


"""
    label_pod(name::AbstractString, label::Pair) -> Nothing

Create or replace a metadata label for a given pod `name`. Requires the "patch" permission.
"""
function label_pod(name::AbstractString, label::Pair)
    kubectl_cmd = `$(kubectl()) label --overwrite pod/$name $(join(label, '='))`
    err = IOBuffer()
    run(pipeline(ignorestatus(kubectl_cmd), stdout=devnull, stderr=err))

    err.size > 0 && throw(KubeError(err))
    return nothing
end


"""
    delete_pod(name::AbstractString) -> Nothing

Delete the pod with the given `name`.
"""
function delete_pod(name::AbstractString; wait::Bool=true)
    kubectl_cmd = `$(kubectl()) delete pod/$name --wait=$wait`
    err = IOBuffer()
    run(pipeline(ignorestatus(kubectl_cmd), stdout=devnull, stderr=err))

    err.size > 0 && throw(KubeError(err))
    return nothing
end


"""
    wait_for_running_pod(name::AbstractString; timeout::Real) -> AbstractDict

Wait for the pod with the given `name` to reach the "Running" phase. If the phase is reached
before the `timeout` then the pod details will be returned, otherwise a `TimeoutException`
will be raised.
"""
function wait_for_running_pod(name::AbstractString; timeout::Real)
    pod = nothing

    # https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-phase
    result = timedwait(timeout; pollint=1) do
        pod = @mock get_pod(name)
        pod["status"]["phase"] != "Pending"
    end

    if result === :ok
        phase = pod !== nothing ? pod["status"]["phase"] : nothing

        if phase == "Running"
            return pod
        else
            error("Worker pod $name expected to in phase \"Running\" and instead is \"$phase\"")
        end
    else
        msg = "timed out after waiting for worker $name to start for $timeout seconds, " *
            "with status:\n" * JSON.json(pod["status"], 4)
        throw(TimeoutException(msg))
    end
end


"""
    exec_pod(name::AbstractString, cmd::Cmd) -> Nothing

Execute `cmd` on the `name`d pod. If the command fails a `KubeError` will be raised.
"""
function exec_pod(name::AbstractString, cmd::Cmd)
    # When an `exec` failure occurs there is some useful information in stdout and stderr
    kubectl_cmd = `$(kubectl()) exec pod/$name -- $cmd`
    err = IOBuffer()
    p = run(pipeline(ignorestatus(kubectl_cmd), stdout=err, stderr=err))

    !success(p) && throw(KubeError(err))
    return nothing
end


"""
    pod_status(name::AbstractString) -> Pair
    pod_status(resource::AbstractDict) -> Pair

Determine the current pod state and, if applicable, the associated reason.
"""
function pod_status end

function pod_status(resource::AbstractDict)
    kind = resource["kind"]
    if kind != "Pod"
        throw(ArgumentError("Manifest expected to be of kind \"Pod\" and not \"$kind\""))
    end

    container_statuses = resource["status"]["containerStatuses"]

    if length(container_statuses) != 1
        throw(ArgumentError("Currently on pods with a single container are supported"))
    end

    container_status = first(container_statuses)
    states = keys(container_status["state"])

    if length(states) != 1
        json = JSON.json("state" => container_status["state"])
        throw(ArgumentError("Currently only a single state is supported:\n$json"))
    end

    state = first(states)
    return state => get(container_status["state"][state], "reason", nothing)
end

pod_status(name::AbstractString) = pod_status(get_pod(name))


"""
    worker_pod_spec(pod=POD_TEMPLATE; kwargs...)

Generate a pod specification for a Julia worker inside a container.
"""
function worker_pod_spec(pod::AbstractDict=POD_TEMPLATE; kwargs...)
    return worker_pod_spec!(deepcopy(pod); kwargs...)
end

function worker_pod_spec!(pod::AbstractDict;
                          worker_prefix::AbstractString,
                          image::AbstractString,
                          cmd::Cmd,
                          cpu=DEFAULT_WORKER_CPU,
                          memory=DEFAULT_WORKER_MEMORY,
                          cluster_cookie::AbstractString=cluster_cookie(),
                          service_account_name=nothing)
    pod["metadata"]["generateName"] = "$(worker_prefix)-"

    # Set a label with the `worker_prefix` to support easy termination of all workers
    pod["metadata"]["labels"]["worker-prefix"] = worker_prefix
    pod["metadata"]["labels"]["cluster-cookie"] = cluster_cookie

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

Predicate for testing if the current process is running within a Kubernetes (K8s) pod.
"""
function isk8s()
    # https://kubernetes.io/docs/reference/kubectl/#in-cluster-authentication-and-namespace-overrides
    return haskey(ENV, "KUBERNETES_SERVICE_HOST") && haskey(ENV, "KUBERNETES_SERVICE_PORT")
end
