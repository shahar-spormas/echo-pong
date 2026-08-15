# Risk Acceptance: Go 1.24 Standard Library Vulnerabilities

| | |
|---|---|
| **Status** | Accepted, time-limited |
| **Raised** | 2026-08-07 |
| **Review by** | 2026-09-07 |
| **Component** | `ping-pong-game` container image |
| **Affected** | Go standard library linked into the application binary |
| **Base image** | `gcr.io/distroless/static-debian12:nonroot` — contributes **zero** vulnerabilities |
| **Enforced by** | `.trivyignore.yaml`, checked by `./.ci/ci_jobs.sh do_scan_image` on every build |

## Decision

The image is built with the Go 1.24 toolchain, as specified in the project
prerequisites and in `go.mod`. Go 1.24 reached end of life and its final release,
`go1.24.13`, carries 22 known standard library vulnerabilities with **no fix
available on the 1.24 line and no possibility of one**.

We accept this risk for now rather than deviating from the specified toolchain.
This document records the evidence, the analysis, and the conditions under which
the acceptance stops being valid.

## Finding

Trivy is the scanner the pipeline gates on, so it is the count that matters.
Against the image this repository builds today:

```
$ ./.ci/ci_jobs.sh do_scan_image
  19 HIGH, 0 CRITICAL, all in stdlib v1.24.13
  0 findings in OS packages
```

The zero on the second line is the distroless base earning its place: there are
no OS packages to be vulnerable. Every finding is in the Go standard library
compiled into the binary.

An earlier pass with Docker Scout reported 10 HIGH against the same package.
Scanners differ in which advisories they map to a Go release, which is a reason
to gate on one of them by name rather than on "a scan passed".

Cross-checked against OSV, which counts vulnerabilities at all severities:

```
$ curl -s -X POST https://api.osv.dev/v1/query \
    -d '{"package":{"name":"stdlib","ecosystem":"Go"},"version":"1.24.13"}'
22 vulnerabilities affecting stdlib 1.24.13
```

Every advisory lists its first fixed version in the 1.25, 1.26 or 1.27 series.
None lists a 1.24.x fix, because Go supports only the two most recent major
releases and 1.24 fell out of support before these patches shipped. The Go
release index confirms `go1.24.13` is the last 1.24 release; current stable is
`go1.26.5`, with 1.27 in release candidate.

All findings are in the standard library. No third-party module is implicated —
`go.mod` declares no dependencies.

## Reachability analysis

Presence in the binary is not the same as exploitability. Of the 19 Trivy
reports, three are on the request path: `net/url` parsing (CVE-2026-25679,
CVE-2026-56860) and `mime` header parsing (CVE-2026-42504). The rest are
`crypto/tls`, `crypto/x509`, `net/mail`, `encoding/asn1`, `encoding/xml`,
`html/template` and the resolver — linked in by `net/http` and never called by
a server that speaks plain HTTP, renders no templates and makes no outbound
requests. Per-advisory reasoning is in `.trivyignore.yaml`, one line each.

`govulncheck` in source mode agrees, on the advisory set it knew at the time.
Its call-graph analysis narrowed 22 advisories down to **9** with a path from
application code:

```
$ govulncheck ./...
Your code is affected by 9 vulnerabilities from the Go standard library.
This scan also found 5 vulnerabilities in packages you import and 8
vulnerabilities in modules you require, but your code doesn't appear to call
these vulnerabilities.
```

Reviewing those 9 against what this application actually does at runtime — it
serves plain HTTP via `http.ListenAndServe`, terminates no TLS, makes no
outbound requests, and reads exactly one file:

