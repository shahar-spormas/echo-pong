#!/usr/bin/env python3
"""Renders a CI stage's result as markdown.

    report.py <stage> out=<dir> key=value ...

Every stage produces the same document: a title, a verdict, and a list of
blocks. render() knows how to write those; a builder only decides what they
contain. Adding a stage is one function and one line in BUILDERS, with no
argument declarations, because arguments arrive as key=value pairs.

Counts go to stdout and detail to stderr, so a caller can read the numbers
while the detail lands in the log:

    read -r blocking suppressed < <(report.py scan out=... json=...)
"""

import csv
import json
import os
import sys
from pathlib import Path

MARKS = {"PASS": "V", "FAIL": "X"}


def mark(status):
    """V, X or - from a status name or a boolean."""
    if isinstance(status, bool):
        status = "PASS" if status else "FAIL"
    return MARKS.get(status, "-")


def cell(value):
    """A pipe in a message would otherwise split the table cell."""
    return str(value).replace("|", "\\|")


def note(message):
    print(message, file=sys.stderr)


def load_json(path):
    text = Path(path).read_text().strip()
    return json.loads(text) if text else []


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------


def table(headers, rows):
    lines = ["| " + " | ".join(headers) + " |", "|" + "---|" * len(headers)]
    lines += ["| " + " | ".join(cell(c) for c in row) + " |" for row in rows]
    return lines


def render(doc):
    lines = [f"## {doc['title']} — {doc['verdict']}", ""]
    for kind, payload in doc["blocks"]:
        if kind == "text":
            lines += [payload, ""]
        elif kind == "table":
            lines += table(*payload) + [""]
        elif kind == "details":
            summary, headers, rows = payload
            lines += [f"<details><summary>{summary}</summary>", ""]
            lines += table(headers, rows)
            lines += ["", "</details>", ""]
        else:
            raise SystemExit(f"unknown block: {kind}")
    return "\n".join(lines) + "\n"


def write(directory, name, body):
    path = Path(directory) / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body)

    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as handle:
            handle.write(body)

    note(f"==> report: {path}")


# ---------------------------------------------------------------------------
# Builders: given the options, return a document
# ---------------------------------------------------------------------------


def build_static(o):
    shellcheck = load_json(o["shellcheck"])
    actionlint = load_json(o["actionlint"])
    syntax = int(o["syntax"])

    for f in shellcheck:
        note(f"  [X] {f['file']}:{f['line']}:{f['column']} SC{f['code']} ({f['level']}) {f['message']}")
    for f in actionlint:
        note(f"  [X] {f['filepath']}:{f['line']}:{f['column']} [{f['kind']}] {f['message']}")

    return {
        "name": "static-checks.md",
        "title": "Static checks",
        "verdict": "PASS" if not (syntax or shellcheck or actionlint) else "FAIL",
        "counts": [len(shellcheck), len(actionlint)],
        "blocks": [
            ("table", (["", "Check", "Findings"], [
                [mark(syntax == 0), f"syntax check on {o['files']} file(s)", syntax],
                [mark(not shellcheck), f"shellcheck {o['shellcheck_version']}, warning and above", len(shellcheck)],
                [mark(not actionlint), f"actionlint {o['actionlint_version']}", len(actionlint)],
            ])),
            ("text", "Reports: `shellcheck.json`, `actionlint.json`"),
        ],
    }


