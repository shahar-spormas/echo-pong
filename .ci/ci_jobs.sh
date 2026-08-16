#!/usr/bin/env bash
# Every step ci.yml runs. The workflow decides when; this decides what.
# Needs no Actions runtime, so any job runs by hand:
#
#   ./.ci/ci_jobs.sh do_build_image

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=.ci/consts.sh
. "${ROOT_DIR}/.ci/consts.sh"

# Proxies .ci/report.py, so it is named like a command, not a helper.
report() {
    python3 "${ROOT_DIR}/.ci/report.py" "$1" "out=${CI_REPORT_DIR}" "${@:2}"
}

# actionlint's problem matcher turns its output into line annotations.
_matcher() {
    [ -n "${GITHUB_ACTIONS:-}" ] || return 0
    case "$1" in
        add) echo "::add-matcher::${ROOT_DIR}/.github/actionlint-matcher.json" ;;
        remove) echo "::remove-matcher owner=actionlint::" ;;
    esac
}

# Not /usr/local/bin, so no job needs sudo.
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

# Timing per stage, readable straight off the log.
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

_ci_short_sha() {
    local sha
    sha="$(_ci_commit_sha)"
    echo "${sha:0:7}"
}

# v0.1.0-1a2b3c4. Release tags are #8.
_ci_image_version() {
    local base
    [ -f "${ROOT_DIR}/VERSION" ] || _error "no VERSION file at ${ROOT_DIR}/VERSION"
    base="$(tr -d '[:space:]' < "${ROOT_DIR}/VERSION")"
    [ -n "${base}" ] || _error "VERSION is empty"

    # A release tag publishes itself, v1.2.3, and must agree with VERSION: the
    # file is what the tree claims to be, and a release cut from a tree that
    # disagrees is the one thing worth refusing outright.
    if [ -n "${CI_RELEASE_TAG:-}" ]; then
        [ "${CI_RELEASE_TAG}" = "v${base}" ] \
            || _error "tag ${CI_RELEASE_TAG} disagrees with VERSION (v${base}); bump the file or move the tag"
        echo "${CI_RELEASE_TAG}"
        return
    fi

    echo "v${base}-$(_ci_short_sha)"
}

_ci_image_ref() {
    echo "${CI_IMAGE_NAME}:$(_ci_image_version)"
}

_ci_image_archive() {
    echo "${CI_ARTIFACT_DIR}/image-$(_ci_arch).tar"
}

_ci_binary() {
    echo "${CI_ARTIFACT_DIR}/${BINARY_NAME}-linux-$(_ci_arch)"
}

_ci_scan_report() {
    echo "${CI_ARTIFACT_DIR}/trivy-$(_ci_arch).json"
}

# Only Linux is pinned. A laptop brings its own and is warned.
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

