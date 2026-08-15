#!/usr/bin/env bash
# Turns what a stage found into something worth reading: a markdown summary on
# the run itself, rendered from the same files that get kept as artifacts, so
# the two cannot disagree.
#
# Sourced by .ci/ci_jobs.sh, which owns the stages and provides _info and
# friends. Nothing here decides whether a stage passed; it is handed the counts
# and reports them.

# Markdown lands in a file first and is copied into the run summary after, so a
# local run produces the same report without a GitHub environment.
_report_open() {
    CI_REPORT_FILE="${CI_REPORT_DIR}/$1"
    mkdir -p "${CI_REPORT_DIR}"
    : > "${CI_REPORT_FILE}"
}

_report() {
    printf '%s\n' "$*" >> "${CI_REPORT_FILE}"
}

_report_close() {
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        cat "${CI_REPORT_FILE}" >> "${GITHUB_STEP_SUMMARY}"
    fi
    _info "report: ${CI_REPORT_FILE}"
}

# V for pass, X for fail, - for skipped, matching the check scripts.
_mark() {
    case "$1" in
        PASS) echo "V" ;;
        FAIL) echo "X" ;;
        *) echo "-" ;;
    esac
}

# ---------------------------------------------------------------------------
# scripts/lib/checks.sh records results as STATUS<tab>SECTION<tab>MESSAGE
# ---------------------------------------------------------------------------

_tsv_count() {
    grep -c "^$2" "$1" 2>/dev/null || true
}

_tsv_rows() {
    awk -F'\t' '{
        mark = ($1 == "PASS") ? "V" : ($1 == "FAIL") ? "X" : "-"
        gsub(/\|/, "\\|", $3)
        printf "| %s | %s | %s |\n", mark, $2, $3
    }' "$1"
}

# ---------------------------------------------------------------------------
# Per-stage reports
# ---------------------------------------------------------------------------

_static_report() {
    local script_count="$1" syntax="$2" sc="$3" al="$4" verdict="PASS"
    [ $((syntax + sc + al)) -gt 0 ] && verdict="FAIL"

    _report_open "static-checks.md"
    _report "## Static checks — ${verdict}"
    _report
    _report "| | Check | Findings |"
    _report "|---|---|---|"
    _report "| $(_mark "$([ "${syntax}" -eq 0 ] && echo PASS || echo FAIL)") | \`bash -n\` on ${script_count} script(s) | ${syntax} |"
    _report "| $(_mark "$([ "${sc}" -eq 0 ] && echo PASS || echo FAIL)") | shellcheck $(shellcheck --version | awk '/version:/ {print $2}'), warning and above | ${sc} |"
    _report "| $(_mark "$([ "${al}" -eq 0 ] && echo PASS || echo FAIL)") | actionlint ${ACTIONLINT_VERSION} | ${al} |"
    _report
    _report "Reports: \`shellcheck.json\`, \`actionlint.json\`"
    _report_close
}

