using DataStructures: OrderedDict

function k8s_create(manifest::IO)
    open(`$(kubectl()) apply --force -f -`, "w", stdout) do p
        write(p.in, read(manifest))
    end
end

function get_job(name::AbstractString; jsonpath=nothing)
    output = if jsonpath !== nothing
        "jsonpath=$jsonpath"
    else
        "json"
    end

    kubectl_cmd = `$(kubectl()) get job/$name -o $output`
    err = IOBuffer()
    out = read(pipeline(ignorestatus(kubectl_cmd), stderr=err), String)

    err.size > 0 && throw(KubeError(err))
    return output == "json" ? JSON.parse(out; dicttype=OrderedDict) : out
end

function wait_job(job_name; condition=!isempty, timeout=60)
    timedwait(timeout; pollint=10) do
        condition(get_job(job_name, jsonpath="{.status..type}"))
    end
end

function delete_job(name::AbstractString; wait::Bool=true)
    kubectl_cmd = `$(kubectl()) delete job/$name --wait=$wait`
    err = IOBuffer()
    run(pipeline(ignorestatus(kubectl_cmd), stdout=devnull, stderr=err))

    err.size > 0 && throw(KubeError(err))
    return nothing
end

pod_exists(pod_name) = success(`$(kubectl()) get pod/$pod_name`)

# Will fail if called and the job is in state "Waiting"
pod_logs(pod_name) = read(ignorestatus(`$(kubectl()) logs $pod_name`), String)

# https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-phase
pod_phase(pod_name) = read(`$(kubectl()) get pod/$pod_name -o 'jsonpath={.status.phase}'`, String)

function pod_names(labels::Pair...; sort_by=nothing)
    selectors = Dict{String,String}(labels)
    selector = join(map(p -> join(p, '='), collect(pairs(selectors))), ',')

    # Adapted from: https://kubernetes.io/docs/concepts/workloads/controllers/job/#running-an-example-job
    jsonpath = "{range .items[*]}{.metadata.name}{\"\\n\"}{end}"
    sort_by_opt = sort_by !== nothing ? `--sort-by=$sort_by` : ``
    kubectl_cmd = `$(kubectl()) get pods -l $selector -o=jsonpath=$jsonpath $sort_by_opt`
    output = readchomp(kubectl_cmd)
    return !isempty(output) ? split(output, '\n') : String[]
end

function pod_images(pod_name)
    jsonpath = """{range .spec.containers[*]}{.image}{"\\n"}{end}"""
    output = readchomp(`$(kubectl()) get pod/$pod_name -o jsonpath=$jsonpath`)
    return split(output, '\n'; keepempty=false)
end

# Use the double-quoted flow scalar style to allow us to have a YAML string which includes
# newlines without being aware of YAML indentation (block styles)
#
# The double-quoted style allows us to use escape sequences via `\` but requires us to
# escape uses of `\` and `"`. It so happens that `escape_string` follows the same rules
escape_yaml_string(str::AbstractString) = escape_string(str)

randsuffix(len=5) = randstring(['a':'z'; '0':'9'], len)


function report(job_name, pods::Pair...)
    kubectl_cmd = `$(kubectl()) describe job/$job_name`
    @info "Describe job:\n" * read(ignorestatus(kubectl_cmd), String)

    # Note: A job doesn't contain a direct reference to the pod it starts so
    # re-using the job name can result in us identifying the wrong manager pod.
    kubectl_cmd = `$(kubectl()) get pods -L job-name=$job_name`
    @info "List pods for job $job_name:\n" * read(ignorestatus(kubectl_cmd), String)

    for (title, pod_name) in pods
        if pod_exists(pod_name)
            kubectl_cmd = `$(kubectl()) describe pod $pod_name`
            @info "Describe $title pod:\n" * read(kubectl_cmd, String)
        else
            @info "$(titlecase(title)) pod \"$pod_name\" not found"
        end
    end

    for (title, pod_name) in pods
        if pod_exists(pod_name)
            @info "Logs for $title ($pod_name):\n" * pod_logs(pod_name)
        else
            @info "No logs for $title ($pod_name)"
        end
    end
end

function minikube_docker_env()
    env_vars = Pair{String,String}[]
    open(`minikube docker-env`) do f
        while !eof(f)
            line = readline(f)

            if startswith(line, "export")
                line = replace(line, r"^export " => "")
                key, value = split(line, '='; limit=2)
                push!(env_vars, key => unquote(value))
            end
        end
    end

    return env_vars
end

isquoted(str::AbstractString) = startswith(str, '"') && endswith(str, '"')

function unquote(str::AbstractString)
    if isquoted(str)
        return replace(SubString(str, 2, lastindex(str) - 1), "\\\"" => "\"")
    else
        throw(ArgumentError("Passed in string is not quoted"))
    end
end
