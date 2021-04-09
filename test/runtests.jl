using Distributed
using K8sClusterManagers
using Swagger
using Test


@testset "K8sClusterManagers" begin
    @testset "addprocs_pod" begin
        @testset "pods not found" begin
            withenv("HOSTNAME" => "localhost") do
                try
                    K8sClusterManagers.addprocs_pod(1)
                catch ex
                    @test ex isa Swagger.ApiException
                    @test length(Base.catch_stack()) == 2  # Ideally would be 1...
                end
            end
        end
    end
end
