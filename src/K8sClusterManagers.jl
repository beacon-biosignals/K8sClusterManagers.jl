module K8sClusterManagers

using Dates
using Distributed
using JSON
using Kuber
using kubectl_jll

import Distributed: launch, manage, kill

worker_arg() = `--worker=$(Distributed.init_multi(); cluster_cookie())`

include("native_driver.jl")
export addprocs_pod
export K8sNativeManager
export launch, manage, kill

const KUBECTL_PROXY_PROCESS = Ref{Base.Process}()

function restart_kubectl_proxy()
    port = get(ENV, "KUBECTL_PROXY_PORT", 8001)
    if isassigned(KUBECTL_PROXY_PROCESS)
        kill(KUBECTL_PROXY_PROCESS[])
    end

    # Note: Preferring thread-safe executable product wrapper when available
    KUBECTL_PROXY_PROCESS[] = if VERSION >= v"1.6.0-DEV"
        run(`$(kubectl()) proxy --port=$port`; wait=false)
    else
        kubectl() do exe
            run(`$exe proxy --port=$port`; wait=false)
        end
    end
end

__init__() = restart_kubectl_proxy()

end
