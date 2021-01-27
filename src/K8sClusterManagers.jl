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

function __init__()
    kubectl() do exe
        run(`$exe proxy --port=8001`; wait=false)
    end
end

end
