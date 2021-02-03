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

function restart_kubectl_proxy()
    port = get(ENV, "KUBECTL_PROXY_PORT", 8001)
    if isassigned(kubectl_proxy_process)
        kill(kubectl_proxy_process[])
    end
    kubectl() do exe
        kubectl_proxy_process[] = run(`$exe proxy --port=$port`; wait=false)
    end
end

__init__() = restart_kubectl_proxy()

end
