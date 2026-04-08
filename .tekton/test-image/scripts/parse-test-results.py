#!/usr/bin/env python3
"""Parse JUnit XML test results into a structured JSON file.

Usage: parse-test-results.py <junit-xml-path> <output-json-path>

Output JSON format:
  {
    "total": 45,
    "passed": 43,
    "failed": 2,
    "skipped": 0,
    "errors": 0,
    "failedTests": ["TestFoo", "TestBar/subtest"],
    "summary": "45 total, 43 passed, 2 failed, 0 skipped, 0 errors"
  }
"""

import json
import sys
import xml.etree.ElementTree as ET


def parse_junit(junit_path):
    tree = ET.parse(junit_path)
    root = tree.getroot()

    if root.tag == "testsuites":
        suites = list(root)
    elif root.tag == "testsuite":
        suites = [root]
    else:
        suites = [root]

    total = 0
    failures = 0
    errors = 0
    skipped = 0
    failed_tests = []

    for suite in suites:
        total += int(suite.get("tests", 0))
        failures += int(suite.get("failures", 0))
        errors += int(suite.get("errors", 0))
        skipped += int(suite.get("skipped", 0))

        for tc in suite.iter("testcase"):
            has_failure = tc.find("failure") is not None
            has_error = tc.find("error") is not None
            if has_failure or has_error:
                name = tc.get("name", "unknown")
                classname = tc.get("classname", "")
                if classname and classname != name:
                    failed_tests.append(f"{classname}/{name}")
                else:
                    failed_tests.append(name)

    passed = total - failures - errors - skipped
    if passed < 0:
        passed = 0

    summary = (
        f"{total} total, {passed} passed, {failures} failed, "
        f"{skipped} skipped, {errors} errors"
    )

    return {
        "total": total,
        "passed": passed,
        "failed": failures,
        "skipped": skipped,
        "errors": errors,
        "failedTests": failed_tests,
        "summary": summary,
    }


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <junit-xml> <output-json>", file=sys.stderr)
        sys.exit(1)

    junit_path = sys.argv[1]
    output_path = sys.argv[2]

    try:
        results = parse_junit(junit_path)
    except ET.ParseError as e:
        print(f"ERROR: Failed to parse JUnit XML: {e}", file=sys.stderr)
        results = {
            "total": 0, "passed": 0, "failed": 0, "skipped": 0, "errors": 0,
            "failedTests": [], "summary": "0 total (XML parse error)",
        }

    with open(output_path, "w") as f:
        json.dump(results, f, indent=2)

    print(f"Test results: {results['summary']}")
    if results["failedTests"]:
        print(f"Failed tests ({len(results['failedTests'])}):")
        for name in results["failedTests"][:20]:
            print(f"  - {name}")
        if len(results["failedTests"]) > 20:
            print(f"  ... and {len(results['failedTests']) - 20} more")


if __name__ == "__main__":
    main()
