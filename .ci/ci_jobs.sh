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

# Markdown and the JSON the stages produce are rendered by .ci/report.py.
_report() {
    python3 "${ROOT_DIR}/.ci/report.py" "$1" "out=${CI_REPORT_DIR}" "${@:2}"
}

SUPPORTED_CI_JOBS="do_static_checks do_setup_tools do_build_image do_scan_image"
SUPPORTED_CI_JOBS="${SUPPORTED_CI_JOBS} do_k8s_e2e do_publish_image do_verify_published"
SUPPORTED_CI_JOBS="${SUPPORTED_CI_JOBS} do_print_version do_diagnostics"

# Pinned tools go here rather than /usr/local/bin, so no job needs sudo.
CI_BIN_DIR="${ROOT_DIR}/.ci/bin"
PATH="${CI_BIN_DIR}:${PATH}"
export PATH

CI_ARTIFACT_DIR="${CI_ARTIFACT_DIR:-${ROOT_DIR}/.ci-artifacts}"
CI_REPORT_DIR="${CI_REPORT_DIR:-${CI_ARTIFACT_DIR}/reports}"
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

# Banner and timing per stage, so a slow job can be read off the log without
# opening the Actions timing view.
_stage_begin() {
    CI_STAGE="$*"
    CI_STAGE_STARTED="$(date +%s)"
    echo
    printf '=== %s %s\n' "${CI_STAGE}" \
        "$(printf '%*s' $((66 - ${#CI_STAGE})) '' | tr ' ' '=')"
}

