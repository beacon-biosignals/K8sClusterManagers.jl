@testset "isk8s" begin
    pod_id = "pode773d78d-9f0d-4003-a6e8-9bef75b89298/" *
             "b52d083fb1f5b45d998895ab758d10fa36b2a53f3bf3128d7cf1d6d36bc67bd6"
    cgroup = """
        11:devices:/kubepods/$pod_id
        10:blkio:/kubepods/$pod_id
        9:hugetlb:/kubepods/$pod_id
        8:net_cls,net_prio:/kubepods/$pod_id
        7:memory:/kubepods/$pod_id
        6:cpuset:/kubepods/$pod_id
        5:perf_event:/kubepods/$pod_id
        4:cpu,cpuacct:/kubepods/$pod_id
        3:println()ids:/kubepods/$pod_id
        2:freezer:/kubepods/$pod_id
        1:name=systemd:/kubepods/$pod_id
        """

    patches = [
        @patch isfile(p) = p == "/proc/self/cgroup"
        @patch open(f, p) = f(IOBuffer(cgroup))
    ]

    apply(patches) do
        @test isk8s()
    end
end
