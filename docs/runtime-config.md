# Runtime Config and Secret Wiring

| | |
|---|---|
| **Status** | Verified on Kind (Kubernetes v1.35.5, single node, arm64) |
| **Component** | `k8s/configmap.yaml`, the `envFrom` and secret volume blocks of `k8s/deployment.yaml` |
| **Verification** | `scripts/smoke-test.sh` checks 3 and 4 |
| **Requires** | A `ping-pong-secret` Secret, created from the gitignored `secrets/token` |

## Decision

Two kinds of configuration, handled differently because they fail differently.

`PORT` and `SECRET_FILE_PATH` are not secret. They live in a ConfigMap and reach
the container through `envFrom`, so changing either is a manifest change rather
than an image rebuild, which is the acceptance criterion for issue #5.

The token is secret and reaches the process as a file, not an environment
variable. That is partly forced: `readSecretFromFile` at `main.go:31` opens
`SECRET_FILE_PATH` and `log.Fatal`s if it cannot. It is also the better shape.
Environment variables are visible in `kubectl describe pod`, inherited by any
child process, and routinely captured by crash reporters. A Secret volume is
tmpfs-backed, so the value lives in RAM and never touches the node's disk, and it
can be refreshed in place by the kubelet.

## Why not put the token in the ConfigMap too

It would work. One object, one `envFrom`, no volume. The reasons not to are worth
stating, because the usual objection is that Kubernetes Secrets are only
base64-encoded and are therefore no better than a ConfigMap. The premise is true
and the conclusion does not follow: base64 was never the protection.

Two of the differences are observable on the running cluster. Secret volumes are
tmpfs, mounted `noswap`:

```
$ mount | grep kubernetes.io~secret
tmpfs on /var/lib/kubelet/pods/.../volumes/kubernetes.io~secret/node-certs
  type tmpfs (rw,relatime,noswap)
```

The value lives in RAM, never lands on the node's disk, and cannot be paged out.
A ConfigMap volume is written to the node's filesystem, so the token would
persist on the disk of every node that ever ran a pod.

They also redact differently:

```
$ kubectl describe secret ping-pong-secret      $ kubectl describe configmap ping-pong-config
Data                                            Data
====                                            ====
token:  14 bytes                                PORT:
                                                ----
                                                8080
```

That is the difference between a screenshot, a bug report or a CI log being
harmless and being an incident.

Three more do not show up locally. `get configmaps` is handed out freely to
dashboards, pipelines and developers, while `get secrets` is the permission
people actually guard, so moving the token quietly widens who can read it.
Encryption at rest targets Secrets specifically, which is what EKS envelope
encryption with a KMS key covers. And every external secret manager worth using,
including the ones in the EKS section below, delivers its material as a Secret,
so a ConfigMap forecloses that path.

The decisive reason here is narrower. `k8s/configmap.yaml` is committed and is
applied by `kubectl apply -f k8s/`. The Secret is deliberately neither. Putting
the token in the ConfigMap means either committing it, which undoes issue #2, or
shipping a manifest that is permanently wrong on apply.

If base64 genuinely is not enough for the threat model, the answer is encryption
at rest or an external manager, not moving the value somewhere with fewer
protections.

## Nothing secret is in git

`secrets/` is gitignored, which is issue #2 and already closed. The Secret is
created from that file:

```bash
kubectl create secret generic ping-pong-secret --from-file=token=secrets/token
```

`scripts/smoke-test.sh` does this on every run and generates a random token first
if the file is absent, so CI never needs a real credential to exercise the path.

There is no committed Secret manifest, not even a placeholder one. That command
already states everything a template would: the object name, the `token` key, and
the type. A checked-in template would add nothing except a file that must never
be applied, sitting in a directory where everything else is applied by default.

## Three couplings that are not visible from one file

**`SECRET_FILE_PATH` and `mountPath`.** The ConfigMap says
`/etc/ping-pong/secret`; the volume mounts at `/etc/ping-pong` and projects the
`token` key to the filename `secret`. All three have to agree. They are split
across two files, and the failure is a `CrashLoopBackOff` whose log says the file
could not be opened.