_stage_end() {
    _info "${CI_STAGE}: done in $(($(date +%s) - CI_STAGE_STARTED))s"
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

_ci_scan_report() {
    echo "${CI_ARTIFACT_DIR}/trivy-$(_ci_arch).json"
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

    _info "  GET ${url}"
    curl --fail --silent --show-error --location \
        --retry 3 --retry-connrefused --retry-delay 5 \
        -o "${dest}" "${url}" || _error "could not download ${url}"
    _info "  $(wc -c < "${dest}" | tr -d ' ') bytes"
}

_fetch_verified() {
    local url="$1" expected="$2" dest="$3" actual

    _fetch "${url}" "${dest}"

    actual="$(sha256sum "${dest}" | cut -d' ' -f1)"
    if [ "${actual}" != "${expected}" ]; then
        rm -f "${dest}"
        _error "checksum mismatch for ${url}: expected ${expected}, got ${actual}"
    fi
    _info "  sha256 ${actual} matches the pin"
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

_install_trivy() {
    local arch="$1" current="" archive tmp installed

    if command -v trivy >/dev/null 2>&1; then
        current="$(trivy --version 2>/dev/null | awk 'NR==1 {print $2}' || true)"
    fi

    if _tool_is_pinned "${current}" "${TRIVY_VERSION}"; then
        _info "trivy ${TRIVY_VERSION} already present"
        return 0
    fi

    _require_pinned_or_local trivy "${TRIVY_VERSION}" && return 0

    _info "installing trivy ${TRIVY_VERSION} (found '${current:-none}')"
    archive="$(_consts_lookup "TRIVY_ARCHIVE_${arch}")"
    tmp="$(mktemp -d)"
    _fetch \
        "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_${archive}.tar.gz" \
        "${tmp}/trivy.tar.gz"
    tar -xzf "${tmp}/trivy.tar.gz" -C "${tmp}" trivy
    mv "${tmp}/trivy" "${CI_BIN_DIR}/trivy"
    chmod +x "${CI_BIN_DIR}/trivy"
    rm -rf "${tmp}"

    installed="$(trivy --version | awk 'NR==1 {print $2}')"
    _tool_is_pinned "${installed}" "${TRIVY_VERSION}" \
        || _error "installed trivy reports ${installed}, expected ${TRIVY_VERSION}"
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

_registry_login() {
    [ -n "${CI_REGISTRY_TOKEN:-}" ] || _error "CI_REGISTRY_TOKEN is not set"
    [ -n "${CI_REGISTRY_USER:-}" ] || _error "CI_REGISTRY_USER is not set"
    printf '%s' "${CI_REGISTRY_TOKEN}" \
        | docker login "${REGISTRY}" --username "${CI_REGISTRY_USER}" --password-stdin
}

# ---------------------------------------------------------------------------
# Jobs
# ---------------------------------------------------------------------------

do_static_checks() {
    _stage_begin "Static checks"
    mkdir -p "${CI_BIN_DIR}" "${CI_REPORT_DIR}"
    _require_cmd curl sha256sum tar shellcheck python3
    _install_actionlint "$(_ci_arch)"

    local scripts=() pyfiles=() script
    while IFS= read -r script; do
        scripts+=("${script}")
    done < <(find "${ROOT_DIR}/scripts" "${ROOT_DIR}/.ci" -name '*.sh' -type f | sort)
    while IFS= read -r script; do
        pyfiles+=("${script}")
    done < <(find "${ROOT_DIR}/.ci" -name '*.py' -type f | sort)
    _info "checking ${#scripts[@]} shell script(s), ${#pyfiles[@]} python file(s) and $(find "${ROOT_DIR}/.github/workflows" -name '*.yml' | wc -l | tr -d ' ') workflow(s)"

    local syntax=0
    for script in "${scripts[@]}"; do
        if bash -n "${script}" 2>&1; then
            _info "  [V] bash -n ${script#"${ROOT_DIR}"/}"
        else
            _info "  [X] bash -n ${script#"${ROOT_DIR}"/}"
            syntax=$((syntax + 1))
        fi
    done

    # The same check for the reporter, which is the one thing here that is not
    # shell and would otherwise only be exercised at the end of a long job.
    # ast.parse rather than py_compile, which would leave __pycache__ behind.
    for script in "${pyfiles[@]}"; do
        if python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])' "${script}"; then
            _info "  [V] python syntax ${script#"${ROOT_DIR}"/}"
        else
            _info "  [X] python syntax ${script#"${ROOT_DIR}"/}"
            syntax=$((syntax + 1))
        fi
    done

    # Warnings and errors only: a gate that fires on style notices gets muted,
    # and then nobody reads the warnings either.
    # SC1091: consts.sh is sourced through a path shellcheck cannot follow.
    shellcheck --severity=warning --external-sources --exclude=SC1091 \
        --format=json "${scripts[@]}" > "${CI_REPORT_DIR}/shellcheck.json" || true
    actionlint -format '{{json .}}' > "${CI_REPORT_DIR}/actionlint.json" || true

    local sc_count al_count
    read -r sc_count al_count < <(_report static \
        "files=$(( ${#scripts[@]} + ${#pyfiles[@]} ))" \
        "syntax=${syntax}" \
        "shellcheck=${CI_REPORT_DIR}/shellcheck.json" \
        "actionlint=${CI_REPORT_DIR}/actionlint.json" \
        "shellcheck_version=$(shellcheck --version | awk '/version:/ {print $2}')" \
        "actionlint_version=${ACTIONLINT_VERSION}")

    [ "${syntax}" -eq 0 ] || _error "${syntax} file(s) failed the syntax check"
    [ "${sc_count}" -eq 0 ] || _error "shellcheck reported ${sc_count} finding(s) at warning or above"
    [ "${al_count}" -eq 0 ] || _error "actionlint reported ${al_count} finding(s)"

    _info "static checks passed"
    _stage_end
}

# Takes the tools to install, or installs all of them. Named, because the scan
# and cluster jobs run in parallel and each needs a different half.
do_setup_tools() {
    local arch tool tools
    arch="$(_ci_arch)"
    tools="${*:-kind kubectl trivy}"

    _info "Stage: tool setup for linux/${arch}: ${tools}"
    mkdir -p "${CI_BIN_DIR}"
    _require_cmd curl sha256sum tar jq

    for tool in ${tools}; do
        case "${tool}" in
            kind | kubectl | trivy | actionlint) "_install_${tool}" "${arch}" ;;
            *) _error "unknown tool: ${tool}" ;;
        esac
    done
}

