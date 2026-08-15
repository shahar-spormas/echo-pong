#!/usr/bin/env bash
# Every step .github/workflows/ci.yml runs. The workflow decides when a job
# runs and what it may touch; this file is what it does. Nothing here needs the
# Actions runtime, so any job can be run by hand:
#
#   ./.ci/ci_jobs.sh do_build_image

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=.ci/consts.sh
. "${ROOT_DIR}/.ci/consts.sh"

SUPPORTED_CI_JOBS="do_static_checks do_setup_tools do_build_image do_k8s_e2e"
SUPPORTED_CI_JOBS="${SUPPORTED_CI_JOBS} do_print_version do_diagnostics"

# Pinned tools go here rather than /usr/local/bin, so no job needs sudo.
CI_BIN_DIR="${ROOT_DIR}/.ci/bin"
PATH="${CI_BIN_DIR}:${PATH}"
export PATH

CI_ARTIFACT_DIR="${CI_ARTIFACT_DIR:-${ROOT_DIR}/.ci-artifacts}"
CI_IMAGE_NAME="${CI_IMAGE_NAME:-${IMAGE_NAME}}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_error() {
    echo "${SCRIPT_NAME}: $*" >&2
    exit 1
}

_info() {
    echo "==> $*"
}

_warn() {
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        echo "::warning::$*"
    else
        echo "WARNING: $*" >&2
    fi
}

_summary() {
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        printf '%s\n' "$*" >> "${GITHUB_STEP_SUMMARY}"
    fi
}

_require_cmd() {
    local cmd
    for cmd in "$@"; do
        command -v "${cmd}" >/dev/null 2>&1 || _error "${cmd} is not on PATH"
    done
}

_ci_arch() {
    case "${CI_ARCH:-$(uname -m)}" in
        x86_64 | amd64) echo amd64 ;;
        aarch64 | arm64) echo arm64 ;;
        *) _error "unsupported architecture: ${CI_ARCH:-$(uname -m)}" ;;
    esac
}

_ci_commit_sha() {
    if [ -n "${CI_COMMIT_SHA:-}" ]; then
        echo "${CI_COMMIT_SHA}"
    else
        git -C "${ROOT_DIR}" rev-parse HEAD
    fi
}

# Sliced, not `git rev-parse --short`: core.abbrev auto-scales with repository
# size, and a tag has to be the same width everywhere.
_ci_short_sha() {
    local sha
    sha="$(_ci_commit_sha)"
    echo "${sha:0:7}"
}

# v0.1.0-1a2b3c4. Issue #8 adds release tags on top of this.
_ci_image_version() {
    local base
    [ -f "${ROOT_DIR}/VERSION" ] || _error "no VERSION file at ${ROOT_DIR}/VERSION"
    base="$(tr -d '[:space:]' < "${ROOT_DIR}/VERSION")"
    [ -n "${base}" ] || _error "VERSION is empty"
    echo "v${base}-$(_ci_short_sha)"
}

_ci_image_ref() {
    echo "${CI_IMAGE_NAME}:$(_ci_image_version)"
}

_ci_image_archive() {
    echo "${CI_ARTIFACT_DIR}/image-$(_ci_arch).tar"
}


# Only Linux builds are pinned, since that is all CI runs. A laptop brings its
# own tools and is told they may not match.
_require_pinned_or_local() {
    local tool="$1" wanted="$2"

    [ "$(uname -s)" = "Linux" ] && return 1

    command -v "${tool}" >/dev/null 2>&1 \
        || _error "${tool} is not installed, and ${SCRIPT_NAME} only installs pinned Linux builds"
    _warn "using the ${tool} on PATH; it may not be ${wanted}"
    return 0
}

_fetch() {
    local url="$1" dest="$2"

    curl --fail --silent --show-_error --location \
        --retry 3 --retry-connrefused --retry-delay 5 \
        -o "${dest}" "${url}" || _error "could not download ${url}"
}

_fetch_verified() {
    local url="$1" expected="$2" dest="$3" actual

    _fetch "${url}" "${dest}"

    actual="$(sha256sum "${dest}" | cut -d' ' -f1)"
    if [ "${actual}" != "${expected}" ]; then
        rm -f "${dest}"
        _error "checksum mismatch for ${url}: expected ${expected}, got ${actual}"
    fi
}

