#!/usr/bin/env python3
"""Convert a `go test -v` log into JUnit XML.

Usage: gotest-log-to-junit.py <go-test-log> <output-junit-xml>

The Argo CD e2e suite is the one suite in this image that does not produce a JUnit
report of its own: it is a plain Go test binary, and go-junit-report is not installed.
Without a report, parse-test-results.py has nothing to read, so every run is published
with no counts and a bare ERROR status. This reconstructs the report from the log the
runner already keeps.

Counting matches the runner's own Final Results block, so the XML and the log agree:

  - only top-level results count. Go indents subtest lines, so anchoring on `^--- `
    counts `TestFoo` once and ignores its `TestFoo/case-1` children.
  - the log may hold several runs concatenated, because the runner resumes the suite
    after a crash rather than restarting it. Results accumulate across them.
  - a crash that kills the binary before the running test prints its own `--- FAIL:`
    line is still a failure, and is recorded here from the runner's CRASH DETECTED
    line. When the test did print `--- FAIL:` it is already counted, so it is not
    counted twice.
"""

import re
import sys
from xml.etree import ElementTree as ET

RESULT_RE = re.compile(r"^--- (PASS|FAIL|SKIP): (\S+) \(([0-9.]+)s\)")
CRASH_RE = re.compile(r"^CRASH DETECTED during: (\S+)")
PACKAGE_RE = re.compile(r"^(?:ok|FAIL)\s+(\S+)")


def parse_log(path):
    results = []          # (status, name, seconds) in the order they were reported
    crashed = []          # test names the binary died on
    package = "e2e"
    with open(path, errors="replace") as f:
        for line in f:
            m = RESULT_RE.match(line)
            if m:
                results.append((m.group(1), m.group(2), float(m.group(3))))
                continue
            m = CRASH_RE.match(line)
            if m:
                crashed.append(m.group(1))
                continue
            m = PACKAGE_RE.match(line)
            if m:
                package = m.group(1)
    failed_names = {name for status, name, _ in results if status == "FAIL"}
    for name in crashed:
        if name not in failed_names:
            results.append(("FAIL", name, 0.0))
            failed_names.add(name)
    return results, package


def build_junit(results, package):
    passed = sum(1 for s, _, _ in results if s == "PASS")
    failed = sum(1 for s, _, _ in results if s == "FAIL")
    skipped = sum(1 for s, _, _ in results if s == "SKIP")

    suite = ET.Element("testsuite", {
        "name": package,
        "tests": str(len(results)),
        "failures": str(failed),
        "errors": "0",
        "skipped": str(skipped),
        "time": f"{sum(t for _, _, t in results):.2f}",
    })
    for status, name, seconds in results:
        case = ET.SubElement(suite, "testcase", {
            "classname": package,
            "name": name,
            "time": f"{seconds:.2f}",
        })
        if status == "FAIL":
            ET.SubElement(case, "failure", {"message": f"{name} failed"})
        elif status == "SKIP":
            ET.SubElement(case, "skipped", {})
    return suite, passed, failed, skipped


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <go-test-log> <output-junit-xml>", file=sys.stderr)
        return 1

    log_path, out_path = sys.argv[1], sys.argv[2]
    results, package = parse_log(log_path)
    if not results:
        print(f"No top-level Go test results in {log_path}; not writing a JUnit report",
              file=sys.stderr)
        return 1

    suite, passed, failed, skipped = build_junit(results, package)
    ET.ElementTree(suite).write(out_path, encoding="utf-8", xml_declaration=True)
    print(f"Wrote {out_path}: {len(results)} total, {passed} passed, "
          f"{failed} failed, {skipped} skipped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
