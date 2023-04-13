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

# A unique identifier for each test run. Having this ensures that failures in previous runs, which
# won't automatically be cleaned up, do not interfere with new runs.
const TEST_RUN = randsuffix()

# Add a labels for easy cleanup of test resources. Any changes to these common labels also
# needs to occur in the YAML files included in the test directory
# e.g. `kubectl delete pod,job,sa,role,rolebinding -l package-test=K8sClusterManagers.jl`
const COMMON_LABELS = ("package-test" => "K8sClusterManagers.jl",)

const POD_NAME_REGEX = r"Worker pod (?<worker_id>\d+): (?<pod_name>[a-z0-9.-]+)"

# Note: Regex should be generic enough to capture any stray output from the workers
const POD_OUTPUT_REGEX = r"From worker (?<worker_id>\d+):\s+(?<output>.*?)\r?\n"

# As a convenience we'll automatically build the Docker image when a user uses `Pkg.test()`.
# If the environmental variable is set we expect the Docker image has already been built.
if !haskey(ENV, "K8S_CLUSTER_MANAGERS_TEST_IMAGE")
    build_cmd = `docker build --build-arg BASE_IMAGE=julia:$VERSION -t $TEST_IMAGE $PKG_DIR`
    if readchomp(`$(kubectl) config current-context`) == "minikube" && !haskey(ENV, "MINIKUBE_ACTIVE_DOCKERD")
        # When using a minikue cluster we need to build the image within the minikube
        # environment otherwise we'll see pods fail with the reason "ErrImageNeverPull".
        withenv(minikube_docker_env()...) do
            run(build_cmd)
        end
    else
        run(build_cmd)
    end

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
        name = "test-pod-control-$TEST_RUN-named"
        delete!(manifest["metadata"], "generateName")
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

        pod = get_pod(name)
        @test pod["status"]["phase"] == "Running"
        labels = get(pod["metadata"], "labels", Dict())
        @test !("testset" in keys(labels))

        label_pod(name, "testset" => "pod-control")

        pod = get_pod(name)
        labels = get(pod["metadata"], "labels", Dict())
        @test ("testset" => "pod-control") in labels

        # Avoid deleting the pod if we've reached a unhandled phase. This allows for
        # investigation with `kubectl`.
        if pod["status"]["phase"] == "Running"
            @info "Deleting pod $name"
            # Avoid waiting for the pod to be deleted as this can take some time
            delete_pod(name, wait=false)

            # Note: Ideally we would be able to capture the "Terminating" status as reported by
            # `kubectl get pods -w`. Unforturnately I'm not sure how to retrieve this
            # information as it does not seem to be reported by `kubectl get pod` or
            # `kubectl get events`.
            reason = nothing
            while reason === nothing || reason == "Started"
                query = "involvedObject.name=$name"
                output = "jsonpath={.items[-1:].reason}"
                kubectl_cmd = `$(kubectl()) get events --field-selector $query -o=$output`
                reason = read(kubectl_cmd, String)
            end

            @test reason == "Killing"
        else
            @warn "Skipping deletion of pod $name"
        end

        # TODO: Would be nice to show details of the pod if any of these tests fail
    end

    @testset "generate name" begin
        manifest = deepcopy(pod_control_manifest)

        prefix = "test-pod-control-$TEST_RUN-generate-name-"
        manifest["metadata"]["generateName"] = prefix

        name_a = create_pod(manifest)
        name_b = create_pod(manifest)

        @test name_a != name_b
        @test startswith(name_a, prefix)
        @test startswith(name_b, prefix)

        delete_pod(name_a, wait=false)
        delete_pod(name_b, wait=false)
    end

    @testset "exec" begin
        manifest = deepcopy(pod_control_manifest)
        manifest["metadata"]["generateName"] = "test-pod-control-$TEST_RUN-exec-"

        name = create_pod(manifest)
        wait_for_running_pod(name; timeout=30)

        @test exec_pod(name, `bash -c "exit 0"`) === nothing

        try
            exec_pod(name, `kill -s INT 1`)
        catch e
            # Ensure that useful information from stdout/stderr is included
            if e isa KubeError
                @test occursin("\"kill\": executable file not found in \$PATH", e.msg)
                @test occursin("command terminated with exit code 126", e.msg)
            else
                rethrow()
            end
        end

        delete_pod(name; wait=false)
    end
end

