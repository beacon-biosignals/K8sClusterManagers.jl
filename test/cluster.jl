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

# Note: `kubectl apply` will only spawn a new job if there is a change to the job
# specification in the rendered manifest. If we simply used `GIT_REV` for as the image tag
# than any dirty changes may be ignored.
#
# Alternative solutions:
# - Use `imagePullPolicy: Always` (doesn't work with local images)
# - Introduce a unique label (modify the template)
# - Delete the old job first
# - Possibly switching to a pod for the manager instead of a job
const TAG = if !isempty(read(`git --git-dir $GIT_DIR status --short`))
    "$GIT_REV-dirty-$(getpid())"
else
    GIT_REV  # Re-runs here may just use the old job
end

const JOB_TEMPLATE = Mustache.load(joinpath(@__DIR__, "job.template.yaml"))
const TEST_IMAGE = get(ENV, "K8S_CLUSTER_MANAGERS_TEST_IMAGE", "k8s-cluster-managers:$TAG")

const POD_NAME_REGEX = r"Worker pod (?<worker_id>\d+): (?<pod_name>[a-z0-9.-]+)"

# As a convenience we'll automatically build the Docker image when a user uses `Pkg.test()`.
# If the environmental variable is set we expect the Docker image has already been built.
if !haskey(ENV, "K8S_CLUSTER_MANAGERS_TEST_IMAGE")
    run(`docker build -t $TEST_IMAGE $PKG_DIR`)

    # Alternate build call which works on Apple Silicon
    # run(`docker build --platform x86_64 -t $TEST_IMAGE $PKG_DIR`)
    # run(pipeline(`docker save $TEST_IMAGE`, `minikube ssh --native-ssh=false -- docker load`))
end

pod_exists(pod_name) = success(`kubectl get pod/$pod_name`)

# Will fail if called and the job is in state "Waiting"
pod_logs(pod_name) = read(ignorestatus(`kubectl logs $pod_name`), String)

# https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-phase
pod_phase(pod_name) = read(`kubectl get pod/$pod_name -o 'jsonpath={.status.phase}'`, String)

function job_pods(job_name, labels::Pair...)
    selectors = Dict{String,String}(labels)
    selectors["job-name"] = job_name
    selector = join(map(p -> join(p, '='), collect(pairs(selectors))), ',')

    # Adapted from: https://kubernetes.io/docs/concepts/workloads/controllers/job/#running-an-example-job
    jsonpath = "{range .items[*]}{.metadata.name}{\"\\n\"}{end}"
    output = read(`kubectl get pods -l $selector -o=jsonpath=$jsonpath`, String)
    return split(output, '\n')
end

# Use the double-quoted flow scalar style to allow us to have a YAML string which includes
# newlines without being aware of YAML indentation (block styles)
#
# The double-quoted style allows us to use escape sequences via `\` but requires us to
# escape uses of `\` and `"`. It so happens that `escape_string` follows the same rules
escape_yaml_string(str::AbstractString) = escape_string(str)

let job_name = "test-success"
    @testset "$job_name" begin
        code = """
            using Distributed, K8sClusterManagers

            # Avoid trying to pull local-only image
            function configure(ko)
                ko.spec.containers[1].imagePullPolicy = "Never"
                return ko
            end
            K8sClusterManagers.addprocs_pod(1; configure, retry_seconds=60, memory="2Gi")

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

        # Wait for job to reach status: "Complete" or "Failed".
        #
        # There are a few scenarios where the job may become stuck:
        # - Insufficient cluster resources (pod stuck in the "Pending" status)
        # - Local Docker image does not exist (ErrImageNeverPull)
        @info "Waiting for $job_name job. This could take up to 4 minutes..."
        job_status_cmd = `kubectl get job/$job_name -o 'jsonpath={..status..type}'`
        result = timedwait(4 * 60; pollint=10) do
            !isempty(read(job_status_cmd, String))
        end

        manager_pod = first(job_pods(job_name))
        worker_pod = "$manager_pod-worker-9001"

        manager_log = pod_logs(manager_pod)
        matches = collect(eachmatch(POD_NAME_REGEX, manager_log))

        test_results = [
            @test read(job_status_cmd, String) == "Complete"

            @test pod_exists(manager_pod)
            @test pod_exists(worker_pod)

            @test pod_phase(manager_pod) == "Succeeded"
            @test_broken pod_phase(worker_pod) == "Succeeded"

            @test length(matches) == 1
            @test matches[1][:worker_id] == "2"
            @test matches[1][:pod_name] == worker_pod
        ]

        # Display details to assist in debugging the failure
        if any(r -> !(r isa Test.Pass || r isa Test.Broken), test_results)
            cmd = `kubectl describe job/$job_name`
            @info "Describe job:\n" * read(ignorestatus(cmd), String)

            # Note: A job doesn't contain a direct reference to the pod it starts so
            # re-using the job name can result in us identifying the wrong manager pod.
            cmd = `kubectl get pods -L job-name=$job_name`
            @info "List pods:\n" * read(ignorestatus(cmd), String)

            if pod_exists(manager_pod)
                cmd = `kubectl describe pod/$manager_pod`
                @info "Describe manager pod:\n" * read(cmd, String)
            else
                @info "Manager pod \"$manager_pod\" not found"
            end

            if pod_exists(worker_pod)
                cmd = `kubectl describe pod/$worker_pod`
                @info "Describe worker pod:\n" * read(cmd, String)
            else
                @info "Worker pod \"$worker_pod\" not found"
            end

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
        end
    end
end