# Native, no QEMU: the Dockerfile cross-compiles from BUILDPLATFORM and each
# runner builds for its own processor. The tarball is what the publish job
# ships, so the registry gets the bytes that were tested, not a rebuild.
do_build_image() {
    _stage_begin "Build linux/$(_ci_arch)"
    _require_cmd docker
    local ref arch archive
    ref="$(_ci_image_ref)"
    arch="$(_ci_arch)"
    archive="$(_ci_image_archive)"

    mkdir -p "${CI_ARTIFACT_DIR}"

    _info "docker $(docker version --format '{{.Server.Version}}'), buildx $(docker buildx version | awk '{print $2}')"
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

    _info "image    ${ref}"
    _info "digest   $(docker image inspect "${ref}" --format '{{.Id}}')"
    _info "revision $(_ci_commit_sha)"
    _info "size     $(docker image inspect "${ref}" --format '{{.Size}}') bytes uncompressed"
    _info "archive  ${archive} ($(wc -c < "${archive}" | tr -d ' ') bytes)"
    _stage_end
}

do_print_version() {
    _ci_image_version
}

# Scans the archive, so what is judged is what was built. Entries in
# .trivyignore.yaml are reported and allowed through until they expire;
# anything else at HIGH or CRITICAL fails here, before the publish job (#10).
do_scan_image() {
    _stage_begin "Scan linux/$(_ci_arch)"
    _require_cmd trivy python3
    local archive report blocking suppressed arch
    arch="$(_ci_arch)"
    archive="$(_ci_image_archive)"
    report="$(_ci_scan_report)"

    [ -f "${archive}" ] || _error "no image archive at ${archive}; run do_build_image first"
    mkdir -p "${CI_ARTIFACT_DIR}" "${CI_REPORT_DIR}"

    _info "trivy $(trivy --version | awk 'NR==1 {print $2}'), severity ${SCAN_SEVERITY}"
    _info "target ${archive} ($(wc -c < "${archive}" | tr -d ' ') bytes)"
    _info "accepted risks from $(grep -c '^  - id:' "${ROOT_DIR}/.trivyignore.yaml") entr(y|ies) in .trivyignore.yaml"

    # --exit-code 0 because the policy below needs the report to exist to apply
    # it; trivy still exits non-zero if the scan or database itself failed, and
    # that is deliberately not swallowed.
    # No --ignore-unfixed: it reads as noise reduction and behaves as a blanket
    # exemption for every unfixed finding, including ones nobody has read.
    trivy image \
        --input "${archive}" \
        --scanners vuln \
        --severity "${SCAN_SEVERITY}" \
        --ignorefile "${ROOT_DIR}/.trivyignore.yaml" \
        --show-suppressed \
        --format json \
        --output "${report}" \
        --exit-code 0 \
        --quiet || _error "trivy failed to scan ${archive}"

    # The same findings in the two formats anyone downstream would ask for: a
    # table to read and SARIF for whatever consumes scanner output.
    trivy convert --quiet --format table --show-suppressed \
        --output "${CI_REPORT_DIR}/trivy-${arch}.txt" "${report}"
    trivy convert --quiet --format sarif \
        --output "${CI_REPORT_DIR}/trivy-${arch}.sarif" "${report}"
    cp "${report}" "${CI_REPORT_DIR}/trivy-${arch}.json"

    read -r blocking suppressed < <(_report scan \
        "arch=${arch}" \
        "json=${report}" \
        "image=$(_ci_image_version)" \
        "trivy_version=$(trivy --version | awk 'NR==1 {print $2}')" \
        "severity=${SCAN_SEVERITY}" \
        "expiry=${SCAN_EXCEPTION_EXPIRY}")

    if [ "${suppressed}" -gt 0 ]; then
        _warn "${suppressed} accepted ${SCAN_SEVERITY} finding(s) in $(_ci_image_version); see docs/security-risk-acceptance.md"
    fi

    if [ "${blocking}" -gt 0 ]; then
        _error "${blocking} unapproved ${SCAN_SEVERITY} finding(s). Fix them, or record an expiring exception in .trivyignore.yaml with the reasoning in docs/security-risk-acceptance.md"
    fi

    _info "no unapproved ${SCAN_SEVERITY} findings (${suppressed} accepted)"
    _stage_end
}