# Reads KIND_SHA256_amd64 and friends, so consts.sh can stay a flat list.
_consts_lookup() {
    local name="$1"
    eval "printf '%s' \"\${${name}:-}\""
}

_tool_is_pinned() {
    local actual="$1" wanted="$2"
    [ -n "${actual}" ] && [ "${actual}" = "${wanted}" ]
}

_install_kind() {
    local arch="$1" current=""

    if command -v kind >/dev/null 2>&1; then
        current="v$(kind version -q 2>/dev/null || true)"
    fi

    if _tool_is_pinned "${current}" "${KIND_VERSION}"; then
        _info "kind ${KIND_VERSION} already present"
        return 0
    fi

    _require_pinned_or_local kind "${KIND_VERSION}" && return 0

    _info "installing kind ${KIND_VERSION} (found '${current:-none}')"
    _fetch_verified \
        "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-${arch}" \
        "$(_consts_lookup "KIND_SHA256_${arch}")" \
        "${CI_BIN_DIR}/kind"
    chmod +x "${CI_BIN_DIR}/kind"
}

_install_kubectl() {
    local arch="$1" current=""

    if command -v kubectl >/dev/null 2>&1; then
        current="$(kubectl version --client -o json 2>/dev/null \
            | jq -r '.clientVersion.gitVersion // empty' || true)"
    fi

    if _tool_is_pinned "${current}" "${KUBECTL_VERSION}"; then
        _info "kubectl ${KUBECTL_VERSION} already present"
        return 0
    fi

    _require_pinned_or_local kubectl "${KUBECTL_VERSION}" && return 0

    _info "installing kubectl ${KUBECTL_VERSION} (found '${current:-none}')"
    _fetch_verified \
        "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${arch}/kubectl" \
        "$(_consts_lookup "KUBECTL_SHA256_${arch}")" \
        "${CI_BIN_DIR}/kubectl"
    chmod +x "${CI_BIN_DIR}/kubectl"
}

_install_actionlint() {
    local arch="$1" tmp installed

    if command -v actionlint >/dev/null 2>&1 \
        && _tool_is_pinned "$(actionlint -version 2>/dev/null | head -1)" "${ACTIONLINT_VERSION}"; then
        _info "actionlint ${ACTIONLINT_VERSION} already present"
        return 0
    fi

    _require_pinned_or_local actionlint "${ACTIONLINT_VERSION}" && return 0

    _info "installing actionlint ${ACTIONLINT_VERSION}"
    tmp="$(mktemp -d)"
    _fetch \
        "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_${arch}.tar.gz" \
        "${tmp}/actionlint.tar.gz"
    tar -xzf "${tmp}/actionlint.tar.gz" -C "${tmp}" actionlint
    mv "${tmp}/actionlint" "${CI_BIN_DIR}/actionlint"
    chmod +x "${CI_BIN_DIR}/actionlint"
    rm -rf "${tmp}"

    installed="$(actionlint -version | head -1)"
    _tool_is_pinned "${installed}" "${ACTIONLINT_VERSION}" \
        || _error "installed actionlint reports ${installed}, expected ${ACTIONLINT_VERSION}"
}

# ---------------------------------------------------------------------------
# Jobs
# ---------------------------------------------------------------------------

