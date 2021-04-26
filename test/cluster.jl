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
    # run(pipeline(`docker save $TEST_IMAGE`, `minikube ssh --native-ssh=false -- docker load`))
end


@testset "pod control" begin
    pod_control_manifest = YAML.load_file(joinpath(@__DIR__, "pod-control.yaml"))

    # Overwrite some parts of the specification
    # Note: We don't need to use the `TEST_IMAGE` here but it avoid having to download
    # another Docker image.
    pod_control_manifest["spec"]["containers"][1]["image"] = TEST_IMAGE
    pod_control_manifest["spec"]["containers"][1]["imagePullPolicy"] = "Never"

    @testset "named" begin
        manifest = deepcopy(pod_control_manifest)

        # Note: We do not want to use "generateName" here we want to use the same name when we
        # call `create_pod` multiple times. However, we do want to avoid conflicts with previous
        # `Pkg.test` executions.
        name = "test-pod-control-named-" * randsuffix()
        manifest["metadata"]["name"] = name

        @test_throws KubeError get_pod(name)
        @test_throws KubeError delete_pod(name)

        @info "Creating pod $name"
        create_pod(manifest)

        @test_throws KubeError create_pod(manifest)
        @test get_pod(name)["status"]["phase"] == "Pending"

        @info "Waiting for pod to start..."
        while get_pod(name)["status"]["phase"] == "Pending"
            sleep(1)
        end

        @test get_pod(name)["status"]["phase"] == "Running"

        # Avoid deleting the pod if we've reached a unhandled phase. This allows for
        # investigation with `kubectl`.
        if get_pod(name)["status"]["phase"] == "Running"
            @info "Deleting pod $name"
            # Avoid waiting for the pod to be deleted as this can take some time
            delete_pod(name, wait=false)

            # Note: Ideally we would be able to capture the "Terminating" status as reported by
            # `kubectl get pods -w`. Unforturnately I'm not sure how to retrieve this
            # information as it does not seem to be reported by `kubectl get pod` or
            # `kubectl get events`.
            reason = nothing
            while reason === nothing || reason == "Started"
                reason = kubectl() do exe
                    output = "jsonpath={.items[-1:].reason}"
                    read(`$exe get events --field-selector involvedObject.name=$name -o=$output`, String)
                end
            end

            @test reason == "Killing"
        else
            @warn "Skipping deletion of pod $name"
        end

        # TODO: Would be nice to show details of the pod if any of these tests fail
    end

    @testset "generate name" begin
        manifest = deepcopy(pod_control_manifest)

        prefix = "test-pod-control-generate-name-"
        delete!(manifest["metadata"], "name")
        manifest["metadata"]["generateName"] = prefix

        name_a = create_pod(manifest)
        name_b = create_pod(manifest)

        @test name_a != name_b
        @test startswith(name_a, prefix)
        @test startswith(name_b, prefix)

        delete_pod(name_a, wait=false)
        delete_pod(name_b, wait=false)
    end

    @testset "wait_for_running_pod" begin
        manifest = deepcopy(pod_control_manifest)

        prefix = "test-pod-control-wait-"
        delete!(manifest["metadata"], "name")
        manifest["metadata"]["generateName"] = prefix

        name = create_pod(manifest)

        @test_throws K8sClusterManagers.TimeoutException wait_for_running_pod(name; timeout=1)
        pod = wait_for_running_pod(name; timeout=30)
        @test pod["status"]["phase"] == "Running"

        delete_pod(name, wait=false)
    end
end