# Reads KIND_SHA256_amd64 and friends by name. Flat variables rather than an
# associative array, which needs bash 4; macOS ships 3.2.
_consts_lookup() {
    local name="$1"
    printf '%s' "${!name:-}"
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

# What this change touches when CI_LINT_BASE is set, everything otherwise.
# ACMR drops deletions, which no longer exist to lint.
_files_to_check() {
    local pattern="$1"
    if [ -n "${CI_LINT_BASE:-}" ]; then
        git -C "${ROOT_DIR}" diff --name-only --diff-filter=ACMR \
            "${CI_LINT_BASE}...HEAD" | grep -E "${pattern}" || true
    else
        (cd "${ROOT_DIR}" && find scripts .ci .github/workflows -type f | grep -E "${pattern}" | sort) || true
    fi
}

do_static_checks() {
    _stage_begin "Static checks"
    mkdir -p "${CI_BIN_DIR}" "${CI_REPORT_DIR}"
    _require_cmd curl sha256sum tar shellcheck python3 git
    _install_actionlint "$(_ci_arch)"
    cd "${ROOT_DIR}"

    local shell_files=() py_files=() workflows=() file
    while IFS= read -r file; do
        [ -n "${file}" ] && shell_files+=("${file}")
    done < <(_files_to_check '\.sh$')
    while IFS= read -r file; do
        [ -n "${file}" ] && py_files+=("${file}")
    done < <(_files_to_check '\.py$')
    while IFS= read -r file; do
        [ -n "${file}" ] && workflows+=("${file}")
    done < <(_files_to_check '^\.github/workflows/.*\.ya?ml$')

    if [ -n "${CI_LINT_BASE:-}" ]; then
        _info "scope: changed since ${CI_LINT_BASE:0:7}"
    else
        _info "scope: every tracked file"
    fi
    _info "${#shell_files[@]} shell, ${#py_files[@]} python, ${#workflows[@]} workflow(s)"

    local syntax=0
    for file in ${shell_files[@]+"${shell_files[@]}"}; do
        if bash -n "${file}" 2>&1; then
            _info "  [V] bash -n ${file}"
        else
            _info "  [X] bash -n ${file}"
            syntax=$((syntax + 1))
        fi
    done

    # ast.parse, not py_compile, which leaves __pycache__ behind.
    for file in ${py_files[@]+"${py_files[@]}"}; do
        if python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])' "${file}"; then
            _info "  [V] python syntax ${file}"
        else
            _info "  [X] python syntax ${file}"
            syntax=$((syntax + 1))
        fi
    done

    # Exit status is the gate; findings surface as annotations and JSON.
    # Warning and above only: a gate that fires on style notices gets muted.
    # SC1091: consts.sh is sourced through a path shellcheck cannot follow.
    local lint=0
    if [ "${#shell_files[@]}" -gt 0 ]; then
        shellcheck --severity=warning --external-sources --exclude=SC1091 \
            --format=json "${shell_files[@]}" > "${CI_REPORT_DIR}/shellcheck.json" || true
        shellcheck --severity=warning --external-sources --exclude=SC1091 \
            "${shell_files[@]}" || lint=$((lint + 1))
    fi

    if [ "${#workflows[@]}" -gt 0 ]; then
        actionlint -format '{{json .}}' "${workflows[@]}" > "${CI_REPORT_DIR}/actionlint.json" || true
        _matcher add
        actionlint "${workflows[@]}" || lint=$((lint + 1))
        _matcher remove
    fi

    [ "${syntax}" -eq 0 ] || _error "${syntax} file(s) failed the syntax check"
    [ "${lint}" -eq 0 ] || _error "${lint} linter(s) reported findings; see the annotations"

    _info "static checks passed"
    _stage_end
}

# Named tools, or all: scan and e2e run in parallel and need different halves.
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

# Native, no QEMU: the Dockerfile cross-compiles from BUILDPLATFORM. The
# tarball is what gets published, so shipped bytes are tested bytes.
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
    # Attestations off: they wrap the build in an index that survives save and
    # load only with the containerd image store, so archives differ by runner.
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

# Lifted out of the image rather than compiled again, so what a developer
# downloads is the executable that was scanned and cluster-tested, not another
# build of the same source. docker create makes no attempt to run it, which
# matters for a distroless image with no shell.
do_extract_binary() {
    _stage_begin "Extract binary linux/$(_ci_arch)"
    _require_cmd docker
    local ref binary container
    ref="$(_ci_image_ref)"
    binary="$(_ci_binary)"

    mkdir -p "${CI_ARTIFACT_DIR}"
    container="$(docker create --platform "linux/$(_ci_arch)" "${ref}")"
    docker cp "${container}:${BINARY_PATH}" "${binary}" >/dev/null
    docker rm "${container}" >/dev/null
    chmod +x "${binary}"

    _info "binary  ${binary} ($(wc -c < "${binary}" | tr -d ' ') bytes)"
    _info "sha256  $(sha256sum "${binary}" | cut -d' ' -f1)"
    _stage_end
}

