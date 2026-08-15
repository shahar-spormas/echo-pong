#!/usr/bin/env bash
# Every step the CI pipeline runs, as a function you can also run by hand.
#
# .github/workflows/ci.yml owns *when* things run and what they are allowed to
# touch; this file owns *what* they do. Logic that lives in YAML can only ever
# be tested by pushing a commit, so nothing here needs the Actions runtime:
# each job takes its input from CI_* environment variables that default to
# something sensible on a laptop.
#
#   ./.ci/ci_jobs.sh do_build_image
#   ./.ci/ci_jobs.sh do_k8s_e2e
#
# Bash, not sh: the scripts under scripts/ that these jobs call are bash, and
# rewriting them for dash would buy nothing but the rewrite.

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=.ci/consts.sh
. "${ROOT_DIR}/.ci/consts.sh"

SUPPORTED_CI_JOBS="do_static_checks do_setup_tools do_build_image do_k8s_e2e"
SUPPORTED_CI_JOBS="${SUPPORTED_CI_JOBS} do_diagnostics"

# Pinned tools land here rather than /usr/local/bin, so a job never needs sudo
# and the directory is the first thing on PATH for every later step.
CI_BIN_DIR="${ROOT_DIR}/.ci/bin"
PATH="${CI_BIN_DIR}:${PATH}"
export PATH

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

error() {
    echo "${SCRIPT_NAME}: $*" >&2
    exit 1
}

info() {
    echo "==> $*"
}

# Surfaces as an annotation on the run when there is a run, and as a plain line
# when there is not.
warn() {
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        echo "::warning::$*"
    else
        echo "WARNING: $*" >&2
    fi
}

summary() {
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        printf '%s\n' "$*" >> "${GITHUB_STEP_SUMMARY}"
    fi
}

require_cmd() {
    local cmd
    for cmd in "$@"; do
        command -v "${cmd}" >/dev/null 2>&1 || error "${cmd} is not on PATH"
    done
}

# GOARCH, whatever the caller or the kernel calls it.
ci_arch() {
    case "${CI_ARCH:-$(uname -m)}" in
        x86_64 | amd64) echo amd64 ;;
        aarch64 | arm64) echo arm64 ;;
        *) error "unsupported architecture: ${CI_ARCH:-$(uname -m)}" ;;
    esac
}

# The image reference is read out of the Deployment so this pipeline cannot
# disagree with what actually gets deployed.
ci_image_ref() {
    local ref
    ref="$(awk '/^[[:space:]]+image:[[:space:]]/ {print $2; exit}' \
        "${ROOT_DIR}/k8s/deployment.yaml")"
    [ -n "${ref}" ] || error "no image: field found in k8s/deployment.yaml"
    echo "${ref}"
}

# Only Linux binaries are pinned, because that is the only thing CI runs on.
# Pinning macOS builds as well would double the checksum table to serve a
# platform the pipeline never uses, so a laptop is expected to bring its own
# tools and is told so rather than handed a Linux binary.
require_pinned_or_local() {
    local tool="$1" wanted="$2"

    [ "$(uname -s)" = "Linux" ] && return 1

    command -v "${tool}" >/dev/null 2>&1 \
        || error "${tool} is not installed; this host is not Linux, so ${SCRIPT_NAME} cannot install the pinned ${wanted} for you"
    warn "using the ${tool} already on PATH; only Linux builds are version-pinned, so this may not be ${wanted}"
    return 0
}

# Downloads a file and refuses to hand it over unless it hashes to what
# .ci/consts.sh says it should. An unpinned tool is an unpinned pipeline.
fetch_verified() {
    local url="$1" expected="$2" dest="$3" actual

    curl --fail --silent --show-error --location \
        --retry 3 --retry-connrefused --retry-delay 5 \
        -o "${dest}" "${url}" || error "could not download ${url}"

    actual="$(sha256sum "${dest}" | cut -d' ' -f1)"
    if [ "${actual}" != "${expected}" ]; then
        rm -f "${dest}"
        error "checksum mismatch for ${url}: expected ${expected}, got ${actual}"
    fi
}

# Reads KIND_SHA256_amd64 and friends without an associative array, so the
# constants file stays a flat list that is easy to re-generate.
consts_lookup() {
    local name="$1"
    eval "printf '%s' \"\${${name}:-}\""
}

# True when the tool already on PATH is exactly the pinned version. The runner
# image ships kind and kubectl and bumps them on GitHub's schedule, so this is
# a fast path, never a source of truth.
tool_is_pinned() {
    local actual="$1" wanted="$2"
    [ -n "${actual}" ] && [ "${actual}" = "${wanted}" ]
}