**`PORT` and the container port.** Moving `PORT` into a ConfigMap makes it look
independently adjustable. It is not. The probes and the Service target the
container port *named* `http`, which is a literal `8080` in
`k8s/deployment.yaml`. Change the ConfigMap alone and the listener moves while
every probe keeps checking 8080, so the pods fail readiness and leave the
Service. The comment in `k8s/configmap.yaml` says so at the point of use.

**`defaultMode: 0440` and `fsGroup: 65532`.** A matched pair. Secret files are
root-owned by default, so tightening the mode without the `fsGroup` means UID
65532 cannot read its own token. Same `CrashLoopBackOff`, and nothing in the
message mentions permissions.

## How the smoke test proves it rather than reading it back

Checking that the Deployment references a ConfigMap proves only that the manifest
references a ConfigMap. The real evidence is behavioural:

```
3. Is the mounted secret actually enforcing auth?
  PASS  /ping without a token returned 401
  PASS  /pong without a token returned 401
  PASS  /ping with the token returned 200 and answered pong
  PASS  /pong with the token returned 200 and answered ping
  PASS  /ping with a wrong token returned 401

4. Is runtime config external to the image?
  PASS  config comes from ConfigMap/ping-pong-config, so a change needs no rebuild
```

A 401 without the token and a 200 with the exact bytes from `secrets/token` can
both happen only if the process opened the file at the path the ConfigMap
supplied. That single pair of results exercises the ConfigMap, the Secret, the
volume, the mode and the `fsGroup` together. The wrong-token case matters
separately: without it, an app that accepted any non-empty header would pass.

Check 4 also asserts the container declares no inline `env` at all, so config
cannot quietly drift back into the manifest or the image.

## What this does not cover

The secret is read once at startup, at `main.go:185`, before the server begins
listening. The kubelet refreshes the projected file, but this process never
re-reads it, so rotation needs `kubectl rollout restart deploy/ping-pong`. The
same is true of a ConfigMap change. Nothing here reloads.

Kubernetes Secrets are base64, not encrypted. Anyone with `get secret` in the
namespace, or read access to etcd, has the token. Meaningful protection needs
encryption at rest with a KMS provider and RBAC that does not grant secret reads
casually.

There is no `imagePullSecrets` in `k8s/deployment.yaml`, because the GHCR package
is public and naming a Secret that does not exist earns a warning event on every
pull. `docs/image-and-registry.md` covers the private path, which was exercised
end to end before the package was made public.

There is one token shared by every replica and every caller, with no identity, no
expiry and no revocation. That is the application's design and it is treated as
given.

## The same design on EKS

- The ConfigMap is unchanged. This part already works the same way anywhere.
- The Secret comes from AWS Secrets Manager or Parameter Store, projected by the
  Secrets Store CSI driver or synced by the External Secrets Operator, with the
  pod's service account bound to an IAM role through IRSA or EKS Pod Identity.
  The container keeps reading the same file path, so `main.go` is unaffected.
- That also fixes rotation: the CSI driver can rotate the projected file, though
  this application still needs a restart to notice, so a controller like Reloader
  hashes the source and triggers the rollout.
- Encryption at rest via a KMS key, and `get secret` removed from developer
  roles.

## Reproducing this

```bash
kubectl create secret generic ping-pong-secret --from-file=token=secrets/token
kubectl apply -f k8s/
./scripts/smoke-test.sh

# What the container actually received. No exec: the image is distroless and
# has no shell, which is the point of docs/security-risk-acceptance.md.
kubectl get deploy ping-pong \
  -o jsonpath='{.spec.template.spec.containers[0].envFrom}'
kubectl get pod -l app.kubernetes.io/name=ping-pong \
  -o jsonpath='{.items[0].spec.volumes}'

# Rotation, end to end.
openssl rand -hex 16 > secrets/token
kubectl create secret generic ping-pong-secret --from-file=token=secrets/token \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart deploy/ping-pong   # without this, nothing changes
```
