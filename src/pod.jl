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

function get_pod(pod_name::AbstractString)
    err = IOBuffer()
    out = kubectl() do exe
        read(pipeline(ignorestatus(`$exe get pod/$pod_name -o json`), stderr=err), String)
    end

    err.size > 0 && throw(KubeError(err))
    return JSON.parse(out)
end

function create_pod(manifest::AbstractDict)
    if manifest["kind"] != "Pod"
        error("Manifest expected to be of kind \"Pod\" and not \"$(manifest["kind"])\"")
    end

    err = IOBuffer()
    kubectl() do exe
        open(pipeline(ignorestatus(`$exe create -f -`), stderr=err), "w") do p
            write(p.in, JSON.json(manifest))
        end
    end

    err.size > 0 && throw(KubeError(err))
    return nothing
end

function delete_pod(pod_name::AbstractString)
    err = IOBuffer()
    kubectl() do exe
        run(pipeline(ignorestatus(`$exe delete pod/$pod_name`), stderr=err))
    end

    err.size > 0 && throw(KubeError(err))
    return nothing
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