install_kind() {
    local arch="$1" current=""

    if command -v kind >/dev/null 2>&1; then
        current="v$(kind version -q 2>/dev/null || true)"
    fi

    if tool_is_pinned "${current}" "${KIND_VERSION}"; then
        info "kind ${KIND_VERSION} already present"
        return 0
    fi

    require_pinned_or_local kind "${KIND_VERSION}" && return 0

    info "installing kind ${KIND_VERSION} (found '${current:-none}')"
    fetch_verified \
        "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-${arch}" \
        "$(consts_lookup "KIND_SHA256_${arch}")" \
        "${CI_BIN_DIR}/kind"
    chmod +x "${CI_BIN_DIR}/kind"
}

install_kubectl() {
    local arch="$1" current=""

    if command -v kubectl >/dev/null 2>&1; then
        current="$(kubectl version --client -o json 2>/dev/null \
            | jq -r '.clientVersion.gitVersion // empty' || true)"
    fi

    if tool_is_pinned "${current}" "${KUBECTL_VERSION}"; then
        info "kubectl ${KUBECTL_VERSION} already present"
        return 0
    fi

    require_pinned_or_local kubectl "${KUBECTL_VERSION}" && return 0

    info "installing kubectl ${KUBECTL_VERSION} (found '${current:-none}')"
    fetch_verified \
        "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${arch}/kubectl" \
        "$(consts_lookup "KUBECTL_SHA256_${arch}")" \
        "${CI_BIN_DIR}/kubectl"
    chmod +x "${CI_BIN_DIR}/kubectl"
}

install_actionlint() {
    local arch="$1" tmp

    if command -v actionlint >/dev/null 2>&1 \
        && tool_is_pinned "$(actionlint -version 2>/dev/null | head -1)" "${ACTIONLINT_VERSION}"; then
        info "actionlint ${ACTIONLINT_VERSION} already present"
        return 0
    fi

    require_pinned_or_local actionlint "${ACTIONLINT_VERSION}" && return 0

    info "installing actionlint ${ACTIONLINT_VERSION}"
    tmp="$(mktemp -d)"
    fetch_verified \
        "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_${arch}.tar.gz" \
        "$(consts_lookup "ACTIONLINT_SHA256_${arch}")" \
        "${tmp}/actionlint.tar.gz"
    tar -xzf "${tmp}/actionlint.tar.gz" -C "${tmp}" actionlint
    mv "${tmp}/actionlint" "${CI_BIN_DIR}/actionlint"
    chmod +x "${CI_BIN_DIR}/actionlint"
    rm -rf "${tmp}"
}

# ---------------------------------------------------------------------------
# Jobs
# ---------------------------------------------------------------------------

# Everything that can be judged without building anything. Cheap, so it runs
# first and gates the matrix.
do_static_checks() {
    info "Stage: static checks"
    mkdir -p "${CI_BIN_DIR}"
    require_cmd curl sha256sum tar shellcheck
    install_actionlint "$(ci_arch)"

    check_action_pins
    actionlint

    local failures=0 script
    while IFS= read -r script; do
        bash -n "${script}" || failures=$((failures + 1))
    done < <(find "${ROOT_DIR}/scripts" "${ROOT_DIR}/.ci" -name '*.sh' -type f | sort)
    [ "${failures}" -eq 0 ] || error "${failures} script(s) failed the syntax check"

    # Warnings and errors fail; style and info notices are left as advice.
    # A gate that fires on "consider using ${var//x/y}" gets switched off, and
    # then the warnings stop being read either.
    #
    # SC1091: consts.sh is sourced through a computed path shellcheck cannot follow.
    shellcheck --severity=warning --external-sources --exclude=SC1091 \
        "${ROOT_DIR}"/scripts/*.sh "${ROOT_DIR}"/.ci/*.sh

    info "static checks passed"
}

# A tag can be repointed at new code by anyone who controls the action's
# repository, so an unpinned `uses:` is someone else's write access to this
# pipeline. Enforced here rather than trusted to review.
check_action_pins() {
    local unpinned=0 line ref

    while IFS= read -r line; do
        # Local actions (./path) have no ref and are this repository's own code.
        case "${line}" in
            *"uses: ./"*) continue ;;
        esac
        ref="${line##*@}"
        if ! printf '%s' "${ref}" | grep -qE '^[0-9a-f]{40}$'; then
            echo "  not pinned to a full commit SHA: ${line}" >&2
            unpinned=$((unpinned + 1))
        fi
    # sed, not tr: tr squeezes newlines too, which would fold every match into
    # one line whose last @ref is a valid SHA, and the check would pass forever.
    done < <(grep -hoE 'uses:[[:space:]]*[^[:space:]]+' \
        "${ROOT_DIR}"/.github/workflows/*.yml | sed 's/[[:space:]][[:space:]]*/ /g')

    [ "${unpinned}" -eq 0 ] || error "${unpinned} action reference(s) are not pinned"
    info "all action references are pinned to a full commit SHA"
}