let test_name = "test-isk8s"
    @testset "$test_name" begin
        job_name = "$(test_name)-$(TEST_RUN)"

        code = """
            using K8sClusterManagers
            println("isk8s: ", isk8s())
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
        @info "Waiting for $job_name job. This could take up to 1 minute..."
        wait_job(job_name, condition=!isempty, timeout=1 * 60)

        manager_pod = first(pod_names("job-name" => job_name))

        manager_log = pod_logs(manager_pod)
        log_matches = collect(eachmatch(r"isk8s: (?<isk8s>.*?)\r?\n", manager_log))

        test_results = [
            @test get_job(job_name, jsonpath="{.status..type}") == "Complete"
            @test pod_exists(manager_pod)
            @test pod_phase(manager_pod) == "Succeeded"

            @test length(log_matches) == 1
            @test log_matches[1][:isk8s] == "true"
        ]

        # Display details to assist in debugging the failure
        if any(r -> !(r isa Test.Pass || r isa Test.Broken), test_results)
            report(job_name, "manager" => manager_pod)
        else
            @info "Deleting job/pods for $job_name"
            delete_job(job_name; wait=false)
        end
    end
end

let test_name = "test-k8s-external-manager"
    @testset "$test_name" begin
        worker_prefix = "$(test_name)-$(TEST_RUN)-worker"
        function configure(pod)
            push!(pod["metadata"]["labels"], "test" => test_name, COMMON_LABELS...)
            return pod
        end

        # Manager must be running outside of a K8s cluster for these tests
        @test !isk8s()

        worker_ids = addprocs(K8sClusterManager(1; configure, worker_prefix, pending_timeout=60, cpu="0.5", memory="300Mi"))
        @test nprocs() == 2

        worker_id = only(worker_ids)
        worker_pod = remotecall_fetch(gethostname, worker_id)

        @test pod_exists(worker_pod)
        @test pod_phase(worker_pod) == "Running"

        # Worker image should default to the standard Julia docker image when the manager
        # isn't running as a K8s pod
        @test only(pod_images(worker_pod)) == "julia:$VERSION"

        # Execute code on remote worker
        @test remotecall_fetch(myid, worker_id) == worker_id

        rmprocs(worker_id)
        timedwait(20; pollint=1) do
            pod_phase(worker_pod) != "Running"
        end

        # Removed workers should have a return code of zero
        @test pod_phase(worker_pod) == "Succeeded"

        @info "Deleting pod for $test_name"
        delete_pod(worker_pod; wait=false)
    end
end

let test_name = "test-k8s-internal-manager"
    @testset "$test_name" begin
        job_name = "$(test_name)-$(TEST_RUN)"
        worker_prefix = "$(job_name)-worker"

        code = """
            using Distributed, K8sClusterManagers
            worker_prefix = "$worker_prefix"

            function configure(pod)
                push!(pod["metadata"]["labels"], "test" => "$test_name", $COMMON_LABELS...)

                # Avoid trying to pull local-only image
                pod["spec"]["containers"][1]["imagePullPolicy"] = "Never"
                return pod
            end
            pids = addprocs(K8sClusterManager(1; configure, worker_prefix, pending_timeout=60, cpu="0.5", memory="300Mi"))

            println("Num Processes: ", nprocs())
            for i in workers()
                # Return the name of the pod via HOSTNAME
                println("Worker pod \$i: ", remotecall_fetch(() -> ENV["HOSTNAME"], i))
            end

            # Ensure that stdout/stderr on the worker is displayed on the manager
            @everywhere pids begin
                println(ENV["HOSTNAME"])
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

        manager_pod = only(pod_names("job-name" => job_name))
        worker_pod = only(pod_names("worker-prefix" => worker_prefix))

        manager_log = pod_logs(manager_pod)
        call_matches = collect(eachmatch(POD_NAME_REGEX, manager_log))
        output_matches = collect(eachmatch(POD_OUTPUT_REGEX, manager_log))

        test_results = [
            @test get_job(job_name, jsonpath="{.status..type}") == "Complete"

            @test pod_exists(manager_pod)
            @test pod_exists(worker_pod)

            @test pod_phase(manager_pod) == "Succeeded"
            @test pod_phase(worker_pod) == "Succeeded"

            @test length(call_matches) == 1
            @test call_matches[1][:worker_id] == "2"
            @test call_matches[1][:pod_name] == worker_pod

            @test length(output_matches) == 1
            @test output_matches[1][:worker_id] == "2"
            @test output_matches[1][:output] == worker_pod

            # Worker image should default to the manager's image
            @test only(pod_images(worker_pod)) == only(pod_images(manager_pod))

            # Ensure there are no unexpected error messages in the log
            @test !occursin(r"\bError\b"i, manager_log)
        ]

        # Display details to assist in debugging the failure
        if any(r -> !(r isa Test.Pass || r isa Test.Broken), test_results)
            report(job_name, "manager" => manager_pod, "worker" => worker_pod)
        else
            @info "Deleting job/pods for $job_name"
            delete_job(job_name; wait=false)
            delete_pod(worker_pod; wait=false)
        end
    end
