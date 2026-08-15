#!/usr/bin/env bash
# shellcheck disable=SC2034  # every value here is read by the script that sources this one
# Tool versions and their checksums, sourced by .ci/ci_jobs.sh.
#
# The runner image is not the version source. GitHub ships kind and kubectl
# preinstalled and bumps them on its own schedule, so a pipeline that takes
# whatever is on PATH silently changes its Kubernetes version between two runs
# of the same commit. Everything the pipeline depends on is pinned here, and
# every download is checksum-verified before it is allowed to run.
#
# Refreshing a pin:
#   kind       https://github.com/kubernetes-sigs/kind/releases/download/<ver>/kind-linux-<arch>.sha256sum
#   kubectl    https://dl.k8s.io/release/<ver>/bin/linux/<arch>/kubectl.sha256
#   actionlint https://github.com/rhysd/actionlint/releases/download/<ver>/actionlint_<ver>_checksums.txt

# kubectl tracks the node image in kind/cluster.yaml rather than the newest
# release: skew against a much older server is supported, but testing the
# version we actually ship is worth more than being current.
KIND_VERSION="v0.32.0"
KUBECTL_VERSION="v1.35.5"
ACTIONLINT_VERSION="1.7.12"

KIND_SHA256_amd64="50030de23cf40a18505f20426f6a8506bedf13c6e509244bd1fa9463721b0f54"
KIND_SHA256_arm64="b92cd615e97585de8ddade28ed5cd7feb4248d717c233eea5b03c37298900f5d"

KUBECTL_SHA256_amd64="90f75ea6ecc9ea5633262e1c0b83a40560003b30fc94a04cb099404fcef0c224"
KUBECTL_SHA256_arm64="ac69e06fd6860d69786692f5af1c3a1208ed54f8366a4d97ab15c172e99765ee"

ACTIONLINT_SHA256_amd64="8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8"
ACTIONLINT_SHA256_arm64="325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6"

CLUSTER_NAME="echo-pong-k8s"
