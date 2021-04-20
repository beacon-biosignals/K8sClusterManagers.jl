module K8sClusterManagers

using Dates
using Distributed
using JSON
using Kuber
using Mocking: Mocking, @mock
using kubectl_jll

import Distributed: launch, manage, kill

worker_arg() = `--worker=$(Distributed.init_multi(); cluster_cookie())`

include("native_driver.jl")
export addprocs_pod
export K8sNativeManager
export launch, manage, kill

const kubectl_proxy_process = Ref{Base.Process}()

function restart_kubectl_proxy()
    # Note: "KUBECTL_PROXY_PORT" is a made up environmental variable and is not supported by
    # `kubectl proxy`. The default port (8001) is what `kubectl proxy` uses when `--port` is
    # not specified.
    port = get(ENV, "KUBECTL_PROXY_PORT", 8001)
    if isassigned(kubectl_proxy_process)
        kill(kubectl_proxy_process[])
    end
    kubectl() do exe
        kubectl_proxy_process[] = run(`$exe proxy --port=$port`; wait=false)
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

end
