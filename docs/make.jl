using Documenter
using K8sClusterManagers

makedocs(modules=[K8sClusterManagers],
         sitename="K8sClusterManagers.jl",
         authors="Beacon Biosignals, Inc.",
         pages=["Home" => "index.md"])