# Installs the pinned Kubernetes tooling for this architecture.
do_setup_tools() {
    info "Stage: tool setup"
    local arch
    arch="$(ci_arch)"

    mkdir -p "${CI_BIN_DIR}"
    require_cmd curl sha256sum tar jq docker

    install_kind "${arch}"
    install_kubectl "${arch}"

    # Print what the rest of the pipeline will actually use, so a version
    # question is answered by the log rather than by a guess about the runner.
    info "docker       $(docker version --format '{{.Server.Version}}')"
    info "buildx       $(docker buildx version | awk '{print $2}')"
    info "kind         $(kind version -q)"
    info "kubectl      $(kubectl version --client -o json | jq -r .clientVersion.gitVersion)"
    info "architecture ${arch}"
}

# Builds this architecture natively. The Dockerfile already cross-compiles from
# BUILDPLATFORM, so this needs no QEMU: each runner builds for the processor it
# is running on.
do_build_image() {
    info "Stage: build"
    require_cmd docker git
    local ref arch
    ref="$(ci_image_ref)"
    arch="$(ci_arch)"

    info "building ${ref} for linux/${arch}"
    docker build \
        --platform "linux/${arch}" \
        --build-arg VERSION="${ref##*:}" \
        --build-arg REVISION="$(git -C "${ROOT_DIR}" rev-parse --short HEAD)" \
        --tag "${ref}" \
        "${ROOT_DIR}" || error "image build failed"

    summary "- Built \`${ref}\` for \`linux/${arch}\`"
}

# The same scripts a developer runs locally, against the image this run built.
# Nothing is asserted here that ./scripts cannot assert on a laptop.
do_k8s_e2e() {
    info "Stage: Kubernetes end-to-end"
    require_cmd docker kind kubectl
    local ref
    ref="$(ci_image_ref)"

    "${ROOT_DIR}/scripts/cluster-up.sh"
    verify_cluster_version

    # imagePullPolicy is IfNotPresent, so a side-loaded image is found on the
    # node and never fetched. That is why the registry-pull assertion stays off
    # here: the commit under test has no published image yet.
    info "side-loading ${ref} into kind"
    kind load docker-image "${ref}" --name "${CLUSTER_NAME}"

    ASSERT_REGISTRY_PULL=0 "${ROOT_DIR}/scripts/smoke-test.sh"
    "${ROOT_DIR}/scripts/verify-zdd.sh"

    summary "- Kubernetes end-to-end passed on \`linux/$(ci_arch)\`"
}

# kind/cluster.yaml pins the node image by digest, but a pinned manifest and a
# running cluster are different claims, and scripts/verify-zdd.sh depends on a
# kubelet new enough for lifecycle.preStop.sleep.
verify_cluster_version() {
    local server
    server="$(kubectl version -o json | jq -r .serverVersion.gitVersion)"
    if [ "${server}" != "${KUBECTL_VERSION}" ]; then
        error "cluster is running ${server}, expected ${KUBECTL_VERSION} from kind/cluster.yaml"
    fi
    info "cluster is running ${server}"
}

# Best-effort context for a failed run. Every command is allowed to fail: the
# cluster may not exist, which is itself part of the answer.
do_diagnostics() {
    info "Stage: diagnostics"
    command -v kubectl >/dev/null 2>&1 || { info "kubectl unavailable"; return 0; }

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

usage() {
    echo "usage: ${SCRIPT_NAME} <job>"
    echo
    echo "jobs:"
    local job
    for job in ${SUPPORTED_CI_JOBS}; do
        echo "  ${job}"
    done
}

main() {
    local requested="${1:-}" job

    case "${requested}" in
        -h | --help)
            usage
            return 0
            ;;
        "")
            usage >&2
            error "no job given"
            ;;
    esac

    for job in ${SUPPORTED_CI_JOBS}; do
        if [ "${job}" = "${requested}" ]; then
            shift
            "${requested}" "$@"
            return
        fi
    done

    usage >&2
    error "unknown job: ${requested}"
}

main "$@"
