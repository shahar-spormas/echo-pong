#!/usr/bin/env bash
# Reporting shared by scripts/smoke-test.sh and scripts/verify-zdd.sh.
#
# Console gets [V], [X], [-] in a fixed column, so a failure is findable by eye.
# Set CHECK_REPORT and the same results are written as TAP 14
# (https://testanything.org) for CI to render and keep.
#
# TAP because it already has all of it: ok/not ok, a SKIP directive, subtests
# for sections, and a closing 1..N plan. The plan is the point: a script killed
# part way writes fewer results than it promised, and that mismatch is what
# says the run was truncated.

CHECK_PASS=0
CHECK_FAIL=0
CHECK_SKIP=0
CHECK_TOTAL=0
CHECK_WIDTH="${CHECK_WIDTH:-74}"
CHECK_REPORT="${CHECK_REPORT:-}"

_check_fill() {
  local char="$1" count="$2"
  [[ "$count" -lt 1 ]] && count=1
  printf '%*s' "$count" '' | tr ' ' "$char"
}

_tap() {
  [[ -n "$CHECK_REPORT" ]] || return 0
  printf '%s\n' "$*" >> "$CHECK_REPORT"
}

# What ran, and against what.
check_title() {
  echo
  _check_fill '=' "$CHECK_WIDTH"
  echo
  printf ' %s\n' "$*"
  _check_fill '=' "$CHECK_WIDTH"
  echo

  _tap "TAP version 14"
  _tap "# $*"
}

check_section() {
  local label=" -- $* "
  echo
  printf '%s' "$label"
  _check_fill '-' $(( CHECK_WIDTH - ${#label} ))
  echo

  _tap "# Subtest: $*"
}

pass() {
  printf ' [V] %s\n' "$*"
  CHECK_PASS=$((CHECK_PASS + 1))
  CHECK_TOTAL=$((CHECK_TOTAL + 1))
  _tap "ok ${CHECK_TOTAL} - $*"
}

fail() {
  printf ' [X] %s\n' "$*"
  CHECK_FAIL=$((CHECK_FAIL + 1))
  CHECK_TOTAL=$((CHECK_TOTAL + 1))
  _tap "not ok ${CHECK_TOTAL} - $*"
}

# Counted, not a failure. TAP has a directive for it.
skip() {
  printf ' [-] %s\n' "$*"
  CHECK_SKIP=$((CHECK_SKIP + 1))
  CHECK_TOTAL=$((CHECK_TOTAL + 1))
  _tap "ok ${CHECK_TOTAL} - $* # SKIP"
}

# Context, not a result: never counted.
info() {
  printf '     %s\n' "$*"
  _tap "# $*"
}

# Last thing a script runs, so its status is the script's. The plan is written
# only here, which is what makes its absence meaningful.
check_summary() {
  local verdict="PASS"
  [[ "$CHECK_FAIL" -gt 0 ]] && verdict="FAIL"

  _tap "1..${CHECK_TOTAL}"

  echo
  _check_fill '=' "$CHECK_WIDTH"
  echo
  printf ' %-6s  passed %-4d failed %-4d skipped %-4d\n' \
    "$verdict" "$CHECK_PASS" "$CHECK_FAIL" "$CHECK_SKIP"
  _check_fill '=' "$CHECK_WIDTH"
  echo

  [[ "$CHECK_FAIL" -eq 0 ]]
}
