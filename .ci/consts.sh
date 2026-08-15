#!/usr/bin/env bash
# shellcheck disable=SC2034  # read by .ci/ci_jobs.sh, which sources this file
#
# Versions for everything the pipeline runs. The runner image is not the source
# of truth: GitHub ships kind and kubectl and bumps them on its own schedule.
#
# kind and kubectl also carry checksums, because they decide which Kubernetes
# version the tests run against and a release asset can be re-uploaded under the
# same tag. trivy and actionlint only report, and the installer checks their
# version after unpacking.
#
# Refreshing a checksum:
#   kind    https://github.com/kubernetes-sigs/kind/releases/download/<ver>/kind-linux-<arch>.sha256sum
#   kubectl https://dl.k8s.io/release/<ver>/bin/linux/<arch>/kubectl.sha256

# kubectl tracks the node image in kind/cluster.yaml, not the newest release.
KIND_VERSION="v0.32.0"
KUBECTL_VERSION="v1.35.5"
TRIVY_VERSION="0.74.0"
ACTIONLINT_VERSION="1.7.12"

KIND_SHA256_amd64="50030de23cf40a18505f20426f6a8506bedf13c6e509244bd1fa9463721b0f54"
KIND_SHA256_arm64="b92cd615e97585de8ddade28ed5cd7feb4248d717c233eea5b03c37298900f5d"

KUBECTL_SHA256_amd64="90f75ea6ecc9ea5633262e1c0b83a40560003b30fc94a04cb099404fcef0c224"
KUBECTL_SHA256_arm64="ac69e06fd6860d69786692f5af1c3a1208ed54f8366a4d97ab15c172e99765ee"

# Trivy names its archives after the platform, not the GOARCH used elsewhere.
TRIVY_ARCHIVE_amd64="Linux-64bit"
TRIVY_ARCHIVE_arm64="Linux-ARM64"

SCAN_SEVERITY="HIGH,CRITICAL"

CLUSTER_NAME="echo-pong-k8s"

REGISTRY="${REGISTRY_OVERRIDE:-ghcr.io}"
IMAGE_NAME="${REGISTRY}/shahar-spormas/echo-pong"
