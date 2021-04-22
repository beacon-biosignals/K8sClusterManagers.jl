@testset "K8sClusterManager" begin
    @testset "pods not found" begin
        try
            K8sClusterManager(1)
        catch ex
            # Show the original stacktrace if an unexpected error occurred.
            ex isa K8sClusterManagers.KubeError || rethrow()

            @test ex isa K8sClusterManagers.KubeError
            @test length(Base.catch_stack()) == 1
        end
    end
end
