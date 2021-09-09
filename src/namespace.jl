const DEFAULT_NAMESPACE = "default"
const NAMESPACE_FILE = "/var/run/secrets/kubernetes.io/serviceaccount/namespace"


"""
    config_namespace() -> Union{String,Nothing}

Determine the Kubernetes namespace as specified by the current config context. If the
namespace is not set, the current context is not set, or the current context is not defined
then `nothing` will be returned.
"""
function config_namespace()
    # https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/
    #
    # Equivalent to running `kubectl config view --minify --output='jsonpath={..namespace}'`
    # but improves handling of corner cases.

    output = "jsonpath={.current-context}"
    context = read(`$(kubectl()) config view --output=$output`, String)
    isempty(context) && return nothing

    # Note: The output from `kubectl config view` reports a missing `namespace` entry,
    # `namespace: null`, and `namespace: ""` as the same.
    output = "jsonpath={.contexts[?(@.name=='$context')].context.namespace}"
    namespace = read(`$(kubectl()) config view --output=$output`, String)
    return !isempty(namespace) ? namespace : nothing
end


"""
    pod_namespace() -> Union{String,Nothing}

Determine the namespace of the pod if running inside of a Kubernetes pod, otherwise return
`nothing`.
"""
function pod_namespace()
    return if @mock isfile(NAMESPACE_FILE)
        @mock read(NAMESPACE_FILE, String)
    else
        nothing
    end
end


"""
    current_namespace() -> String

Determine the Kubernetes namespace as specified by the current config or, when running
inside a pod, the namespace of the pod. If the namespace is cannot be determined the default
namespace ("$DEFAULT_NAMESPACE") will be returned.
"""
function current_namespace()
    namespace = config_namespace()
    namespace !== nothing && return namespace

    namespace = pod_namespace()
    namespace !== nothing && return namespace

    return DEFAULT_NAMESPACE
end
