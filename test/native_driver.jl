@testset "K8sClusterManager" begin
    @testset "pods not found" begin
        ctx = KuberContext()
        withenv("HOSTNAME" => "localhost") do
            try
                K8sClusterManager(1; _ctx=ctx)
            catch ex
                # Show the original stacktrace if an unexpected error occurred.
                ex isa Swagger.ApiException || rethrow()

                @test ex isa Swagger.ApiException
                @test length(Base.catch_stack()) == 1
            end
        end
    end
end
