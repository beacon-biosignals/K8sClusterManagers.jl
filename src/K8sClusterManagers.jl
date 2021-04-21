module K8sClusterManagers

using Distributed: Distributed, ClusterManager, WorkerConfig, cluster_cookie
using JSON
using Kuber
using Mocking: Mocking, @mock
using kubectl_jll

export K8sClusterManager


const KUBECTL_PROXY_PROCESS = Ref{Base.Process}()

function restart_kubectl_proxy()
    # Note: "KUBECTL_PROXY_PORT" is a made up environmental variable and is not supported by
    # `kubectl proxy`. The default port (8001) is what `kubectl proxy` uses when `--port` is
    # not specified.
    port = get(ENV, "KUBECTL_PROXY_PORT", 8001)
    if isassigned(KUBECTL_PROXY_PROCESS)
        kill(KUBECTL_PROXY_PROCESS[])
    end
    kubectl() do exe
        KUBECTL_PROXY_PROCESS[] = run(`$exe proxy --port=$port`; wait=false)
    end
end

function __init__()
    if !kubectl_jll.is_available()
        error("kubectl_jll does not support the current platform. See: ",
              "https://github.com/JuliaBinaryWrappers/kubectl_jll.jl#platforms")
    end

    # Kuber.jl expects that Kubernetes API server is available via: http://localhost:8001
    restart_kubectl_proxy()
end

include("namespace.jl")
include("pod.jl")
include("native_driver.jl")

end
