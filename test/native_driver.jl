@testset "addprocs_pod" begin
    @testset "pods not found" begin
        withenv("HOSTNAME" => "localhost") do
            try
                K8sClusterManagers.addprocs_pod(1)
            catch ex
                @test ex isa Swagger.ApiException
                @test length(Base.catch_stack()) == 1
            end
        end
    end
end