# The matrix as JSON, so ci.yml holds no copy of the architecture list.
do_print_matrix() {
    local arch runner entries=""
    for arch in ${CI_ARCHES}; do
        runner="$(_consts_lookup "CI_RUNNER_${arch}")"
        # Otherwise runs-on: "", which queues forever instead of failing.
        [ -n "${runner}" ] || _error "CI_ARCHES lists ${arch} but CI_RUNNER_${arch} is unset in .ci/consts.sh"
        entries="${entries}${entries:+,}{\"arch\":\"${arch}\",\"runner\":\"${runner}\"}"
    done
    echo "{\"include\":[${entries}]}"
}

# Scans the archive, so what is judged is what was built. .trivyignore.yaml
# entries pass until they expire; anything else HIGH or CRITICAL fails (#10).
do_scan_image() {
    _stage_begin "Scan linux/$(_ci_arch)"
    _require_cmd trivy python3
    local archive scan_json blocking suppressed arch
    arch="$(_ci_arch)"
    archive="$(_ci_image_archive)"
    scan_json="$(_ci_scan_report)"

    [ -f "${archive}" ] || _error "no image archive at ${archive}; run do_build_image first"
    mkdir -p "${CI_ARTIFACT_DIR}" "${CI_REPORT_DIR}"

    _info "trivy $(trivy --version | awk 'NR==1 {print $2}'), severity ${SCAN_SEVERITY}"
    _info "target ${archive} ($(wc -c < "${archive}" | tr -d ' ') bytes)"
    _info "accepted risks from $(grep -c '^  - id:' "${ROOT_DIR}/.trivyignore.yaml") entr(y|ies) in .trivyignore.yaml"

    # --exit-code 0: the policy below is the gate and needs the report. A failed
    # scan still exits non-zero, and that is not swallowed.
    # No --ignore-unfixed: a blanket exemption for findings nobody has read.
    trivy image \
        --input "${archive}" \
        --scanners vuln \
        --severity "${SCAN_SEVERITY}" \
        --ignorefile "${ROOT_DIR}/.trivyignore.yaml" \
        --show-suppressed \
        --format json \
        --output "${scan_json}" \
        --exit-code 0 \
        --quiet || _error "trivy failed to scan ${archive}"

    # A table to read, SARIF for tooling.
    trivy convert --quiet --format table --show-suppressed \
        --output "${CI_REPORT_DIR}/trivy-${arch}.txt" "${scan_json}"
    trivy convert --quiet --format sarif \
        --output "${CI_REPORT_DIR}/trivy-${arch}.sarif" "${scan_json}"
    cp "${scan_json}" "${CI_REPORT_DIR}/trivy-${arch}.json"

    read -r blocking suppressed < <(report scan \
        "arch=${arch}" \
        "json=${scan_json}" \
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

# The scripts a developer runs locally, against the image this run built.
do_k8s_e2e() {
    _stage_begin "Kubernetes end-to-end linux/$(_ci_arch)"
    _require_cmd docker kind kubectl
    local ref archive
    ref="$(_ci_image_ref)"
    archive="$(_ci_image_archive)"

    [ -f "${archive}" ] || _error "no image archive at ${archive}; run do_build_image first"

    "${ROOT_DIR}/scripts/cluster-up.sh"
    _verify_cluster_version

    # From the archive: this job did not build the image. The tag is inside.
    _info "side-loading ${ref} into kind"
    kind load image-archive "${archive}" --name "${CLUSTER_NAME}"

    _preload_probe_image

    # Both run even if the first fails: two reports beat one and an early exit.
    local arch smoke zdd failed=0
    arch="$(_ci_arch)"
    smoke="${CI_REPORT_DIR}/e2e-${arch}-smoke.tap"
    zdd="${CI_REPORT_DIR}/e2e-${arch}-zdd.tap"
    mkdir -p "${CI_REPORT_DIR}"
    : > "${smoke}"
    : > "${zdd}"

    # IMAGE_OVERRIDE names the image under test. The manifest's own tag is a
    # published release, which a failed side-load would silently pass against.
    CHECK_REPORT="${smoke}" IMAGE_OVERRIDE="${ref}" ASSERT_REGISTRY_PULL=0 \
        "${ROOT_DIR}/scripts/smoke-test.sh" || failed=1
    CHECK_REPORT="${zdd}" "${ROOT_DIR}/scripts/verify-zdd.sh" || failed=1

    # No exit codes: the TAP plan tells the report if a stream was truncated.
    report e2e \
        "arch=${arch}" \
        "image=$(_ci_image_version)" \
        "kubernetes=${KUBECTL_VERSION}" \
        "kind=${KIND_VERSION}" \
        "smoke=${smoke}" \
        "zdd=${zdd}"

    [ "${failed}" -eq 0 ] || _error "the Kubernetes suite failed on linux/${arch}"
    _stage_end
}

# Both scripts run a curl pod, so the node would pull the same rate-limited
# Docker Hub image twice. Best effort: on failure the node pulls it itself.
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
# verify-zdd.sh needs a kubelet with lifecycle.preStop.sleep.
_verify_cluster_version() {
    local server
    server="$(kubectl version -o json | jq -r .serverVersion.gitVersion)"
    if [ "${server}" != "${KUBECTL_VERSION}" ]; then
        _error "cluster is running ${server}, expected ${KUBECTL_VERSION} from kind/cluster.yaml"
    fi
    _info "cluster is running ${server}"
}

# Only reached from a push to main, so a PR never holds these credentials.
do_publish_image() {
    _stage_begin "Publish"
    _require_cmd docker jq
    local ref published_revision arch archive
    ref="$(_ci_image_ref)"

    _registry_login

    if published_revision="$(_published_revision_of "${ref}")"; then
        if [ "${published_revision}" = "$(_ci_commit_sha)" ]; then
            _warn "${ref} is already published for this commit; leaving it alone"
            _publish_report "${ref}" "${published_revision}"
            _stage_end
            return 0
        fi
        # Same refusal either way, but the reason and the fix differ.
        if [ -n "${CI_RELEASE_TAG:-}" ]; then
            _error "${ref} was already released from ${published_revision}; a published release tag does not move. Cut a new version instead"
        fi
        _error "${ref} exists and was built from ${published_revision}, not $(_ci_commit_sha): two commits shortened to the same prefix, so bump VERSION"
    fi

    local arch_refs=()
    for arch in ${CI_ARCHES}; do
        archive="${CI_ARTIFACT_DIR}/image-${arch}.tar"
        [ -f "${archive}" ] || _error "no tested archive for ${arch} at ${archive}"

        # Tag straight after each load: both archives carry the same tag.
        _info "loading and pushing the tested ${arch} image"
        docker load --input "${archive}" >/dev/null
        docker tag "${ref}" "${ref}-${arch}"
        docker push --quiet "${ref}-${arch}"
        arch_refs+=("${ref}-${arch}")
    done

    # One index, two names: the version people pull, and the same thing with the
    # commit spelled out. Built in a single call so they cannot drift apart.
    local names=() name
    for name in $(_ci_publish_tags); do
        names+=(--tag "${CI_IMAGE_NAME}:${name}")
    done

    _info "assembling the multi-architecture manifest: $(_ci_publish_tags | tr '\n' ' ')"
    docker buildx imagetools create "${names[@]}" "${arch_refs[@]}"

    _publish_report "${ref}" "$(_ci_commit_sha)"

    _info "published ${ref}"
    _stage_end
}

# What a release is published under. The bare version is what a human types;
# the one carrying the commit is what an incident is traced with.
_ci_publish_tags() {
    _ci_image_version
    if [ -n "${CI_RELEASE_TAG:-}" ]; then
        echo "$(_ci_image_version)-$(_ci_short_sha)"
    fi
}

_publish_report() {
    local ref="$1" revision="$2" name rows=()
    for name in $(_ci_publish_tags); do
        rows+=("row=PASS|Tag|\`${CI_IMAGE_NAME}:${name}\`")
    done
    report table name=publish.md title=Publish \
        "headers=|Item|Value" \
        "${rows[@]}" \
        "row=PASS|Index digest|\`$(docker buildx imagetools inspect "${ref}" --format '{{.Manifest.Digest}}')\`" \
        "row=PASS|Revision|\`${revision}\`" \
        "row=PASS|Platforms|$(_platform_list)"
}

# "`linux/amd64`, `linux/arm64`", from CI_ARCHES.
_platform_list() {
    local arch out=""
    for arch in ${CI_ARCHES}; do
        out="${out}${out:+, }\`linux/${arch}\`"
    done
    echo "${out}"
}

# The revision of an already-published tag, or non-zero if there is none. Read
# off a pulled image: the label is in the config blob, not the index.
_published_revision_of() {
    local ref="$1" any
    # Any platform answers; one commit, one label.
    any="${CI_ARCHES%% *}"
    docker buildx imagetools inspect "${ref}" >/dev/null 2>&1 || return 1
    docker pull --quiet --platform "linux/${any}" "${ref}" >/dev/null 2>&1 || return 1
    docker image inspect "${ref}" \
        --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}'
}

# The only step that asks the registry, and the only proof the tag resolves.
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

    for arch in ${CI_ARCHES}; do
        want="linux/${arch}"
        case " ${platforms} " in
            *" ${want} "*) _info "${want} present" ;;
            *)
                echo "  missing ${want} in ${ref} (found: ${platforms})" >&2
                failures=$((failures + 1))
                ;;
        esac
    done

    # An index entry is a promise; a pull is evidence.
    for arch in ${CI_ARCHES}; do
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

    local status="PASS"
    [ "${failures}" -eq 0 ] || status="FAIL"
    report table name=verify-published.md title="Published image verified" \
        "headers=|Check" \
        "row=${status}|\`${ref}\` resolves for $(_platform_list)" \
        "row=${status}|every platform pulls and reports revision \`$(_ci_commit_sha)\`"

    [ "${failures}" -eq 0 ] || _error "${failures} check(s) failed for ${ref}"

    _info "${ref} verified"
    _stage_end
}