# The same scripts a developer runs locally, against the image this run built.
do_k8s_e2e() {
    _stage_begin "Kubernetes end-to-end linux/$(_ci_arch)"
    _require_cmd docker kind kubectl
    local ref archive
    ref="$(_ci_image_ref)"
    archive="$(_ci_image_archive)"

    [ -f "${archive}" ] || _error "no image archive at ${archive}; run do_build_image first"

    "${ROOT_DIR}/scripts/cluster-up.sh"
    _verify_cluster_version

    # From the archive rather than the local image store, because this runs in
    # parallel with the scan and neither job is the one that built the image.
    # The tag travels inside the tarball.
    _info "side-loading ${ref} into kind"
    kind load image-archive "${archive}" --name "${CLUSTER_NAME}"

    _preload_probe_image

    # Both scripts record every result to a file as well as printing it, and
    # both run even if the first fails: two reports are more use than one plus
    # an early exit.
    local arch smoke zdd smoke_rc=0 zdd_rc=0
    arch="$(_ci_arch)"
    smoke="${CI_REPORT_DIR}/e2e-${arch}-smoke.tsv"
    zdd="${CI_REPORT_DIR}/e2e-${arch}-zdd.tsv"
    mkdir -p "${CI_REPORT_DIR}"
    : > "${smoke}"
    : > "${zdd}"

    # IMAGE_OVERRIDE names the image under test. The tag in k8s/deployment.yaml
    # is an already published release, so without this a run that failed to
    # side-load would pull that one and pass for code it never ran.
    CHECK_REPORT="${smoke}" IMAGE_OVERRIDE="${ref}" ASSERT_REGISTRY_PULL=0 \
        "${ROOT_DIR}/scripts/smoke-test.sh" || smoke_rc=$?
    CHECK_REPORT="${zdd}" "${ROOT_DIR}/scripts/verify-zdd.sh" || zdd_rc=$?

    _report e2e \
        "arch=${arch}" \
        "image=$(_ci_image_version)" \
        "kubernetes=${KUBECTL_VERSION}" \
        "kind=${KIND_VERSION}" \
        "smoke=${smoke}" "smoke_rc=${smoke_rc}" \
        "zdd=${zdd}" "zdd_rc=${zdd_rc}"

    [ "${smoke_rc}" -eq 0 ] && [ "${zdd_rc}" -eq 0 ] \
        || _error "the Kubernetes suite failed on linux/${arch}"
    _stage_end
}

