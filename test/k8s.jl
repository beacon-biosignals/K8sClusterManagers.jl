using LibGit2
using Mustache
using Test

const PKG_DIR = abspath(@__DIR__, "..")
const GIT_DIR = joinpath(PKG_DIR, ".git")
const GIT_REV = try
    readchomp(`git --git-dir $GIT_DIR rev-parse --short HEAD`)
catch
    # Fallback to using the full SHA when git is not installed
    LibGit2.with(LibGit2.GitRepo(GIT_DIR)) do repo
        string(LibGit2.GitHash(LibGit2.GitObject(repo, "HEAD")))
    end
end

const TEST_IMAGE = "k8s-cluster-managers:$GIT_REV"
const JOB_TEMPLATE = Mustache.load(joinpath(@__DIR__, "job.template.yaml"))

function parse_env(str::AbstractString)
    env = Pair{String,String}[]
    for line in split(str, '\n')
        if startswith(line, "export")
            name, value = split(replace(line, "export " => ""), '=')
            value = replace(value, r"^([\"'])(.*)\1$" => s"\2")
            push!(env, name => value)
        end
    end

    return env
end

# TODO: Look into alternative way of accessing the image inside of minikube that is agnostic
# of the local Kubernetes distro being used: https://minikube.sigs.k8s.io/docs/handbook/pushing/
withenv(parse_env(read(`minikube docker-env`, String))...) do
    run(`docker build -t $TEST_IMAGE $PKG_DIR`)
end

function manager_start(job_name, code)
    job_yaml = render(JOB_TEMPLATE,
                      job_name=job_name,
                      image=TEST_IMAGE,
                      command=["julia", "-e", code])

    p = open(`kubectl apply -f -`, "w+")
    write(p.in, job_yaml)
    close(p.in)
    return read(p.out, String)
end


function pod_logs(pod_name)
    if success(`kubectl get pod/$pod_name`)
        read(`kubectl logs $pod_name`, String)
    else
        nothing
    end
end

escape_quotes(str::AbstractString) = replace(str, r"\"" => "\\\"")

let job_name = "test-worker-success"
    @testset "$job_name" begin
        code = """
            using Distributed, K8sClusterManagers
            K8sClusterManagers.addprocs_pod(1, retry_seconds=60)

            println("Num Processes: ", nprocs())
            for i in workers()
                # TODO: HOSTNAME is the name of the pod. Maybe should return other info
                println("Worker pod \$i: ", remotecall_fetch(() -> ENV["HOSTNAME"], i))
            end
            """

        # TODO: As Mustache.jl is primarily meant for HTML templating it isn't smart enough
        # to escape double-quotes found inside `code`. We should investigate better
        # approaches to this templating problem
        command = ["julia", "-e", replace(escape_quotes(code), '\n' => "\\n")]
        @show command
        config = render(JOB_TEMPLATE; job_name, image=TEST_IMAGE, command)
        @info config
        open(`kubectl apply --force -f -`, "w", stdout) do p
            write(p.in, config)
        end

        # Wait for job to reach status: "Complete" or "Failed"
        job_status_cmd = `kubectl get job/$job_name -o 'jsonpath={..status..type}'`
        while isempty(read(job_status_cmd, String))
            sleep(1)
        end

        # TODO: Query could return more than one result
        manager_pod = read(`kubectl get pods -l job-name=$job_name -o 'jsonpath={..metadata.name}'`, String)
        worker_pod = "$manager_pod-worker-9001"
        @show manager_pod

        @info "Describe manager:\n" * read(`kubectl describe pod/$manager_pod`, String)

        @info "Logs for manager:\n" * string(pod_logs(manager_pod))
        @info "Logs for worker:\n" * string(pod_logs(worker_pod))
    end
end