end

let test_name = "test-multi-addprocs"
    @testset "$test_name" begin
        job_name = "$(test_name)-$(TEST_RUN)"
        worker_prefix = "$(job_name)-worker"

        code = """
            using Distributed, K8sClusterManagers
            worker_prefix = "$worker_prefix"

            function configure(pod)
                push!(pod["metadata"]["labels"], "test" => "$test_name", $COMMON_LABELS...)

                # Avoid trying to pull local-only image
                pod["spec"]["containers"][1]["imagePullPolicy"] = "Never"
                return pod
            end

            mgr = K8sClusterManager(1; configure, worker_prefix, pending_timeout=60, cpu="0.5", memory="300Mi")
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

        manager_pod = only(pod_names("job-name" => job_name))
        worker_pods = pod_names("worker-prefix" => worker_prefix; sort_by="{.metadata.labels.worker-id}")

        manager_log = pod_logs(manager_pod)
        matches = collect(eachmatch(POD_NAME_REGEX, manager_log))
        reported_worker_pods = map(m -> m[:pod_name], sort!(matches; by=m -> m[:worker_id]))

        test_results = [
            @test get_job(job_name, jsonpath="{.status..type}") == "Complete"

            @test pod_exists(manager_pod)
            @test length(worker_pods) == 2
            @test pod_exists(worker_pods[1])
            @test pod_exists(worker_pods[2])

            @test pod_phase(manager_pod) == "Succeeded"
            @test pod_phase(worker_pods[1]) == "Succeeded"
            @test pod_phase(worker_pods[2]) == "Succeeded"

            @test length(matches) == length(worker_pods)
            @test reported_worker_pods == worker_pods

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
        else
            @info "Deleting job/pods for $job_name"
            delete_job(job_name; wait=false)
            foreach(pod_name -> delete_pod(pod_name; wait=false), worker_pods)
        end
    end
end

# Keep this test using a in-cluster manager as the interrupt reports the error in the
let test_name = "test-interrupt"
    @testset "$test_name" begin
        job_name = "$(test_name)-$(TEST_RUN)"
        worker_prefix = "$(job_name)-worker"

        code = """
            using Distributed, K8sClusterManagers
            worker_prefix = "$worker_prefix"

            function configure(pod)
                push!(pod["metadata"]["labels"], "test" => "$test_name", $COMMON_LABELS...)

                # Avoid trying to pull local-only image
                pod["spec"]["containers"][1]["imagePullPolicy"] = "Never"
                return pod
            end

            mgr = K8sClusterManager(1; configure, worker_prefix, pending_timeout=60, cpu="0.5", memory="300Mi")
            pids = addprocs(mgr)
            interrupt(pids)
            """

        command = ["julia"]
        args = ["-e", escape_yaml_string(code)]
        manifest = render(JOB_TEMPLATE; job_name, image=TEST_IMAGE, command, args)
        k8s_create(IOBuffer(manifest))

        # Wait for job to reach status: "Complete" or "Failed".
        @info "Waiting for $job_name job. This could take up to 4 minutes..."
        wait_job(job_name, condition=!isempty, timeout=4 * 60)

        manager_pod = only(pod_names("job-name" => job_name))
        worker_pod = only(pod_names("worker-prefix" => worker_prefix))

        manager_log = pod_logs(manager_pod)

        test_results = [
            @test pod_phase(manager_pod) == "Succeeded"
            @test pod_phase(worker_pod) == "Failed"

            # Ensure there are no unexpected error messages in the log
            @test length(collect(eachmatch(r"\bError\b"i, manager_log))) == 1
        ]

        # Display details to assist in debugging the failure
        if any(r -> !(r isa Test.Pass || r isa Test.Broken), test_results)
            report(job_name, "manager" => manager_pod, "worker" => worker_pod)
        else
            @info "Deleting job/pods for $job_name"
            delete_job(job_name; wait=false)
            delete_pod(worker_pod; wait=false)
        end
    end
end

let test_name = "test-oom"
    @testset "$test_name" begin
        job_name = "$(test_name)-$(TEST_RUN)"
        worker_prefix = "$(job_name)-worker"

        code = """
            using Distributed, K8sClusterManagers
            worker_prefix = "$worker_prefix"

            function configure(pod)
                push!(pod["metadata"]["labels"], "test" => "$test_name", $COMMON_LABELS...)

                # Avoid trying to pull local-only image
                pod["spec"]["containers"][1]["imagePullPolicy"] = "Never"
                return pod
            end

            mgr = K8sClusterManager(1; configure, worker_prefix, pending_timeout=60, cpu="0.5", memory="300Mi")
            pids = addprocs(mgr)

            @everywhere begin
                function oom(T=Int64)
                    max_elements = Sys.total_memory() ÷ sizeof(T)
                    fill(zero(T), max_elements + 1)
                end
            end

            f = remotecall(oom, first(pids))

            # Use `wait` call to ensure that Distributed.jl notices the termination of the
            # worker. We can safely ignore the expected `ProcessExitedException`.
            try
                wait(f)
                error("`oom` call has not resulted in worker termination")
            catch e
                e isa ProcessExitedException || rethrow()
            end

            # Wait for the deregistration task which reports abnormal worker terminations.
            wait(K8sClusterManagers.DEREGISTER_ALERT)
            """

        command = ["julia"]
        args = ["-e", escape_yaml_string(code)]
        manifest = render(JOB_TEMPLATE; job_name, image=TEST_IMAGE, command, args)
        k8s_create(IOBuffer(manifest))

        # Wait for job to reach status: "Complete" or "Failed".
        @info "Waiting for $job_name job. This could take up to 4 minutes..."
        wait_job(job_name, condition=!isempty, timeout=4 * 60)

        manager_pod = only(pod_names("job-name" => job_name))
        worker_pod = only(pod_names("worker-prefix" => worker_prefix))

        manager_log = pod_logs(manager_pod)
        worker_oom_msg = "Worker 2 on pod $worker_pod was terminated due to: OOMKilled"

        test_results = [
            @test pod_phase(manager_pod) == "Succeeded"
            @test pod_phase(worker_pod) == "Failed"

            @test pod_status(worker_pod) == ("terminated" => "OOMKilled")
            @test occursin(worker_oom_msg, manager_log)

            # Ensure there are no unexpected error messages in the log
            @test !occursin(r"\bError\b"i, manager_log)
        ]

        # Display details to assist in debugging the failure
        if any(r -> !(r isa Test.Pass || r isa Test.Broken), test_results)
            report(job_name, "manager" => manager_pod, "worker" => worker_pod)
        else
            @info "Deleting job/pods for $job_name"
            delete_job(job_name; wait=false)
            delete_pod(worker_pod; wait=false)
        end
    end
end

let test_name = "test-pending-timeout"
    @testset "$test_name" begin
        job_name = "$(test_name)-$(TEST_RUN)"
        worker_prefix = "$(job_name)-worker-"

        code = """
            using Distributed, K8sClusterManagers

            function configure(pod)
                push!(pod["metadata"]["labels"], "test" => "$test_name", $COMMON_LABELS...)

                # Avoid trying to pull local-only image
                pod["spec"]["containers"][1]["imagePullPolicy"] = "Never"
                return pod
            end

            # Make a worker memory request so large that it will always fail.
            # Previously with Kubenetes 1.22 we used "1Ei" (1 exbibyte) as this large
            # value but this now fails with Kubernetes 1.26 so we'll use "1Pi" (1 pebibyte)
            # instead.
            # TODO: Reproduce the "1Ei" failure outside of K8sClusterManagers and file an
            # issue for this.
            mgr = K8sClusterManager(1; configure, pending_timeout=1, memory="1Pi")
            pids = addprocs(mgr)

            println("Num Processes: ", nprocs())
            for i in pids
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

        manager_log = pod_logs(manager_pod)
        call_matches = collect(eachmatch(POD_NAME_REGEX, manager_log))

        test_results = [
            @test get_job(job_name, jsonpath="{.status..type}") == "Complete"

            @test pod_exists(manager_pod)
            @test pod_phase(manager_pod) == "Succeeded"

            @test length(call_matches) == 0

            @test occursin(r"timed out after waiting for worker", manager_log)

            # Ensure there are no unexpected error messages in the log
            @test !occursin(r"\bError\b"i, manager_log)
        ]

        # Display details to assist in debugging the failure
        if any(r -> !(r isa Test.Pass || r isa Test.Broken), test_results)
            report(job_name, "manager" => manager_pod)
        else
            @info "Deleting job/pods for $job_name"
            delete_job(job_name; wait=false)
        end
    end
end
