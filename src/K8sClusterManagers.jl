module K8sClusterManagers

using Compat: @something
using DataStructures: DefaultOrderedDict, OrderedDict
using Distributed: Distributed, ClusterManager, WorkerConfig, cluster_cookie
using JSON: JSON
using Mocking: Mocking, @mock
using kubectl_jll

export K8sClusterManager, KubeError, isk8s


function __init__()
    if !kubectl_jll.is_available()
        error("kubectl_jll does not support the current platform. See: ",
              "https://github.com/JuliaBinaryWrappers/kubectl_jll.jl#platforms")
    end
end

include("namespace.jl")
include("pod.jl")
include("native_driver.jl")

end
