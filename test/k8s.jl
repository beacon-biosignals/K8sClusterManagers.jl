using Mustache

const PKG_DIR = abspath(@__DIR__, "")
const GIT_DIR = joinpath(PKG_DIR, ".git")
const GIT_REV = try
    readchomp(`git --git-dir $GIT_DIR rev-parse --short HEAD`)
catch
    # Fallback to using the full SHA when git is not installed
    LibGit2.with(LibGit2.GitRepo(GIT_DIR)) do repo
        string(LibGit2.GitHash(LibGit2.GitObject(repo, "HEAD")))
    end
end

const TEST_IMAGE = "k8s-cluster-managers:$GIT_REV"
const JOB_TEMPLATE = Mustache.load("job.template.yaml")

function parse_env(str::AbstractString)
    env = Pair{String,String}[]
    for line in split(str, '\n')
        if startswith(line, "export")
            name, value = split(replace(line, "export " => ""), '=')
            value = replace(value, r"^([\"'])(.*)\1$" => s"\2")
            push!(env, name => value)
        end
    end

    return env
end

# TODO: Look into alternative way of accessing the image inside of minikube that is agnostic
# of the local Kubernetes distro being used: https://minikube.sigs.k8s.io/docs/handbook/pushing/
withenv(parse_env(read(`minikube docker-env`, String))...) do
    run(`docker build -t $TEST_IMAGE $PKG_DIR`)
end

function manager_start(job_name, code)
    job_yaml = render(JOB_TEMPLATE,
                      job_name=job_name,
                      image=TEST_IMAGE,
                      command=["julia", "-e", code])

    p = open(`kubectl apply -f -`, "w+")
    write(p.in, job_yaml)
    close(p.in)
    return read(p.out, String)
end
