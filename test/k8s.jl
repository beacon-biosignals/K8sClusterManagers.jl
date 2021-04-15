using LibGit2
using Mustache

const PKG_DIR = abspath(@__DIR__, "..")
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


let job_name = "test-worker-success"
    @testset job_name begin
        code = """
            using Distributed, K8sClusterManagers
            K8sClusterManagers.addprocs_pod(1, retry_seconds=60)

            println("Num Processes: ", nprocs())
            for i in workers()
                # TODO: HOSTNAME is the name of the pod. Maybe should return other info
                println("Worker pod \$i: ", remotecall_fetch(() -> ENV["HOSTNAME"], i))
            end
            """

        command = ["julia", "-e", code]
        config = render(JOB_TEMPLATE; job_name, image=TEST_IMAGE, command)
        open(`kubectl apply -f -`, "w", stdout) do p
            write(p.in, config)
        end

        # Wait for job to reach status: "Complete" or "Failed"
        job_status_cmd = `kubectl get job/$job_name -o 'jsonpath={..status..type}'`
        while isempty(read(job_status_cmd, String))
            sleep(1)
        end

        manager_pod = "pod/$job_name"
        worker_pod = "pod/$job_name-worker-9001"

        @info "Logs for manager:\n" * read(`kubectl logs $manager_pod`, String)
        @info "Logs for worker:\n" * read(`kubectl logs $worker_pod`, String)
    end
end
