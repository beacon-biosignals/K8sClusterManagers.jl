@testset "KubeError" begin
    msg = "Error from server (NotFound): pods \"localhost\" not found"
    @test sprint(Base.showerror, KubeError(msg)) == "KubeError: $msg"
end

@testset "create_pod" begin
    @testset "non-pod" begin
        @test_throws ArgumentError create_pod(Dict("kind" => "Job"))
    end
end

@testset "wait_for_running_pod" begin
    function stateful_get_pod_patch(states)
        i = 0
        @patch function get_pod(name)
            i <= length(states) && (i += 1)
            Dict("status" => Dict("phase" => states[i]))
        end
    end

    @testset "basic" begin
        states = ("Pending", "Running", "Succeeded")
        pod = apply(stateful_get_pod_patch(states)) do
            wait_for_running_pod("foo"; timeout=10)
        end

        @test pod["status"]["phase"] == "Running"
    end

    # Note: It does not seems possible to reliably test timeout without using Mocking.
    @testset "timeout" begin
        patch = @patch get_pod(name) = Dict("status" => Dict("phase" => "Pending"))

        apply(patch) do
            @test_throws K8sClusterManagers.TimeoutException wait_for_running_pod("foo"; timeout=1)
        end
    end

    @testset "failure" begin
        states = ("Failed",)
        apply(stateful_get_pod_patch(states)) do
            @test_throws ErrorException wait_for_running_pod("foo"; timeout=1)
        end
    end
end

@testset "pod_status" begin
    function gen_resource(status)
        state, reason = status
        state_dict = reason !== nothing ? Dict("reason" => reason) : Dict()
        container_status = Dict("state" => Dict(state => state_dict))

        return Dict("kind" => "Pod",
                    "status" => Dict("containerStatuses" => [container_status]))
    end

    @testset "running" begin
        r = gen_resource("running" => nothing)
        @test pod_status(r) == ("running" => nothing)
    end

    @testset "terminated: Completed" begin
        r = gen_resource("terminated" => "Completed")
        @test pod_status(r) == ("terminated" => "Completed")
    end

    @testset "terminated: OOMKilled" begin
        r = gen_resource("terminated" => "OOMKilled")
        @test pod_status(r) == ("terminated" => "OOMKilled")
    end

    @testset "invalid kind" begin
        @test_throws ArgumentError pod_status(Dict("kind" => "Unknown"))
    end

    @testset "multiple container statuses" begin
        r = gen_resource("running" => nothing)
        r["status"]["containerStatuses"] = repeat(r["status"]["containerStatuses"], 2)
        @test_throws ArgumentError pod_status(r)
    end

    @testset "multiple states" begin
        r = gen_resource("running" => nothing)
        r["status"]["containerStatuses"][1]["state"]["extra"] = Dict()
        @test_throws ArgumentError pod_status(r)
    end
end

@testset "worker_pod_spec" begin
    kwargs = (; worker_prefix="test-wkr", image="julia", cmd=`julia`, cluster_cookie="🍪")
    pod = K8sClusterManagers.worker_pod_spec(; kwargs...)

    @test keys(pod) == Set(["apiVersion", "kind", "metadata", "spec"])
    @test pod["apiVersion"] == "v1"
    @test pod["kind"] == "Pod"

    @test keys(pod["metadata"]) == Set(["generateName", "labels"])
    @test pod["metadata"]["generateName"] == "test-wkr-"
    @test keys(pod["metadata"]["labels"]) == Set(["worker-prefix", "cluster-cookie"])
    @test pod["metadata"]["labels"]["worker-prefix"] == "test-wkr"
    @test pod["metadata"]["labels"]["cluster-cookie"] == "🍪"

    @test pod["spec"]["restartPolicy"] == "Never"
    @test length(pod["spec"]["containers"]) == 1

    worker = pod["spec"]["containers"][1]
    @test keys(worker) == Set(["name", "image", "command", "resources"])
    @test worker["name"] == "worker"
    @test worker["image"] == "julia"
    @test worker["command"] == ["julia"]
    @test worker["resources"]["requests"]["cpu"] == DEFAULT_WORKER_CPU
    @test worker["resources"]["requests"]["memory"] == DEFAULT_WORKER_MEMORY
    @test worker["resources"]["limits"]["cpu"] == DEFAULT_WORKER_CPU
    @test worker["resources"]["limits"]["memory"] == DEFAULT_WORKER_MEMORY
end

@testset "isk8s" begin
    withenv("KUBERNETES_SERVICE_HOST" => nothing, "KUBERNETES_SERVICE_PORT" => nothing) do
        @test !isk8s()
    end

    withenv("KUBERNETES_SERVICE_HOST" => "10.0.0.1", "KUBERNETES_SERVICE_PORT" => "443") do
        @test isk8s()
    end
end
