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

# Re-use the same Kuber context throughout the tests. Note we cannot just set this as a load
# time constant as it depends on K8sClusterManagers being initialized first.
const KUBER_CONTEXT = Ref{KuberContext}()

function _kuber_context()
    if !isassigned(KUBER_CONTEXT)
        KUBER_CONTEXT[] = K8sClusterManagers.kuber_context()
    end
    return KUBER_CONTEXT[]
end


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
