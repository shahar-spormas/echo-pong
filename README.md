# 🏓 DevOps: Ping-Pong Game Deployment

## 📋 Overview

**⏱️ Duration:** 2-3 hours  
**🎯 Objective:** Create a production-ready CI/CD pipeline that builds, containerizes, and deploys a Go application to Kubernetes.

---

## 🚀 Application

A Go HTTP server implementing a ping-pong game with these endpoints:

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/ping` | GET | Returns "pong" message |
| `/pong` | GET | Returns "ping" message |
| `/health` | GET | Health check endpoint |
| `/` | GET | API documentation |

**Environment Variables:**
- `PORT` - Server port (default: 8080)
- `SECRET_FILE_PATH` - Path to secret file

**Run Modes:** `server` or `cli`

**Authentication:**
- `Authorization` header with secret token is required for `/ping` and `/pong` endpoints
- in CLI mode, the secret token is passed as a command line argument

**Note:**
- The server will think for 10 seconds before starting the server
- health check endpoint is available at `/health` and it will return 200 OK if the server is ready to serve requests
- The server will be available on the port specified in the `PORT` environment variable
- The server will read the secret token from the `SECRET_FILE_PATH` environment variable
- The secret token is passed as a command line argument in CLI mode

---

## 🎯 Mission

Take this application to production with support for both **x86** and **ARM64** architectures. Have a binary release and a container release available for developers and production.

---

## 📋 Requirements

### 🔒 Security
- [ ] No containers running as root
- [ ] All images must pass security scans
- [ ] No critical/high vulnerabilities should be released to production
- [ ] No secrets in codebase
- [ ] Proper filesystem isolation

### ☸️ Kubernetes
- [ ] Zero-downtime deployments server must be available and ready at all times
- [ ] ARM64 architecture preferred
- [ ] No direct internet access (use ingress/proxy)
- [ ] Cluster can pull from registry

### 🏗️ CI/CD
- [x] Multi-architecture builds (x86/ARM64)
- [x] Images stored in GitHub Container Registry
- [ ] Versioned releases with tags
- [ ] Both container and binary releases

---

## 🛠️ Environment

**Prerequisites:**
- Docker
- Kind (the cluster is defined in `kind/cluster.yaml`; Minikube needs its own ingress setup)
- Kubernetes 1.30 to 1.35. The floor is `lifecycle.preStop.sleep`, which older kubelets ignore silently. The ceiling is the ingress controller, not this application. Both are explained in `docs/deployment-design.md` and `docs/exposure-design.md`.
- kubectl
- Go 1.24 (there are CVEs that are not fixed in that version, will consider them as accepted)
- GitHub account
- Host ports 80 and 443 free, so the ingress is reachable at `http://localhost`

---

## ⚡ Local quickstart

```bash
./scripts/cluster-up.sh     # Kind + Calico + ingress-nginx, every version pinned
./scripts/smoke-test.sh     # deploys, then asserts exposure, auth, config and policy
./scripts/verify-zdd.sh     # asserts availability across a rolling update
```

`cluster-up.sh` is idempotent and reuses an existing cluster; `RECREATE=1` rebuilds
it from scratch. `smoke-test.sh` generates a throwaway token into the gitignored
`secrets/` on first run, so no credential is needed to try this.

Reaching it by hand, noting the Ingress is host-based:

```bash
curl -H 'Host: ping-pong.local' http://localhost/health
curl -H 'Host: ping-pong.local' -H "Authorization: Bearer $(cat secrets/token)" \
  http://localhost/ping
```

To run the container without Kubernetes, `./scripts/build.sh && ./scripts/run.sh`.

---

## 🔁 CI

`.github/workflows/ci.yml` decides when things run; every step is a function in
`.ci/ci_jobs.sh`, so the pipeline can be run and linted without pushing:

```bash
./.ci/ci_jobs.sh              # list the jobs
./.ci/ci_jobs.sh do_scan_image
```

Each architecture builds once, on a runner of that architecture, and the scan
and the Kubernetes suite both work from that one tarball:

