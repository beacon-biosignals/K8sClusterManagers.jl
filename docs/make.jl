using Documenter
using K8sClusterManagers

makedocs(modules=[K8sClusterManagers],
         sitename="K8sClusterManagers.jl",
         authors="Beacon Biosignals and other contributors",
         pages=["Home" => "index.md",
                "Examples" => "examples.md",
                "Workflow Patterns" => "patterns.md",
                "API Documentation" => "api.md"])

deploydocs(repo="github.com/beacon-biosignals/K8sClusterManagers.jl.git",
           devbranch="main")
