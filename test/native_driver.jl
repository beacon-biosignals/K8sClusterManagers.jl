@testset "K8sClusterManager" begin
    @testset "pods not found" begin
        ctx = _kuber_context()
        withenv("HOSTNAME" => "localhost") do
            try
                K8sClusterManager(1; _ctx=ctx)
            catch ex
                @test ex isa Swagger.ApiException
                @test length(Base.catch_stack()) == 1
            end
        end
    end
end