| Advisory | CVE | Package | Assessment |
|---|---|---|---|
| GO-2026-4601 | CVE-2026-25679 | `net/url` | **Exercised.** Request URIs from untrusted clients are parsed on every request. |
| GO-2026-5039 | CVE-2026-42507 | `net/textproto` | **Exercised.** `ReadMIMEHeader` parses attacker-supplied request headers. |
| GO-2026-4870 | CVE-2026-32283 | `crypto/tls` | Not exercised. The server speaks plain HTTP; no `tls.Conn` is ever constructed. |
| GO-2026-5856 | CVE-2026-42505 | `crypto/tls` | Not exercised. Client-side Encrypted Client Hello; no outbound TLS. |
| GO-2026-4946 | CVE-2026-32281 | `crypto/x509` | Not exercised. No certificate verification occurs. |
| GO-2026-4947 | CVE-2026-32280 | `crypto/x509` | Not exercised. No chain building occurs. |
| GO-2026-5037 | CVE-2026-27145 | `crypto/x509` | Not exercised. No hostname verification occurs. |
| GO-2026-4602 | CVE-2026-27139 | `os` | Not exercised. Affects the `os.Root` / `ReadDir` family; the app calls only `os.Open`, `os.Getenv`, `os.Exit`. |
| GO-2026-4971 | CVE-2026-39836 | `net` | Likely not applicable. The advisory describes Windows-specific NUL byte handling; the image runs Linux. Note the OSV record carries no formal GOOS constraint, so this is not a guaranteed exclusion. |

The seven "not exercised" entries appear because govulncheck's call graph is a
safe over-approximation — `net/http` links `crypto/tls` and `crypto/x509`
regardless of whether TLS is configured.

Three advisories in that table (CVE-2026-42507, CVE-2026-42505, CVE-2026-27139)
are not among Trivy's 19. The lists were produced by different tools at
different times, and neither is a superset of the other. Only the Trivy set has
an entry in `.trivyignore.yaml`, because only that set can block a build.

## How the pipeline enforces this

`do_scan_image` scans the image archive that was just built, before anything is
pushed, and fails on any HIGH or CRITICAL finding that is not listed in
`.trivyignore.yaml`. Listed findings are printed as an annotation on the run
rather than hidden, so the accepted set is visible on every build.

Two things this deliberately does not do. It does not use `--ignore-unfixed`,
which would exempt every unfixed vulnerability including ones nobody has looked
at — the unfixable findings here are enumerated by hand instead. And it does not
use `continue-on-error`, so the gate cannot pass while failing.

Each entry carries `expired_at: 2026-09-07`. On that date they stop suppressing
anything and the build fails until someone decides again. That is the mechanism
behind the "time-limited" in the status line above; without it, an accepted risk
quietly becomes a permanent one.

## Compensating controls

- The pod is not directly internet-facing; traffic arrives through an ingress
  that terminates TLS and normalizes requests before they reach the container.
- The container runs as UID/GID 65532 with a read-only root filesystem, all
  capabilities dropped, and `no-new-privileges` set.
- The base image is distroless: no shell, no package manager, no coreutils, so
  there is no post-exploitation tooling available inside the container.
- `/ping` and `/pong` require a bearer token; only `/health` and `/` are
  unauthenticated.
- The secret is mounted read-only at runtime and never baked into the image.

## Reproducing this analysis

```bash
# The scan the pipeline gates on, against a freshly built image.
./.ci/ci_jobs.sh do_build_image
./.ci/ci_jobs.sh do_scan_image

# The same findings without the accepted-risk file, which is what a new
# advisory in this package would look like.
trivy image --input .ci-artifacts/image-$(uname -m | sed s/x86_64/amd64/ \
  | sed s/aarch64/arm64/).tar --severity HIGH,CRITICAL

# Full advisory list including non-high severities
curl -s -X POST https://api.osv.dev/v1/query \
  -H 'Content-Type: application/json' \
  -d '{"package":{"name":"stdlib","ecosystem":"Go"},"version":"1.24.13"}'

# Call-graph reachability against the 1.24 toolchain
docker run --rm -v "$PWD:/src:ro" -w /src golang:1.24-alpine sh -c '
  GOTOOLCHAIN=auto go install golang.org/x/vuln/cmd/govulncheck@latest
  GOTOOLCHAIN=local /go/bin/govulncheck ./...'
```

## A note on Go and image rebuilds

Go statically links the standard library into the binary. Unlike a distribution
package, a stdlib vulnerability cannot be patched by updating a base layer — the
only remedy is recompiling with a fixed toolchain. An image sitting untouched in
the registry therefore accumulates vulnerabilities while its source never
changes.

The pipeline still has no scheduled rebuild, so an image is only ever scanned
against the advisory database as it stood on the day of the commit. A `schedule`
trigger running the same build and scan would catch a new advisory against an
unchanged source tree. That is the main gap left here.
