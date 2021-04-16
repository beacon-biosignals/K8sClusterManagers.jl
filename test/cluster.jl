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

const JOB_TEMPLATE = Mustache.load(joinpath(@__DIR__, "job.template.yaml"))
const TEST_IMAGE = get(ENV, "K8S_CLUSTER_MANAGERS_TEST_IMAGE", "k8s-cluster-managers:$GIT_REV")

# As a convenience we'll automatically build the Docker image when a user uses `Pkg.test()`.
# If the environmental variable is set we expect the Docker image has already been built.
if !haskey(ENV, "K8S_CLUSTER_MANAGERS_TEST_IMAGE")
    run(`docker build -t $TEST_IMAGE $PKG_DIR`)
end

pod_exists(pod_name) = success(`kubectl get pod/$pod_name`)
pod_logs(pod_name) = read(`kubectl logs $pod_name`, String)

# https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-phase
pod_phase(pod_name) = read(`kubectl get pod/$pod_name -o 'jsonpath={.status.phase}'`, String)

function job_pods(job_name)
    # Adapted from: https://kubernetes.io/docs/concepts/workloads/controllers/job/#running-an-example-job
    jsonpath = "{range .items[*]}{.metadata.name}{\"\\n\"}{end}"
    output = read(`kubectl get pods -l job-name=$job_name -o=jsonpath=$jsonpath`, String)
    return split(output, '\n')
end

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
            K8sClusterManagers.addprocs_pod(1, retry_seconds=60, memory="2Gi")

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
        manager_pod = nothing
        worker_pod = nothing

        # TODO: There are a few scenarios in which this wait loop could just hang:
        # - Pod stuck as pending due to not enough cluster resources
        # - Failure to pull Docker image will cause job not to complete
        while isempty(read(job_status_cmd, String))
            if manager_pod === nothing
                manager_pod = first(job_pods(job_name))
                worker_pod = "$manager_pod-worker-9001"
            elseif pod_phase(manager_pod) in ("Failed", "Unknown")
                break
            end

            @info read(ignorestatus(`kubectl describe job/$job_name`), String)
            @info read(ignorestatus(`kubectl get pods -L job-name=$job_name`), String)
            if manager_pod !== nothing && pod_exists(manager_pod)
                @info "Describe manager pod ($manager_pod):\n" * read(ignorestatus(`kubectl describe pod/$manager_pod`), String)
                @info pod_phase(manager_pod)
            end
            if worker_pod !== nothing && pod_exists(worker_pod)
                @info "Describe worker pod ($worker_pod):\n" * read(ignorestatus(`kubectl describe pod/$worker_pod`), String)
                @info pod_phase(worker_pod)
            end

            sleep(20)
        end

        manager_pod = first(job_pods(job_name))
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