let job_name = "test-success"
    @testset "$job_name" begin
        code = """
            using Distributed, K8sClusterManagers

            # Avoid trying to pull local-only image
            function configure(pod)
                pod["spec"]["containers"][1]["imagePullPolicy"] = "Never"
                return pod
            end
            addprocs(K8sClusterManager(1; configure, retry_seconds=60, cpu="0.5", memory="300Mi"))

            println("Num Processes: ", nprocs())
            for i in workers()
                # Return the name of the pod via HOSTNAME
                println("Worker pod \$i: ", remotecall_fetch(() -> ENV["HOSTNAME"], i))
            end
            """

        command = ["julia"]
        args = ["-e", escape_yaml_string(code)]
        manifest = render(JOB_TEMPLATE; job_name, image=TEST_IMAGE, command, args)
        k8s_create(IOBuffer(manifest))

        # Wait for job to reach status: "Complete" or "Failed".
        #
        # There are a few scenarios where the job may become stuck:
        # - Insufficient cluster resources (pod stuck in the "Pending" status)
        # - Local Docker image does not exist (ErrImageNeverPull)
        @info "Waiting for $job_name job. This could take up to 4 minutes..."
        wait_job(job_name, condition=!isempty, timeout=4 * 60)

        manager_pod = first(pod_names("job-name" => job_name))
        worker_pod = first(pod_names("manager" => manager_pod))

        manager_log = pod_logs(manager_pod)
        matches = collect(eachmatch(POD_NAME_REGEX, manager_log))

        test_results = [
            @test get_job(job_name, jsonpath="{.status..type}") == "Complete"

            @test pod_exists(manager_pod)
            @test pod_exists(worker_pod)

            @test pod_phase(manager_pod) == "Succeeded"
            @test pod_phase(worker_pod) == "Succeeded"

            @test length(matches) == 1
            @test matches[1][:worker_id] == "2"
            @test matches[1][:pod_name] == worker_pod

            # Ensure there are no unexpected error messages in the log
            @test !occursin(r"\bError\b"i, manager_log)
        ]

        # Display details to assist in debugging the failure
        if any(r -> !(r isa Test.Pass || r isa Test.Broken), test_results)
            report(job_name, "manager" => manager_pod, "worker" => worker_pod)
        end
    end
end

let job_name = "test-multi-addprocs"
    @testset "$job_name" begin
        code = """
            using Distributed, K8sClusterManagers

            # Avoid trying to pull local-only image
            function configure(pod)
                pod["spec"]["containers"][1]["imagePullPolicy"] = "Never"
                return pod
            end

            mgr = K8sClusterManager(1; configure, retry_seconds=60, cpu="0.5", memory="300Mi")
            addprocs(mgr)
            addprocs(mgr)

            println("Num Processes: ", nprocs())
            for i in workers()
                # Return the name of the pod via HOSTNAME
                println("Worker pod \$i: ", remotecall_fetch(() -> ENV["HOSTNAME"], i))
            end
            """

        command = ["julia"]
        args = ["-e", escape_yaml_string(code)]
        manifest = render(JOB_TEMPLATE; job_name, image=TEST_IMAGE, command, args)
        k8s_create(IOBuffer(manifest))

        # Wait for job to reach status: "Complete" or "Failed".
        @info "Waiting for $job_name job. This could take up to 4 minutes..."
        wait_job(job_name, condition=!isempty, timeout=4 * 60)

        manager_pod = first(pod_names("job-name" => job_name))
        worker_pods = pod_names("manager" => manager_pod)

        manager_log = pod_logs(manager_pod)
        reported_workers = map(m -> m[:pod_name], eachmatch(POD_NAME_REGEX, manager_log))

        test_results = [
            @test get_job(job_name, jsonpath="{.status..type}") == "Complete"

            @test pod_exists(manager_pod)
            @test length(worker_pods) == 2
            @test pod_exists(worker_pods[1])
            @test pod_exists(worker_pods[2])

            @test pod_phase(manager_pod) == "Succeeded"
            @test pod_phase(worker_pods[1]) == "Succeeded"
            @test pod_phase(worker_pods[2]) == "Succeeded"

            @test length(reported_workers) == length(worker_pods)
            @test Set(reported_workers) == Set(worker_pods)

            # Ensure there are no unexpected error messages in the log
            @test !occursin(r"\bError\b"i, manager_log)
        ]

        # Display details to assist in debugging the failure
        if any(r -> !(r isa Test.Pass || r isa Test.Broken), test_results)
            n = length(worker_pods)
            worker_pairs = map(enumerate(worker_pods)) do (i, w)
                "worker $i/$n" => w
            end

            report(job_name, "manager" => manager_pod, worker_pairs...)
        end
    end
end
