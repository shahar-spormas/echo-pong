#!/usr/bin/env python3
"""Renders a CI stage's result as markdown.

    report.py <stage> out=<dir> key=value ...

Every stage is the same document: title, verdict, list of blocks. render()
writes those; a builder only says what they contain. `table` takes its rows on
the command line, so a stage needs code here only to read a foreign format,
which is why the two builders are Trivy JSON and the check scripts' TAP.

Counts go to stdout, detail to stderr:

    read -r blocking suppressed < <(report.py scan out=... json=...)
"""

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
    """A pipe would otherwise split the table cell."""
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


# The default, for stages with nothing to parse:
#
#   report.py table out=DIR name=publish.md title=Publish \
#       headers='|Item|Value' row='PASS|Tag|`x`'
#
# The verdict defaults to the worst row, so a heading cannot contradict them.
def build_table(o):
    rows, statuses = [], []
    for spec in o["row"]:
        status, *cells = spec.split("|")
        statuses.append(status)
        rows.append([mark(status)] + cells)

    verdict = o.get("verdict") or ("FAIL" if "FAIL" in statuses else "PASS")
    blocks = [("table", (o.get("headers", "|Item|Value").split("|"), rows))]
    if o.get("note"):
        blocks.append(("text", o["note"]))

    return {"name": o["name"], "title": o["title"], "verdict": verdict, "blocks": blocks}


def build_scan(o):
    data = load_json(o["json"])
    wanted = set(o["severity"].split(","))
    arch = o["arch"]

    blocking, accepted, packages = [], [], 0
    for result in data.get("Results") or []:
        packages += len(result.get("Packages") or [])
        blocking += [v for v in result.get("Vulnerabilities") or [] if v.get("Severity") in wanted]
        # Suppressed entries nest the vulnerability under .Finding.
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


def read_tap(path):
    """A TAP 14 stream as (results, plan); plan is None if never written.

    Only the subset scripts/lib/checks.sh emits: test points, `# Subtest:`
    headers, and the closing plan that says the producer reached the end.
    """
    results, plan, section = [], None, ""
    if not Path(path).exists():
        return results, plan

    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if line.startswith("# Subtest:"):
            section = line[len("# Subtest:"):].strip()
        elif line.startswith("1.."):
            plan = int(line[3:] or 0)
        elif line.startswith(("ok ", "not ok ")):
            ok = not line.startswith("not ok")
            description = line.split(" - ", 1)[1] if " - " in line else line
            skipped = "# SKIP" in description
            description = description.replace("# SKIP", "").strip()
            results.append(("SKIP" if skipped else "PASS" if ok else "FAIL",
                            section, description))

    return results, plan


def build_e2e(o):
    blocks = [("text", f"Image `{o['image']}` on Kubernetes {o['kubernetes']}, kind {o['kind']}.")]
    failed = False

    for title, path in (("Smoke test", o["smoke"]), ("Zero-downtime", o["zdd"])):
        results, plan = read_tap(path)
        counts = {s: sum(1 for r in results if r[0] == s) for s in ("PASS", "FAIL", "SKIP")}
        rows = [[mark(status), section, description] for status, section, description in results]

        # Written last, so a missing or short plan means a truncated run.
        if plan is None:
            rows.append(["X", "—", "no plan line: the script did not reach the end, see the log"])
        elif plan != len(results):
            rows.append(["X", "—", f"planned {plan} checks but recorded {len(results)}"])

        failed = failed or counts["FAIL"] > 0 or plan != len(results)

        blocks.append(("text", f"### {title} — {counts['PASS']} passed, "
                               f"{counts['FAIL']} failed, {counts['SKIP']} skipped"))
        blocks.append(("table", (["", "Section", "Check"], rows)))

    return {
        "name": f"e2e-{o['arch']}.md",
        "title": f"Kubernetes end-to-end — linux/{o['arch']}",
        "verdict": "FAIL" if failed else "PASS",
        "blocks": blocks,
    }


BUILDERS = {
    "table": build_table,
    # Only stages that read a foreign format need their own builder.
    "scan": build_scan,
    "e2e": build_e2e,
}


def parse_options(argv):
    """key=value pairs, repeated keys collected into a list."""
    options = {"row": []}
    for arg in argv:
        key, separator, value = arg.partition("=")
        if not separator:
            continue
        if isinstance(options.get(key), list):
            options[key].append(value)
        else:
            options[key] = value
    return options


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in BUILDERS:
        raise SystemExit(f"usage: {Path(sys.argv[0]).name} "
                         f"<{'|'.join(BUILDERS)}> out=<dir> key=value ...")

    options = parse_options(sys.argv[2:])
    doc = BUILDERS[sys.argv[1]](options)
    write(options["out"], doc["name"], render(doc))

    if doc.get("counts"):
        print(" ".join(str(c) for c in doc["counts"]))


if __name__ == "__main__":
    main()
