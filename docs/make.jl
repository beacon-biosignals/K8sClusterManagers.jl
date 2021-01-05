using Documenter
using K8sClusterManagers

makedocs(modules=[K8sClusterManagers],
         sitename="K8sClusterManagers",
         authors="Beacon Biosignals and other contributors",
         pages=["API Documentation" => "index.md"])

deploydocs(repo="github.com/beacon-biosignals/K8sClusterManagers.jl.git",
           devbranch="main")
