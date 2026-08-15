#!/usr/bin/env bash
# Reporting shared by scripts/smoke-test.sh and scripts/verify-zdd.sh.
#
# Markers are [V], [X] and [-] rather than words or emoji: they line up in a
# column, so a failure is findable by eye in a few hundred lines of log.
#
# Set CHECK_REPORT to a path and every result is also appended as
# "STATUS<tab>SECTION<tab>MESSAGE". CI renders that into the run summary and
# keeps it as an artifact; locally it stays unset and nothing is written.

CHECK_PASS=0
CHECK_FAIL=0
CHECK_SKIP=0
CHECK_SECTION="preflight"
CHECK_WIDTH="${CHECK_WIDTH:-74}"
CHECK_REPORT="${CHECK_REPORT:-}"

_check_fill() {
  local char="$1" count="$2"
  [[ "$count" -lt 1 ]] && count=1
  printf '%*s' "$count" '' | tr ' ' "$char"
}

# The banner a script opens with: what ran, and against what.
check_title() {
  echo
  _check_fill '=' "$CHECK_WIDTH"
  echo
  printf ' %s\n' "$*"
  _check_fill '=' "$CHECK_WIDTH"
  echo
}

check_section() {
  CHECK_SECTION="$*"
  local label=" -- $* "
  echo
  printf '%s' "$label"
  _check_fill '-' $(( CHECK_WIDTH - ${#label} ))
  echo
}

_check_record() {
  [[ -n "$CHECK_REPORT" ]] || return 0
  printf '%s\t%s\t%s\n' "$1" "$CHECK_SECTION" "$2" >> "$CHECK_REPORT"
}

pass() {
  printf ' [V] %s\n' "$*"
  CHECK_PASS=$((CHECK_PASS + 1))
  _check_record PASS "$*"
}

fail() {
  printf ' [X] %s\n' "$*"
  CHECK_FAIL=$((CHECK_FAIL + 1))
  _check_record FAIL "$*"
}

skip() {
  printf ' [-] %s\n' "$*"
  CHECK_SKIP=$((CHECK_SKIP + 1))
  _check_record SKIP "$*"
}

# Context, not a result: indented under whatever it follows and never counted.
info() {
  printf '     %s\n' "$*"
}

# Last thing a script runs, so its exit status is the script's.
check_summary() {
  local verdict="PASS"
  [[ "$CHECK_FAIL" -gt 0 ]] && verdict="FAIL"

  echo
  _check_fill '=' "$CHECK_WIDTH"
  echo
  printf ' %-6s  passed %-4d failed %-4d skipped %-4d\n' \
    "$verdict" "$CHECK_PASS" "$CHECK_FAIL" "$CHECK_SKIP"
  _check_fill '=' "$CHECK_WIDTH"
  echo

  [[ "$CHECK_FAIL" -eq 0 ]]
}
