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

# Re-use the same Kuber context throughout the tests.
const KUBER_CONTEXT = KuberContext()

@testset "K8sClusterManagers" begin
    include("namespace.jl")
    include("pod.jl")
    include("native_driver.jl")

    # Tests that interact with a real, usually local, Kubernetes cluster
    if parse(Bool, get(ENV, "K8S_CLUSTER_TESTS", "true"))
        @testset "Kubernetes Cluster Tests" begin
            include("cluster.jl")
        end
    end
end