_scan_report() {
    local arch="$1" report="$2" blocking="$3" suppressed="$4" verdict="PASS"
    [ "${blocking}" -gt 0 ] && verdict="FAIL"

    _report_open "scan-${arch}.md"
    _report "## Vulnerability scan — linux/${arch} — ${verdict}"
    _report
    _report "| | Result | Count |"
    _report "|---|---|---|"
    _report "| $(_mark "$([ "${blocking}" -eq 0 ] && echo PASS || echo FAIL)") | Unapproved ${SCAN_SEVERITY} | ${blocking} |"
    _report "| $(_mark SKIP) | Accepted, expiring 2026-09-07 | ${suppressed} |"
    _report
    _report "Image \`$(_ci_image_version)\`, scanned with Trivy $(trivy --version | awk 'NR==1 {print $2}')."
    _report

    if [ "${blocking}" -gt 0 ]; then
        _report "### Blocking"
        _report
        _report "| Severity | ID | Package | Installed | Fixed in |"
        _report "|---|---|---|---|---|"
        jq -r '.Results[]?.Vulnerabilities[]?
            | select(.Severity == "HIGH" or .Severity == "CRITICAL")
            | "| \(.Severity) | \(.VulnerabilityID) | \(.PkgName) | \(.InstalledVersion) | \(.FixedVersion // "no fix") |"' \
            "${report}" >> "${CI_REPORT_FILE}"
        _report
    fi

    if [ "${suppressed}" -gt 0 ]; then
        _report "<details><summary>${suppressed} accepted finding(s)</summary>"
        _report
        _report "| ID | Package | Reason |"
        _report "|---|---|---|"
        jq -r '.Results[]?.ExperimentalModifiedFindings[]?
            | select(.Finding.Severity == "HIGH" or .Finding.Severity == "CRITICAL")
            | "| \(.Finding.VulnerabilityID) | \(.Finding.PkgName) \(.Finding.InstalledVersion) | \(.Statement // "-") |"' \
            "${report}" >> "${CI_REPORT_FILE}"
        _report
        _report "</details>"
        _report
    fi

    _report "Reports: \`trivy-${arch}.txt\` (full table, accepted findings included),"
    _report "\`trivy-${arch}.sarif\` and \`trivy-${arch}.json\`. SARIF carries only"
    _report "findings that are not accepted, so it is empty while the table is not."
    _report_close
}

_e2e_report() {
    local arch="$1" smoke="$2" smoke_rc="$3" zdd="$4" zdd_rc="$5" verdict="PASS"

    # A script that dies on a raw kubectl error records no failure of its own,
    # so the verdict follows the exit codes and not just the counters. Otherwise
    # an aborted run reports PASS with nothing in it, which is worse than no
    # report at all.
    [ "${smoke_rc}" -eq 0 ] && [ "${zdd_rc}" -eq 0 ] || verdict="FAIL"

    _report_open "e2e-${arch}.md"
    _report "## Kubernetes end-to-end — linux/${arch} — ${verdict}"
    _report
    _report "Image \`$(_ci_image_version)\` on Kubernetes ${KUBECTL_VERSION}, kind ${KIND_VERSION}."
    _report

    _e2e_section "Smoke test" "${smoke}" "${smoke_rc}"
    _e2e_section "Zero-downtime" "${zdd}" "${zdd_rc}"
    _report_close
}

_e2e_section() {
    local title="$1" tsv="$2" rc="$3"

    _report "### ${title} — $(_tsv_count "${tsv}" PASS) passed, $(_tsv_count "${tsv}" FAIL) failed, $(_tsv_count "${tsv}" SKIP) skipped"
    _report
    _report "| | Section | Check |"
    _report "|---|---|---|"
    _tsv_rows "${tsv}" >> "${CI_REPORT_FILE}"
    if [ "${rc}" -ne 0 ] && [ "$(_tsv_count "${tsv}" FAIL)" -eq 0 ]; then
        _report "| X | — | script exited ${rc} before reaching a check; see the log |"
    fi
    _report
}

_publish_report() {
    local ref="$1" digest="$2" revision="$3"

    _report_open "publish.md"
    _report "## Publish — PASS"
    _report
    _report "| | Item | Value |"
    _report "|---|---|---|"
    _report "| $(_mark PASS) | Tag | \`${ref}\` |"
    _report "| $(_mark PASS) | Index digest | \`${digest}\` |"
    _report "| $(_mark PASS) | Revision | \`${revision}\` |"
    _report "| $(_mark PASS) | Platforms | \`linux/amd64\`, \`linux/arm64\` |"
    _report_close
}

_verify_report() {
    local ref="$1" revision="$2" failures="$3" status="PASS"
    [ "${failures}" -eq 0 ] || status="FAIL"

    _report_open "verify-published.md"
    _report "## Published image verified — ${status}"
    _report
    _report "| | Check |"
    _report "|---|---|"
    _report "| $(_mark "${status}") | \`${ref}\` resolves for \`linux/amd64\` and \`linux/arm64\` |"
    _report "| $(_mark "${status}") | both platforms pull and report revision \`${revision}\` |"
    _report_close
}
