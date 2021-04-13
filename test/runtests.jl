using Distributed
using K8sClusterManagers
using Kuber: KuberContext
using Swagger
using Test
using kubectl_jll: kubectl


@testset "K8sClusterManagers" begin
    @testset "current_namespace" begin
        @testset "user namespace" begin
            # Validate that we can process whatever the current system's namespace is
            result = @test K8sClusterManagers.current_namespace() isa String

            if !(result isa Test.Pass)
                kubectl() do exe
                    @info "kubectl config view:\n" * read(`$exe config view`, String)
                end
            end
        end

        @testset "multiple contexts" begin
            config_path = tempname()
            write(config_path,
                  """
                  apiVersion: v1
                  kind: Config
                  contexts:
                  - context:
                      namespace: extra-namespace
                    name: extra
                  - context:
                      namespace: test-namespace
                    name: test
                  current-context: test
                  """)

            withenv("KUBECONFIG" => config_path) do
                @test K8sClusterManagers.current_namespace() == "test-namespace"
            end
        end

        # Note: Mirrors the config returned when running in the CI environment
        @testset "no current context" begin
            config_path = tempname()
            write(config_path,
                  """
                  apiVersion: v1
                  kind: Config
                  current-context: ""
                  """)

            withenv("KUBECONFIG" => config_path) do
                @test K8sClusterManagers.current_namespace() == ""
            end
        end

        @testset "no namespace for context" begin
            config_path = tempname()
            write(config_path,
                  """
                  apiVersion: v1
                  kind: Config
                  contexts:
                  - context:
                      cluster: ""
                      user: ""
                    name: test
                  current-context: test
                  """)

            withenv("KUBECONFIG" => config_path) do
                @test K8sClusterManagers.current_namespace() == ""
            end
        end

        # Note: Can occur when the current context is deleted
        @testset "bad active context" begin
            config_path = tempname()
            write(config_path,
                  """
                  apiVersion: v1
                  kind: Config
                  contexts:
                  - context:
                      namespace: test-namespace
                    name: test
                  current-context: foo
                  """)

            withenv("KUBECONFIG" => config_path) do
                @test K8sClusterManagers.current_namespace() == ""
            end
        end
    end

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
