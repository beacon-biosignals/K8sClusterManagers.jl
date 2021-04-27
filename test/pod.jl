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

@testset "worker_pod_spec" begin
    kwargs = (; cmd=`julia`, driver_name="driver", image="julia")
    pod = K8sClusterManagers.worker_pod_spec(; kwargs...)

    @test keys(pod) == Set(["apiVersion", "kind", "metadata", "spec"])
    @test pod["apiVersion"] == "v1"
    @test pod["kind"] == "Pod"

    @test keys(pod["metadata"]) == Set(["generateName", "labels"])
    @test pod["metadata"]["generateName"] == "driver-worker-"
    @test keys(pod["metadata"]["labels"]) == Set(["manager"])
    @test pod["metadata"]["labels"]["manager"] == "driver"

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
    pod_id = "pode773d78d-9f0d-4003-a6e8-9bef75b89298/" *
             "b52d083fb1f5b45d998895ab758d10fa36b2a53f3bf3128d7cf1d6d36bc67bd6"
    cgroup = """
        11:devices:/kubepods/$pod_id
        10:blkio:/kubepods/$pod_id
        9:hugetlb:/kubepods/$pod_id
        8:net_cls,net_prio:/kubepods/$pod_id
        7:memory:/kubepods/$pod_id
        6:cpuset:/kubepods/$pod_id
        5:perf_event:/kubepods/$pod_id
        4:cpu,cpuacct:/kubepods/$pod_id
        3:println()ids:/kubepods/$pod_id
        2:freezer:/kubepods/$pod_id
        1:name=systemd:/kubepods/$pod_id
        """

    patches = [
        @patch isfile(p) = p == "/proc/self/cgroup"
        @patch open(f, p) = f(IOBuffer(cgroup))
    ]

    apply(patches) do
        @test isk8s()
    end
end
