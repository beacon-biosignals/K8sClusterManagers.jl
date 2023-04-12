@testset "K8sClusterManager" begin
    @testset "basic" begin
        mgr = K8sClusterManager(1; image="julia:1")
        @test mgr.np == 1
        @test mgr.worker_prefix == "$(gethostname())-worker"
        @test mgr.image == "julia:1"
        @test mgr.cpu == string(K8sClusterManagers.DEFAULT_WORKER_CPU)
        @test mgr.memory == K8sClusterManagers.DEFAULT_WORKER_MEMORY
        @test mgr.pending_timeout == 180
        @test mgr.configure === identity
    end

    @testset "worker_prefix" begin
        kwargs = (; image="julia:1")
        mgr = K8sClusterManager(1; kwargs...)
        @test mgr.worker_prefix == "$(gethostname())-worker"

        mgr = K8sClusterManager(1; worker_prefix="wkr-group", kwargs...)
        @test mgr.worker_prefix == "wkr-group"

        mgr = K8sClusterManager(1; manager_pod_name="pod", kwargs...)
        @test mgr.worker_prefix == "pod-worker"

        mgr = K8sClusterManager(1; worker_prefix="wkr-group", manager_pod_name="pod", kwargs...)
        @test mgr.worker_prefix == "wkr-group"
    end

    @testset "pods not found" begin
        try
            K8sClusterManager(1)
        catch ex
            # Show the original stacktrace if an unexpected error occurred.
            ex isa KubeError || rethrow()

            @test ex isa KubeError
            @test length(Base.catch_stack()) == 1
        end
    end
end

@testset "TimeoutException" begin
    e = K8sClusterManagers.TimeoutException("time out!")
    @test sprint(showerror, e) == "TimeoutException: time out!"
end
