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
    err = IOBuffer()
    out = kubectl() do exe
        read(pipeline(ignorestatus(`$exe get pod/$name -o json`), stderr=err), String)
    end

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

    out = IOBuffer()
    err = IOBuffer()
    kubectl() do exe
        open(pipeline(ignorestatus(`$exe create -f -`), stdout=out, stderr=err), "w") do p
            write(p.in, JSON.json(manifest))
        end
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
    delete_pod(name::AbstractString) -> Nothing

Delete the pod with the given `name`.
"""
function delete_pod(name::AbstractString; wait::Bool=true)
    err = IOBuffer()
    kubectl() do exe
        cmd = `$exe delete pod/$name --wait=$wait`
        run(pipeline(ignorestatus(cmd), stdout=devnull, stderr=err))
    end

    err.size > 0 && throw(KubeError(err))
    return nothing
end


"""
    worker_pod_spec(pod=POD_TEMPLATE; kwargs...)

Generate a pod specification for a Julia worker inside a container.
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
    pod["metadata"]["generateName"] = "$(driver_name)-worker-$port"

    # Set a label with the manager name to support easy termination of all workers
    pod["metadata"]["labels"]["manager"] = driver_name

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
