# Image Distribution: Multi-Arch, Registry Pulls and Architecture Preference

| | |
|---|---|
| **Status** | Verified on Kind (Kubernetes v1.35.5, single node, arm64) |
| **Component** | `Dockerfile`, the `image` and `imagePullPolicy` fields of `k8s/deployment.yaml` |
| **Verification** | `scripts/smoke-test.sh` check 5 |
| **Image** | `ghcr.io/shahar-spormas/echo-pong:v0.1.0` |

> The multi-arch build described here was done by hand. It is now
> `.github/workflows/ci.yml`; see "How this is built now" at the end.

## Decision

One tag resolves to both architectures, the cluster fetches it from GHCR rather
than having it handed to them, and ARM64 is a preference rather than a
requirement.

The build was already portable: the `Dockerfile` takes `TARGETOS` and
`TARGETARCH` from BuildKit and cross-compiles with `CGO_ENABLED=0`, so producing
a second architecture costs a `--platform` flag and no code. What issue #6 adds
is the distribution half.

## What the tag actually contains

```
$ docker buildx imagetools inspect ghcr.io/shahar-spormas/echo-pong:v0.1.0

Name:      ghcr.io/shahar-spormas/echo-pong:v0.1.0
MediaType: application/vnd.oci.image.index.v1+json
Digest:    sha256:469fecce022210ca822fe936df1175b383274c37cfcf0cfdc986078b8b429c50

  linux/amd64   sha256:8f12873070974771b560931165be4cda620629cc489e0aaf2641d305d011a477
  linux/arm64   sha256:16ccdd356fccd3b4a1f8ea5d644002d281c671d0d713f4ee0480459dbd315b22
  unknown       attestation-manifest for linux/amd64
  unknown       attestation-manifest for linux/arm64
```

The tag is an OCI image index, not an image. A client sends its platform and the
registry hands back the matching manifest, which is why the same string works on
an arm64 laptop and an amd64 node with nothing architecture-specific in
`k8s/deployment.yaml`.

The two `unknown/unknown` entries are SLSA provenance attestations that buildx
attaches by default. They record how the image was built. They are not
signatures, and nothing verifies them at admission yet.

The compressed image is 2,962,477 bytes. Almost all of that is the Go binary:
the base is `gcr.io/distroless/static-debian12:nonroot`, which contributes no
packages and, per `docs/security-risk-acceptance.md`, no vulnerabilities.

## Where the ARM64 preference belongs

The pod spec says nothing about architecture. That is deliberate, and it is the
one decision here most likely to be challenged, so the reasoning is worth
setting out.

The obvious move is a node affinity on `kubernetes.io/arch: arm64`, soft rather
than hard so an amd64-only cluster does not leave every replica `Pending`. It was
written that way and then removed, because on a homogeneous cluster it does
nothing at all: every node already matches, the scheduler ranks a single
candidate, and the block is inert. It only starts to matter in a genuinely mixed
cluster.

In a mixed cluster, though, the pod spec is the wrong layer to express it. What
architecture a workload lands on is a property of the capacity you provisioned,
not of the workload, and it is decided by node groups or a Karpenter node pool.
Encoding it per-Deployment means every new workload has to remember to repeat it,
and a workload that forgets silently lands anywhere. Setting the arch at the node
pool and letting the scheduler fill it is the version that does not rot.

That leaves the workload with one obligation, which is to be genuinely
architecture-agnostic so the infrastructure is free to choose. That is exactly
what the image index above provides, and it is what
`.github/workflows/ci.yml` checks by running the whole suite on both an
amd64 and an arm64 runner. Preference expressed as a scheduling hint is a claim;
a green build on both architectures is evidence.

If a mixed cluster later needs ARM capacity protected rather than merely
preferred, the answer is a taint on the ARM nodes and a toleration on the
workloads entitled to them. A soft affinity would not have achieved that anyway,
since the scheduler is free to ignore a preference under pressure.

