Workflow Patterns
=================

## Required Permissions

K8sClusterManagers.jl requires a minimal set of permisisons for managing worker Pods within
the cluster. A minimal set of permissions is documented below along with a ServiceAccount
to make use of these permissions:

````@eval
using Markdown
Markdown.parse("""
```yaml
$(read("julia-manager-serviceaccount.yaml", String))
```
""")
````

## Use K8sClusterManager only within cluster

Since the [`K8sClusterManager`](@ref) can only be used when running inside of a Kubernetes
Pod you may want conditionally use it. The [`isk8s`](@ref) predicate provides a convenient
way of determining if the running Julia process is executing within a K8s Pod.

```julia
using Distributed, K8sClusterManagers

manager = if isk8s()
    K8sClusterManager(n)
else
    Distributed.LocalManager(n)
end

addprocs(manager; exeflags="--project")
```

## Executing a script

Depending on your use case you may find yourself wanting to execute a script on the K8s
cluster. One basic workflow would be as follows.

1. Write a "script.jl" which uses `K8sClusterManager`
2. Build and push a Docker image containing the "script.jl" and the required dependencies:

   ```sh
   docker build -t $IMAGE .
   docker push $IMAGE
   ```

3. Define a Kubernetes manifest ("script-example.template.yaml") which executes the Docker
   image on the cluster. Note that the use of `envsubst` will substitute `${...}` with the
   respectively named environmental variable.

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     generateName: script-example-
   spec:
     serviceAccountName: "${PROJECT}-service-account"
     restartPolicy: Never
     containers:
     - name: manager
       image: "${IMAGE}"
       imagePullPolicy: Always
       command: ["julia", "script.jl"]
       args: ["${ARG}"]
   ```

4. Create the resource which will run our script.

   ```sh
   # Expects that `PROJECT`, `IMAGE`, and `ARG` are all predefined
   cat script-example.template.yaml | envsubst | kubectl create -f -
   ```
