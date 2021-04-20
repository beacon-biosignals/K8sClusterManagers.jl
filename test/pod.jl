@testset "self_pod" begin
    @testset "non-nested exceptions" begin
        ctx = KuberContext()
        withenv("HOSTNAME" => "localhost") do
            try
                K8sClusterManagers.self_pod(ctx)
            catch ex
                @test ex isa Swagger.ApiException
                @test length(Base.catch_stack()) == 1
            end
        end
    end
end
