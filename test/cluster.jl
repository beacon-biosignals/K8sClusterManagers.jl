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
# withenv(parse_env(read(`minikube docker-env`, String))...) do
#     run(`docker build -t $TEST_IMAGE $PKG_DIR`)
# end

run(`docker build -t $TEST_IMAGE $PKG_DIR`)


pod_exists(pod_name) = success(`kubectl get pod/$pod_name`)
pod_logs(pod_name) = read(`kubectl logs $pod_name`, String)
pod_phase(pod_name) = read(`kubectl get pod/$pod_name -o 'jsonpath={.status.phase}'`, String)

# Use the double-quoted flow scalar style to allow us to have a YAML string which includes
# newlines without being aware of YAML indentation (block styles)
#
# The double-quoted style allows us to use escape sequences via `\` but requires us to
# escape uses of `\` and `"`. It so happens that `escape_string` follows the same rules
escape_yaml_string(str::AbstractString) = escape_string(str)

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

        command = ["julia", "-e", escape_yaml_string(code)]
        config = render(JOB_TEMPLATE; job_name, image=TEST_IMAGE, command)
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

        # @info "Describe manager:\n" * read(`kubectl describe pod/$manager_pod`, String)

        if pod_exists(manager_pod)
            @info "Logs for manager ($manager_pod):\n" * pod_logs(manager_pod)
        else
            @info "No logs for manager ($manager_pod)"
        end

        if pod_exists(worker_pod)
            @info "Logs for worker ($worker_pod):\n" * pod_logs(worker_pod)
        else
            @info "No logs for worker ($worker_pod)"
        end

        @test pod_exists(manager_pod)
        @test pod_exists(worker_pod)

        @test pod_phase(manager_pod) == "Succeeded"
        @test_broken pod_phase(worker_pod) == "Succeeded"
    end
end