def build_scan(o):
    data = load_json(o["json"])
    wanted = set(o["severity"].split(","))
    arch = o["arch"]

    blocking, accepted, packages = [], [], 0
    for result in data.get("Results") or []:
        packages += len(result.get("Packages") or [])
        blocking += [v for v in result.get("Vulnerabilities") or [] if v.get("Severity") in wanted]
        # A suppressed entry wraps the vulnerability in .Finding and records
        # why it was let through alongside it.
        accepted += [e for e in result.get("ExperimentalModifiedFindings") or []
                     if e.get("Finding", {}).get("Severity") in wanted]

    note(f"==> {packages} package(s) scanned, {len(blocking)} unapproved, {len(accepted)} accepted")
    for e in accepted:
        f = e["Finding"]
        note(f"  accepted  {f['Severity']}  {f['VulnerabilityID']}  "
             f"{f['PkgName']} {f['InstalledVersion']}  ({e.get('Status', '?')})")
    for v in blocking:
        note(f"  BLOCKING  {v['Severity']}  {v['VulnerabilityID']}  {v['PkgName']} "
             f"{v['InstalledVersion']}  fixed in: {v.get('FixedVersion') or 'no fix'}")

    blocks = [
        ("table", (["", "Result", "Count"], [
            [mark(not blocking), f"Unapproved {o['severity']}", len(blocking)],
            [mark("SKIP"), f"Accepted, expiring {o['expiry']}", len(accepted)],
        ])),
        ("text", f"Image `{o['image']}`, scanned with Trivy {o['trivy_version']}."),
    ]

    if blocking:
        blocks.append(("table", (["Severity", "ID", "Package", "Installed", "Fixed in"], [
            [v["Severity"], v["VulnerabilityID"], v["PkgName"], v["InstalledVersion"],
             v.get("FixedVersion") or "no fix"] for v in blocking
        ])))

    if accepted:
        blocks.append(("details", (f"{len(accepted)} accepted finding(s)",
                                   ["ID", "Package", "Reason"], [
            [e["Finding"]["VulnerabilityID"],
             f"{e['Finding']['PkgName']} {e['Finding']['InstalledVersion']}",
             e.get("Statement") or "-"] for e in accepted
        ])))

    blocks.append(("text",
        f"Reports: `trivy-{arch}.txt` (full table, accepted findings included), "
        f"`trivy-{arch}.sarif` and `trivy-{arch}.json`. SARIF carries only findings "
        "that are not accepted, so it is empty while the table is not."))

    return {
        "name": f"scan-{arch}.md",
        "title": f"Vulnerability scan — linux/{arch}",
        "verdict": "FAIL" if blocking else "PASS",
        "counts": [len(blocking), len(accepted)],
        "blocks": blocks,
    }


def build_e2e(o):
    # scripts/lib/checks.sh records STATUS<tab>SECTION<tab>MESSAGE.
    def results(path):
        if not Path(path).exists():
            return []
        with open(path, newline="") as handle:
            return [r for r in csv.reader(handle, delimiter="\t") if len(r) == 3]

    blocks = [("text", f"Image `{o['image']}` on Kubernetes {o['kubernetes']}, kind {o['kind']}.")]
    failed = False

    for title, path, rc in (("Smoke test", o["smoke"], int(o["smoke_rc"])),
                            ("Zero-downtime", o["zdd"], int(o["zdd_rc"]))):
        rows = results(path)
        counts = {s: sum(1 for r in rows if r[0] == s) for s in ("PASS", "FAIL", "SKIP")}
        table_rows = [[mark(status), section, message] for status, section, message in rows]

        # A script killed by a raw kubectl error records no failure of its own,
        # so without this the report shows an empty table under a passing heading.
        if rc != 0 and not counts["FAIL"]:
            table_rows.append(["X", "—", f"script exited {rc} before reaching a check; see the log"])
        failed = failed or rc != 0

        blocks.append(("text", f"### {title} — {counts['PASS']} passed, "
                               f"{counts['FAIL']} failed, {counts['SKIP']} skipped"))
        blocks.append(("table", (["", "Section", "Check"], table_rows)))

    return {
        "name": f"e2e-{o['arch']}.md",
        "title": f"Kubernetes end-to-end — linux/{o['arch']}",
        "verdict": "FAIL" if failed else "PASS",
        "blocks": blocks,
    }


def build_publish(o):
    return {
        "name": "publish.md",
        "title": "Publish",
        "verdict": "PASS",
        "blocks": [("table", (["", "Item", "Value"], [
            [mark("PASS"), "Tag", f"`{o['ref']}`"],
            [mark("PASS"), "Index digest", f"`{o['digest']}`"],
            [mark("PASS"), "Revision", f"`{o['revision']}`"],
            [mark("PASS"), "Platforms", "`linux/amd64`, `linux/arm64`"],
        ]))],
    }


def build_verify(o):
    status = "PASS" if int(o["failures"]) == 0 else "FAIL"
    return {
        "name": "verify-published.md",
        "title": "Published image verified",
        "verdict": status,
        "blocks": [("table", (["", "Check"], [
            [mark(status), f"`{o['ref']}` resolves for `linux/amd64` and `linux/arm64`"],
            [mark(status), f"both platforms pull and report revision `{o['revision']}`"],
        ]))],
    }


BUILDERS = {
    "static": build_static,
    "scan": build_scan,
    "e2e": build_e2e,
    "publish": build_publish,
    "verify": build_verify,
}


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in BUILDERS:
        raise SystemExit(f"usage: {Path(sys.argv[0]).name} "
                         f"<{'|'.join(BUILDERS)}> out=<dir> key=value ...")

    stage = sys.argv[1]
    options = dict(arg.split("=", 1) for arg in sys.argv[2:] if "=" in arg)

    doc = BUILDERS[stage](options)
    write(options["out"], doc["name"], render(doc))

    if doc.get("counts"):
        print(" ".join(str(c) for c in doc["counts"]))


if __name__ == "__main__":
    main()