```text
static-checks
     |
   build (amd64, arm64)  ->  image tarball
     |            |
   scan          e2e          in parallel, both from that tarball
     |            |
      `-> publish <-'         only on a version tag
             |
      verify-published
             |
      GitHub Release          binaries and notes
```

A pull request stops after `scan` and `e2e` and never holds registry
credentials. Pushes to `main` run nothing: a squash merge lands the tree the
pull request already tested.

A few things worth knowing:

- **Versions.** Only a tag builds and publishes. Pushing `v1.2.3` runs the gates and then
  publishes one image under two names, `v1.2.3` and `v1.2.3-<7-char commit>`,
  plus the Linux `amd64` and `arm64` binaries on a GitHub Release. No `latest`,
  and no published tag is ever moved. Cutting a release is two steps:

```bash
# VERSION and the tag have to agree, or the run fails before it builds.
echo 1.2.3 > VERSION && git commit -am 'release 1.2.3' && git push
git tag v1.2.3 && git push origin v1.2.3
```
- **Tools.** kind, kubectl, Trivy and actionlint are pinned in `.ci/consts.sh`
  rather than taken from whatever the runner image ships. kind and kubectl are
  checksum-verified too, since they decide the Kubernetes version under test.
- **Scanning.** HIGH and CRITICAL findings fail the build unless they are listed
  in `.trivyignore.yaml`, where every entry expires on 2026-09-07. See
  `docs/security-risk-acceptance.md`.
- **What gets published.** The image the publish job pushes is the tarball the
  tests ran against, not a rebuild. The released binary is lifted out of that
  same image rather than compiled again.

### Running a release binary

For anyone who wants the CLI without Docker or a cluster:

```bash
TAG=v0.1.0
BASE=https://github.com/shahar-spormas/echo-pong/releases/download/$TAG
curl -LO $BASE/ping-pong-app-linux-amd64      # or -linux-arm64
curl -LO $BASE/SHA256SUMS
sha256sum -c SHA256SUMS --ignore-missing
chmod +x ping-pong-app-linux-amd64
```

Both modes read the secret from the file named by `SECRET_FILE_PATH`. In CLI
mode `--password` is the value checked against it:

```bash
echo -n mysecret > token
SECRET_FILE_PATH=./token ./ping-pong-app-linux-amd64 --mode=cli --password=mysecret ping
SECRET_FILE_PATH=./token ./ping-pong-app-linux-amd64 --mode=server
```

---

## 📐 Design notes

Each document states a decision, the evidence for it, and what it does not cover.

- `docs/deployment-design.md` — zero-downtime rollouts: probes, the `preStop` hook, and the disruption budget
- `docs/exposure-design.md` — Service, Ingress, the NetworkPolicy, and why the ingress controller is a retired project
- `docs/runtime-config.md` — ConfigMap and Secret wiring, and the couplings that span files
- `docs/image-and-registry.md` — multi-arch build, the registry pull, architecture preference, and how CI publishes
- `docs/security-risk-acceptance.md` — the Go 1.24 standard library CVEs, why they are accepted, and how the scan gate enforces that

---

## 📊 Evaluation

### Technical Implementation
- Container Security
- Kubernetes Manifests and best practices
- CI/CD Pipeline container and binary releases
- Multi-Architecture builds 
- Security Scanning and release prevention for critical and high vulnerabilities

### Understanding & Explanation
- Architecture decisions
- Scaling strategy
- Cloud deployment considerations
- Security measures
- Maintaining image versions and tags and removing old ones

---

## 📝 Deliverables

- [ ] `Dockerfile`
- [ ] `k8s/` manifests
- [ ] `.github/workflows/` CI/CD pipeline
- [ ] Documentation of your approach

**Note:** Use Minikube/Kind for testing. Be prepared to explain real cloud deployment strategy.

## You will be asked to explain the following:
- The deployment strategy
- The scaling strategy
- The security measures
- The CI/CD pipeline
- The multi-architecture builds
- The versioning and tagging strategy
- Going cloud with EKS and how to deploy the application to EKS
- How to allow teams from across the world to pull the image fast using AWS solutions
- How to manage older and stale versions of the application

## Submission
- Create a fork of this repository and give access to your fork
- Once you notify that you are done no more commits!

---

**Good luck! 🚀**
