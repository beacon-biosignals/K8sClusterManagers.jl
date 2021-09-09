@testset "config_namespace" begin
    @testset "user namespace" begin
        # Validate that we can process whatever the current system's namespace is
        result = @test K8sClusterManagers.config_namespace() isa Union{String,Nothing}

        if !(result isa Test.Pass)
            @info "kubectl config view:\n" * read(`$(kubectl()) config view`, String)
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
            @test K8sClusterManagers.config_namespace() == "test-namespace"
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
            @test K8sClusterManagers.config_namespace() === nothing
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
            @test K8sClusterManagers.config_namespace() == nothing
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
            @test K8sClusterManagers.config_namespace() == nothing
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
        config_path = touch(tempname())
        patches = [@patch isfile(f) = false]

        withenv("KUBECONFIG" => config_path) do
            apply(patches) do
                @test K8sClusterManagers.current_namespace() === DEFAULT_NAMESPACE
            end
        end
    end
end