## Proving a pull happened, rather than assuming it

An image reference in a manifest proves nothing about where the bytes came from.
Kind makes this concrete: `kind load docker-image` copies a local image straight
into the node's store, and with `imagePullPolicy: IfNotPresent` the kubelet then
never contacts a registry. The pods run, the manifest says `ghcr.io/...`, and
nothing was ever pulled.

The tell is in the resolved `imageID`, which is what check 5 reads:

```
side-loaded:  docker.io/library/import-2026-08-08@sha256:340fb54e51ce...
pulled:       ghcr.io/shahar-spormas/echo-pong@sha256:469fecce0222...
```

The evidence that this is a real dependency on the registry, and not a cache
artefact, came from applying the manifests to a freshly created cluster while
the package was still private:

```
NAME                         READY   STATUS             RESTARTS   AGE
ping-pong-5674cd69c8-lbwh9   0/1     ImagePullBackOff   0          20s

Failed to pull image "ghcr.io/shahar-spormas/echo-pong:v0.1.0": failed to
resolve reference: failed to authorize: failed to fetch anonymous token:
unexpected status from GET request to https://ghcr.io/token?scope=
repository%3Ashahar-spormas%2Fecho-pong%3Apull&service=ghcr.io: 401 Unauthorized
```

A cluster that had the image cached could not have produced that. After adding
the pull secret:

```
Successfully pulled image "ghcr.io/shahar-spormas/echo-pong:v0.1.0" in 3.889s.
Image size: 2962477 bytes.
```

Check 5 is gated behind `ASSERT_REGISTRY_PULL`, off by default, because CI
side-loads the image it just built and asserting a registry pull there would be
asserting something the pipeline deliberately did not do. The registry path is
proven instead by `do_verify_published`, which pulls the published tag once per
architecture.

## Registry credentials

The package was published private, which is GHCR's default for a new package,
and the pull-secret path was exercised end to end before making it public:

```bash
kubectl create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io --docker-username=shahar-spormas \
  --docker-password="$(gh auth token)"
```

It is now public, so `k8s/deployment.yaml` carries no `imagePullSecrets` at all.
Leaving one in would not be harmless: naming a Secret that does not exist earns a
warning event on every pull. Restoring the private path means recreating the
Secret above and adding two lines to the pod spec:

```yaml
imagePullSecrets:
  - name: ghcr-pull
```

Publishing needs a token with `write:packages`, which the default `gh` OAuth
token does not carry: `gh auth refresh -h github.com -s write:packages`.

## Tag, not digest

The image is referenced by the tag `v0.1.0` rather than
`@sha256:469fecce...`, even though a digest is the stronger reference: it is
immutable, and a tag can be repointed under you.

Two reasons. A digest reference breaks `kind load`, because a locally built
image has no `RepoDigests` until it has been pushed or pulled, so the kubelet
tries to resolve a digest that exists in no registry, which is the pull-request
path in CI. And the tag here is immutable by convention, since issue #8 will
make releases append-only.

In production the answer flips: deploy by digest, resolved at release time by
the pipeline, so a rollback is exact and a repointed tag cannot change what is
running. The digest is recorded above precisely so that is possible.

`imagePullPolicy` is the explicit `IfNotPresent`, which is also the default,
except that it silently becomes `Always` when the tag is `latest`. That is one
of several reasons this never deploys `latest`.

## How this is built now

`.github/workflows/ci.yml` does what the section above did by hand, and issue #7
is closed by it. The shape:

- Each architecture builds on a runner of that architecture — `ubuntu-24.04` and
  `ubuntu-24.04-arm` — rather than one runner emulating the other through QEMU.
  The `Dockerfile` already cross-compiles from `$BUILDPLATFORM`, so this is
  about the evidence rather than the build: the whole Kubernetes suite runs on
  both, and a green run on each is a stronger claim than a manifest that lists
  two platforms.
