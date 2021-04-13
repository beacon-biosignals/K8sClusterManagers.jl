using Distributed
using K8sClusterManagers
using Kuber: KuberContext
using Swagger
using Test


@testset "K8sClusterManagers" begin
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
end