# Records a release that is already published and verified by the time this
# runs, so it creates nothing that has not been checked.
do_github_release() {
    _stage_begin "GitHub Release"
    _require_cmd gh sha256sum
    local tag ref arch assets=() rows=()
    tag="${CI_RELEASE_TAG:-}"
    [ -n "${tag}" ] || _error "CI_RELEASE_TAG is not set; this job only runs for a tag"
    ref="$(_ci_image_ref)"

    for arch in ${CI_ARCHES}; do
        local binary="${CI_ARTIFACT_DIR}/${BINARY_NAME}-linux-${arch}"
        [ -f "${binary}" ] || _error "no binary for ${arch} at ${binary}"
        chmod +x "${binary}"
        assets+=("${binary}")
        rows+=("row=PASS|Binary|\`${BINARY_NAME}-linux-${arch}\`")
    done

    # One checksum file over all of them, so a download can be verified without
    # trusting the page it came from.
    ( cd "${CI_ARTIFACT_DIR}" && sha256sum "${BINARY_NAME}"-linux-* > SHA256SUMS )
    assets+=("${CI_ARTIFACT_DIR}/SHA256SUMS")
    _info "assets:"
    cat "${CI_ARTIFACT_DIR}/SHA256SUMS"

    if gh release view "${tag}" >/dev/null 2>&1; then
        _warn "release ${tag} already exists; replacing its assets"
        gh release upload "${tag}" "${assets[@]}" --clobber
    else
        # --verify-tag so a typo cannot create a release against a tag that is
        # not in the remote. --notes is prepended to the generated notes.
        gh release create "${tag}" "${assets[@]}" \
            --verify-tag \
            --generate-notes \
            --notes "$(_release_notes "${ref}")"
        _info "created release ${tag}"
    fi

    report table name=release.md title="GitHub Release" \
        "headers=|Item|Value" \
        "row=PASS|Release|\`${tag}\`" \
        "row=PASS|Image|\`${ref}\`" \
        "${rows[@]}"
    _stage_end
}

