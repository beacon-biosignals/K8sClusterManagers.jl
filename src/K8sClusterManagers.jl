module K8sClusterManagers

using Dates
using Distributed
using JSON
using kubectl_jll
using Kuber

import Distributed: launch, manage, kill

worker_arg() = `--worker=$(Distributed.init_multi(); cluster_cookie())`

include("native_driver.jl")
export addprocs_pod
export K8sNativeManager
export launch, manage, kill

const kubectl_proxy_process = Ref{Base.Process}()

# Apple Silicon/ARM64 work around
if !kubectl_jll.is_available()
    kubectl(f) = f(`kubectl`)
end

function restart_kubectl_proxy()
    port = get(ENV, "KUBECTL_PROXY_PORT", 8001)
    if isassigned(kubectl_proxy_process)
        kill(kubectl_proxy_process[])
    end
    kubectl() do exe
        kubectl_proxy_process[] = run(`$exe proxy --port=$port`; wait=false)
    end
end

function __init__()
    # if !kubectl_jll.is_available()
    #     error("kubectl_jll does not support the current platform. See: ",
    #           "https://github.com/JuliaBinaryWrappers/kubectl_jll.jl#platforms")
    # end

    restart_kubectl_proxy()
end

end
