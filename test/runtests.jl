using Distributed
using K8sClusterManagers
using K8sClusterManagers: DEFAULT_NAMESPACE, NAMESPACE_FILE
using Kuber: KuberContext
using LibGit2: LibGit2
using Mocking: Mocking, @patch, apply
using Mustache: Mustache, render
using Swagger: Swagger
using Test
using kubectl_jll: kubectl

Mocking.activate()


@testset "K8sClusterManagers" begin
    @testset "current_config_namespace" begin
        @testset "user namespace" begin
            # Validate that we can process whatever the current system's namespace is
            result = @test K8sClusterManagers.current_config_namespace() isa Union{String,Nothing}

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
                @test K8sClusterManagers.current_config_namespace() == "test-namespace"
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
                @test K8sClusterManagers.current_config_namespace() === nothing
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
                @test K8sClusterManagers.current_config_namespace() == nothing
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
                @test K8sClusterManagers.current_config_namespace() == nothing
            end
        end
    end

    @testset "pod_namespace" begin
        @testset "inside of pod" begin
            patches = [@patch isfile(f) = f == NAMESPACE_FILE
                       @patch read(f, ::Type{String}) = "pod-namespace"]

            apply(patches) do
                @test K8sClusterManagers.pod_namespace() == "pod-namespace"
            end
        end

        @testset "outside of pod" begin
            patches = [@patch isfile(f) = false]

            apply(patches) do
                @test K8sClusterManagers.pod_namespace() === nothing
            end
        end
    end

    @testset "current_namespace" begin
        @testset "fallback namespace" begin
            config_path = tempname()
            patches = [@patch isfile(f) = false]

            withenv("KUBECONFIG" => config_path) do
                apply(patches) do
                    @test K8sClusterManagers.pod_namespace() === nothing
                end
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

    # Tests that interact with a real, usually local, Kubernetes cluster
    if parse(Bool, get(ENV, "K8S_CLUSTER_TESTS", "true"))
        @testset "Kubernetes Cluster Tests" begin
            include("cluster.jl")
        end
    end
end