_release_notes() {
    local ref="$1"
    cat <<EOF
### Container

    docker pull ${ref}

One tag, both architectures; the registry serves the one you ask for.

### Binary

Lifted from that image, so it is the executable that was scanned and tested.
Linux, \`amd64\` and \`arm64\`.

    curl -LO https://github.com/shahar-spormas/echo-pong/releases/download/${CI_RELEASE_TAG}/${BINARY_NAME}-linux-amd64
    curl -LO https://github.com/shahar-spormas/echo-pong/releases/download/${CI_RELEASE_TAG}/SHA256SUMS
    sha256sum -c SHA256SUMS --ignore-missing
    chmod +x ${BINARY_NAME}-linux-amd64

Both modes read the secret from a file named by \`SECRET_FILE_PATH\`; in CLI
mode \`--password\` is the value checked against it.

    echo -n mysecret > token
    SECRET_FILE_PATH=./token ./${BINARY_NAME}-linux-amd64 --mode=cli --password=mysecret ping
    SECRET_FILE_PATH=./token ./${BINARY_NAME}-linux-amd64 --mode=server
EOF
}

# Best effort: the cluster may not exist, which is part of the answer.
do_diagnostics() {
    _stage_begin "Diagnostics"
    command -v kubectl >/dev/null 2>&1 || { _info "kubectl unavailable"; return 0; }
    local selector="app.kubernetes.io/name=ping-pong"

    _info "--- workloads"
    kubectl get all,ingress,netpol -A -o wide || true
    kubectl get nodes -o wide || true

    # All namespaces: the interesting event is rarely the app's.
    _info "--- events"
    kubectl get events -A --sort-by=.lastTimestamp | tail -40 || true

    # Why a pod is unhappy, then what it said before it died.
    _info "--- application"
    kubectl describe pods -l "${selector}" || true
    kubectl logs -l "${selector}" --tail=100 --all-containers --prefix || true
    kubectl logs -l "${selector}" --tail=50 --previous --prefix 2>/dev/null || true

    # An empty EndpointSlice looks just like a network fault from outside.
    _info "--- endpoints"
    kubectl get endpointslices -l "kubernetes.io/service-name=${SERVICE:-ping-pong}" -o wide || true

    # Outside the app's selector, and where a Docker Hub 429 shows up.
    _info "--- probes"
    kubectl describe pod -n "${PROBE_NS:-netpol-probe}" 2>/dev/null || true
    kubectl describe pod "${PROBE_POD:-zdd-probe}" 2>/dev/null || true

    _info "--- ingress and cni"
    kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --tail=80 || true
    kubectl -n calico-system get pods || true

    # The node's images, not the host's: a failed side-load differs here.
    _info "--- images on the node"
    docker exec "${CLUSTER_NAME}-control-plane" crictl images 2>/dev/null || true

    # Runners get 14GB; a cluster plus images has filled it before.
    _info "--- runner disk"
    df -h / || true
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

# Derived, not listed. The do_ prefix is also the boundary to the _ helpers.
_usage() {
    echo "usage: ${SCRIPT_NAME} <job>"
    echo
    echo "jobs:"
    declare -F | awk '$3 ~ /^do_/ { print "  " $3 }' | sort
}

_main() {
    local requested="${1:-}"

    case "${requested}" in
        -h | --help)
            _usage
            return 0
            ;;
        "")
            _usage >&2
            _error "no job given"
            ;;
        do_*)
            if declare -F "${requested}" >/dev/null; then
                shift
                "${requested}" "$@"
                return
            fi
            ;;
    esac

    _usage >&2
    _error "unknown job: ${requested}"
}

_main "$@"