# smoke-test.sh and verify-zdd.sh each run a curl pod, so the node would pull
# the same Docker Hub image twice, and an anonymous pull is rate limited by IP.
# Fetching it once here turns a 429 into one warning instead of two pods stuck
# in ImagePullBackOff. Best effort: on failure the node pulls it as before.
_preload_probe_image() {
    local image="${PROBE_IMAGE:-curlimages/curl:8.11.1}"

    if docker image inspect "${image}" >/dev/null 2>&1 \
        || docker pull --quiet "${image}" >/dev/null 2>&1; then
        if kind load docker-image "${image}" --name "${CLUSTER_NAME}" >/dev/null 2>&1; then
            _info "preloaded ${image}"
            return 0
        fi
    fi

    _warn "could not preload ${image}; the cluster will pull it itself"
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

# Reached only from a push to the default branch, so a pull request never holds
# credentials for this.
do_publish_image() {
    _stage_begin "Publish"
    _require_cmd docker jq
    local ref published_revision arch archive
    ref="$(_ci_image_ref)"

    _registry_login

    if published_revision="$(_published_revision_of "${ref}")"; then
        if [ "${published_revision}" = "$(_ci_commit_sha)" ]; then
            _warn "${ref} is already published for this commit; leaving it alone"
            _report publish "ref=${ref}" \
                "digest=$(docker buildx imagetools inspect "${ref}" --format '{{.Manifest.Digest}}')" \
                "revision=${published_revision}"
            _stage_end
            return 0
        fi
        _error "${ref} exists and was built from ${published_revision}, not $(_ci_commit_sha): the short SHA collided, so bump VERSION rather than repointing a published tag"
    fi

    local arch_refs=()
    for arch in amd64 arm64; do
        archive="${CI_ARTIFACT_DIR}/image-${arch}.tar"
        [ -f "${archive}" ] || _error "no tested archive for ${arch} at ${archive}"

        # Tag immediately after each load: both archives carry the same tag, so
        # loading the second one repoints it.
        _info "loading and pushing the tested ${arch} image"
        docker load --input "${archive}" >/dev/null
        docker tag "${ref}" "${ref}-${arch}"
        docker push --quiet "${ref}-${arch}"
        arch_refs+=("${ref}-${arch}")
    done

    _info "assembling the multi-architecture manifest for ${ref}"
    docker buildx imagetools create --tag "${ref}" "${arch_refs[@]}"

    _report publish "ref=${ref}" \
        "digest=$(docker buildx imagetools inspect "${ref}" --format '{{.Manifest.Digest}}')" \
        "revision=$(_ci_commit_sha)"

    _info "published ${ref}"
    _stage_end
}

# Echoes the revision of an already-published tag, or fails if there is none.
# Read off a pulled image, because the label lives in the config blob rather
# than the index.
_published_revision_of() {
    local ref="$1"
    docker buildx imagetools inspect "${ref}" >/dev/null 2>&1 || return 1
    docker pull --quiet --platform linux/amd64 "${ref}" >/dev/null 2>&1 || return 1
    docker image inspect "${ref}" \
        --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}'
}

# Everything above ran against local images. This is the only step that asks
# the registry, and the only evidence that the published tag resolves.
do_verify_published() {
    _stage_begin "Verify published image"
    _require_cmd docker jq
    local ref platforms revision want arch failures=0
    ref="$(_ci_image_ref)"

    if [ -n "${CI_REGISTRY_TOKEN:-}" ]; then
        _registry_login
    fi

    docker buildx imagetools inspect "${ref}"

    platforms="$(docker buildx imagetools inspect "${ref}" --raw \
        | jq -r '[.manifests[]
            | select(.platform.os != "unknown")
            | "\(.platform.os)/\(.platform.architecture)"] | sort | join(" ")')"

    for want in linux/amd64 linux/arm64; do
        case " ${platforms} " in
            *" ${want} "*) _info "${want} present" ;;
            *)
                echo "  missing ${want} in ${ref} (found: ${platforms})" >&2
                failures=$((failures + 1))
                ;;
        esac
    done

    # An index entry is a promise; a pull is evidence.
    for arch in amd64 arm64; do
        docker rmi "${ref}" >/dev/null 2>&1 || true
        if ! docker pull --quiet --platform "linux/${arch}" "${ref}" >/dev/null; then
            echo "  could not pull ${ref} for linux/${arch}" >&2
            failures=$((failures + 1))
            continue
        fi
        revision="$(docker image inspect "${ref}" \
            --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}')"
        if [ "${revision}" != "$(_ci_commit_sha)" ]; then
            echo "  linux/${arch} reports revision ${revision}, expected $(_ci_commit_sha)" >&2
            failures=$((failures + 1))
        else
            _info "pulled linux/${arch}, revision matches"
        fi
    done

    _report verify "ref=${ref}" "revision=$(_ci_commit_sha)" "failures=${failures}"

    [ "${failures}" -eq 0 ] || _error "${failures} check(s) failed for ${ref}"

    _info "${ref} verified"
    _stage_end
}

# Best-effort: the cluster may not exist, which is itself part of the answer.
do_diagnostics() {
    _stage_begin "Diagnostics"
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
