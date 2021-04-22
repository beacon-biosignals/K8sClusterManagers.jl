@testset "K8sClusterManager" begin
    @testset "pods not found" begin
        try
            K8sClusterManager(1)
        catch ex
            # Show the original stacktrace if an unexpected error occurred.
            ex isa Swagger.ApiException || rethrow()

            @test ex isa Swagger.ApiException
            @test length(Base.catch_stack()) == 1
        end
    end
end
