using DataStructures: OrderedDict

function k8s_create(manifest::IO)
    kubectl() do exe
        open(`$exe apply --force -f -`, "w", stdout) do p
            write(p.in, read(manifest))
        end
    end
end

function get_job(name::AbstractString; jsonpath=nothing)
    output = if jsonpath !== nothing
        "jsonpath=$jsonpath"
    else
        "json"
    end

    err = IOBuffer()
    out = kubectl() do exe
        read(pipeline(ignorestatus(`$exe get job/$name -o $output`), stderr=err), String)
    end

    err.size > 0 && throw(KubeError(err))
    return output == "json" ? JSON.parse(out; dicttype=OrderedDict) : out
end

pod_exists(pod_name) = kubectl(exe -> success(`$exe get pod/$pod_name`))

# Will fail if called and the job is in state "Waiting"
pod_logs(pod_name) = kubectl(exe -> read(ignorestatus(`$exe logs $pod_name`), String))

# https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-phase
pod_phase(pod_name) = kubectl(exe -> read(`$exe get pod/$pod_name -o 'jsonpath={.status.phase}'`, String))

function pod_names(labels::Pair...)
    selectors = Dict{String,String}(labels)
    selector = join(map(p -> join(p, '='), collect(pairs(selectors))), ',')

    # Adapted from: https://kubernetes.io/docs/concepts/workloads/controllers/job/#running-an-example-job
    jsonpath = "{range .items[*]}{.metadata.name}{\"\\n\"}{end}"
    output = kubectl() do exe
        read(`$exe get pods -l $selector -o=jsonpath=$jsonpath`, String)
    end
    return split(output, '\n')
end

# Use the double-quoted flow scalar style to allow us to have a YAML string which includes
# newlines without being aware of YAML indentation (block styles)
#
# The double-quoted style allows us to use escape sequences via `\` but requires us to
# escape uses of `\` and `"`. It so happens that `escape_string` follows the same rules
escape_yaml_string(str::AbstractString) = escape_string(str)

randsuffix(len=5) = randstring(['a':'z'; '0':'9'], len)


function report(job_name, pods::Pair...)
    kubectl() do exe
        cmd = `$exe describe job/$job_name`
        @info "Describe job:\n" * read(ignorestatus(cmd), String)
    end

    # Note: A job doesn't contain a direct reference to the pod it starts so
    # re-using the job name can result in us identifying the wrong manager pod.
    kubectl() do exe
        cmd = `$exe get pods -L job-name=$job_name`
        @info "List pods for job $job_name:\n" * read(ignorestatus(cmd), String)
    end

    for (title, pod_name) in pods
        if pod_exists(pod_name)
            kubectl() do exe
                cmd = `$exe describe pod $pod_name`
                @info "Describe $title pod:\n" * read(cmd, String)
            end
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