- The build happens once per architecture and is saved as a tarball. The scan,
  the cluster test and the publish job all work from that tarball, so the thing
  that gets shipped is the thing that was judged. Nothing is rebuilt in between.
- The scan and the cluster test are sibling jobs rather than consecutive steps,
  so a scan failure does not hide the rollout result, and each installs only the
  tools it needs.
- Publishing happens only on a push to `main`, and only after both the scan and
  the cluster test have passed on both architectures. Pull requests are never
  given registry credentials, so a fork cannot reach the registry at all.
- Tags are `v<VERSION>-<7-char commit>`, from the `VERSION` file plus the
  commit. No `latest`, no branch tags. The full commit is in the image's
  `org.opencontainers.image.revision` label.
- Before pushing, the job checks whether the tag already exists. Same revision
  means a rerun and it is left alone; a different revision means two commits
  shortened to the same seven characters, and it fails rather than repointing a
  published tag.
- `do_verify_published` then pulls the tag once per architecture and checks the
  revision label, because an index entry is a promise and a pull is evidence.

Attestations are turned off in CI. Buildx wraps even a single-platform build in
an index whose extra manifests reference their subject by digest, and that
survives `docker save` and `docker load` only on a daemon with the containerd
image store — so the archive would be shaped differently depending on the
runner. They were decorative anyway, since nothing verifies them at admission.

## What this does not cover

Versioning stops at snapshot tags. Every commit on `main` gets its own
immutable tag, but there is no release process, no semver tag on the registry
and no GitHub Release. That is issue #8, and it should attach a version to the
digest this pipeline already published rather than rebuild it.

Nothing is signed, and nothing verifies provenance at admission.

There is no retention policy. Every push accumulates, and a per-commit tagging
scheme accumulates faster than the manual one it replaced. Untagged manifests
left behind by re-pushing are invisible in the UI but still stored. Issue #17.

No scheduled rebuild, so an image is only scanned against the advisory database
as it stood on the day of its commit. `docs/security-risk-acceptance.md` has the
argument in full.

## The same design on AWS

- ECR replaces GHCR. Multi-arch works identically, since the image index is an
  OCI standard rather than a registry feature.
- Nodes authenticate through the instance role or IRSA rather than a pull
  secret, which removes the credential from the cluster entirely. This is
  strictly better than the `ghcr-pull` Secret above.
- For teams spread across regions, the fix for slow pulls is ECR cross-region
  replication so each region pulls locally, plus a pull-through cache for
  upstream images. Both are configuration, not architecture. Issue #19.
- ARM64 becomes a Karpenter node pool or a managed node group constrained to
  `arm64`, which is the layer the preference belongs to. Graviton capacity is
  cheaper, and because the image carries both architectures, a pool that runs
  out can fall back to amd64 without touching a single workload manifest.
- ECR lifecycle policies handle the retention gap, expiring untagged images
  after a few days and capping the number of released tags kept.

## Reproducing this

```bash
# Publish. Needs a token with write:packages.
gh auth token | docker login ghcr.io -u "$GITHUB_USER" --password-stdin
docker buildx build --platform linux/amd64,linux/arm64 \
  --build-arg VERSION=v0.1.0 --build-arg REVISION="$(git rev-parse --short HEAD)" \
  -t ghcr.io/shahar-spormas/echo-pong:v0.1.0 --push .

# What is in the tag.
docker buildx imagetools inspect ghcr.io/shahar-spormas/echo-pong:v0.1.0

# Prove the cluster pulls it, starting from a node with no cached copy.
RECREATE=1 ./scripts/cluster-up.sh
ASSERT_REGISTRY_PULL=1 ./scripts/smoke-test.sh

# By hand:
kubectl get pods -l app.kubernetes.io/name=ping-pong \
  -o jsonpath='{range .items[*]}{.status.containerStatuses[0].imageID}{"\n"}{end}'
kubectl get events --field-selector reason=Pulled -o custom-columns=MSG:.message
```