do_static_checks() {
    _info "Stage: static checks"
    mkdir -p "${CI_BIN_DIR}"
    _require_cmd curl sha256sum tar shellcheck
    _install_actionlint "$(_ci_arch)"

    actionlint

    local failures=0 script
    while IFS= read -r script; do
        bash -n "${script}" || failures=$((failures + 1))
    done < <(find "${ROOT_DIR}/scripts" "${ROOT_DIR}/.ci" -name '*.sh' -type f | sort)
    [ "${failures}" -eq 0 ] || _error "${failures} script(s) failed the syntax check"

    # Warnings and errors only: a gate that fires on style notices gets muted,
    # and then nobody reads the warnings either.
    # SC1091: consts.sh is sourced through a path shellcheck cannot follow.
    shellcheck --severity=warning --external-sources --exclude=SC1091 \
        "${ROOT_DIR}"/scripts/*.sh "${ROOT_DIR}"/.ci/*.sh

    _info "static checks passed"
}

do_setup_tools() {
    _info "Stage: tool setup"
    local arch
    arch="$(_ci_arch)"

    mkdir -p "${CI_BIN_DIR}"
    _require_cmd curl sha256sum tar jq docker

    _install_kind "${arch}"
    _install_kubectl "${arch}"

    # So a version question is answered by the log, not by a guess about the runner.
    _info "docker       $(docker version --format '{{.Server.Version}}')"
    _info "buildx       $(docker buildx version | awk '{print $2}')"
    _info "kind         $(kind version -q)"
    _info "kubectl      $(kubectl version --client -o json | jq -r .clientVersion.gitVersion)"
    _info "architecture ${arch}"
}

# Native, no QEMU: the Dockerfile cross-compiles from BUILDPLATFORM and each
# runner builds for its own processor. The tarball is what the publish job
# ships, so the registry gets the bytes that were tested, not a rebuild.
do_build_image() {
    _info "Stage: build"
    _require_cmd docker
    local ref arch archive
    ref="$(_ci_image_ref)"
    arch="$(_ci_arch)"
    archive="$(_ci_image_archive)"

    mkdir -p "${CI_ARTIFACT_DIR}"

    _info "building ${ref} for linux/${arch}"
    # Attestations off: they wrap even a single-platform build in an index that
    # survives save and load only on a daemon with the containerd image store,
    # so the archive would be shaped differently depending on the runner.
    docker build \
        --platform "linux/${arch}" \
        --provenance=false \
        --sbom=false \
        --build-arg VERSION="$(_ci_image_version)" \
        --build-arg REVISION="$(_ci_commit_sha)" \
        --tag "${ref}" \
        "${ROOT_DIR}" || _error "image build failed"

    docker save --output "${archive}" "${ref}"
    _info "saved $(du -h "${archive}" | cut -f1) to ${archive}"

    _summary "- Built \`${ref}\` for \`linux/${arch}\`"
}

do_print_version() {
    _ci_image_version
}

# The same scripts a developer runs locally, against the image this run built.
do_k8s_e2e() {
    _info "Stage: Kubernetes end-to-end"
    _require_cmd docker kind kubectl
    local ref
    ref="$(_ci_image_ref)"

    "${ROOT_DIR}/scripts/cluster-up.sh"
    _verify_cluster_version

    _info "side-loading ${ref} into kind"
    kind load docker-image "${ref}" --name "${CLUSTER_NAME}"

    # IMAGE_OVERRIDE names the image under test. The tag in k8s/deployment.yaml
    # is an already published release, so without this a run that failed to
    # side-load would pull that one and pass for code it never ran.
    IMAGE_OVERRIDE="${ref}" ASSERT_REGISTRY_PULL=0 "${ROOT_DIR}/scripts/smoke-test.sh"
    "${ROOT_DIR}/scripts/verify-zdd.sh"

    _summary "- Kubernetes end-to-end passed on \`linux/$(_ci_arch)\`"
}

# A pinned node image and a running cluster are different claims, and
# verify-zdd.sh needs a kubelet new enough for lifecycle.preStop.sleep.
_verify_cluster_version() {
    local server
    server="$(kubectl version -o json | jq -r .serverVersion.gitVersion)"
    if [ "${server}" != "${KUBECTL_VERSION}" ]; then
        _error "cluster is running ${server}, expected ${KUBECTL_VERSION} from kind/cluster.yaml"
    fi
    _info "cluster is running ${server}"
}

# Best-effort: the cluster may not exist, which is itself part of the answer.
do_diagnostics() {
    _info "Stage: diagnostics"
    command -v kubectl >/dev/null 2>&1 || { _info "kubectl unavailable"; return 0; }

    kubectl get all,ingress,netpol -A || true
    kubectl describe pods -l app.kubernetes.io/name=ping-pong || true
    kubectl get events --sort-by=.lastTimestamp | tail -40 || true
    kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --tail=80 || true
    kubectl -n calico-system get pods || true
    docker images || true
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

_usage() {
    echo "usage: ${SCRIPT_NAME} <job>"
    echo
    echo "jobs:"
    local job
    for job in ${SUPPORTED_CI_JOBS}; do
        echo "  ${job}"
    done
}

_main() {
    local requested="${1:-}" job

    case "${requested}" in
        -h | --help)
            _usage
            return 0
            ;;
        "")
            _usage >&2
            _error "no job given"
            ;;
    esac

    for job in ${SUPPORTED_CI_JOBS}; do
        if [ "${job}" = "${requested}" ]; then
            shift
            "${requested}" "$@"
            return
        fi
    done

    _usage >&2
    _error "unknown job: ${requested}"
}

_main "$@"
