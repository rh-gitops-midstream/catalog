#!/usr/bin/env python3
"""Parse RapidAST/ZAP JSON scan results into JUnit XML.

Usage: parse-dast-results.py <results-dir> <output-junit-xml>

Reads /usr/local/config/dast-false-positives.json for alert thresholds and
suppression rules. Exits 0 if all unsuppressed alerts are within threshold,
1 if any exceed the threshold.

Output JUnit XML format:
  One testcase per ZAP alert type.
  Suppressed (false-positive) alerts → skipped.
  Alerts within threshold → pass.
  Alerts exceeding threshold → failure.
"""

import glob
import json
import os
import sys
import xml.etree.ElementTree as ET

CONFIG_PATH = "/usr/local/config/dast-false-positives.json"

DEFAULT_THRESHOLDS = {
    "high": 0,
    "medium": 10,
    "low": 9999,
    "informational": 9999,
}

RISK_NAMES = {0: "informational", 1: "low", 2: "medium", 3: "high"}


def load_config():
    if not os.path.exists(CONFIG_PATH):
        print(f"WARNING: {CONFIG_PATH} not found, using defaults", file=sys.stderr)
        return {"thresholds": DEFAULT_THRESHOLDS, "falsePositives": []}
    with open(CONFIG_PATH) as f:
        cfg = json.load(f)
    thresholds = cfg.get("thresholds", {})
    for key, default in DEFAULT_THRESHOLDS.items():
        thresholds.setdefault(key, default)
    cfg["thresholds"] = thresholds
    cfg.setdefault("falsePositives", [])
    return cfg


def is_false_positive(alert, fp_rules):
    alert_ref = str(alert.get("alertRef", alert.get("pluginid", "")))
    for rule in fp_rules:
        if str(rule.get("alertRef", "")) != alert_ref:
            continue
        url_filter = rule.get("url", "")
        if not url_filter:
            return True, rule.get("reason", "suppressed")
        for inst in alert.get("instances", []):
            if url_filter in inst.get("uri", ""):
                return True, rule.get("reason", "suppressed")
    return False, ""


def find_zap_json(results_dir):
    for pattern in [
        os.path.join(results_dir, "rapidast-*", "zap", "zap-report.json"),
        os.path.join(results_dir, "*", "zap-report.json"),
        os.path.join(results_dir, "zap-report.json"),
    ]:
        matches = sorted(glob.glob(pattern))
        if matches:
            return matches[-1]
    return None


def parse_alerts(zap_json_path, fp_rules, thresholds):
    with open(zap_json_path) as f:
        data = json.load(f)

    all_alerts = []
    for site in data.get("site", []):
        all_alerts.extend(site.get("alerts", []))

    results = []
    for alert in all_alerts:
        risk_code = int(alert.get("riskcode", 0))
        risk_name = RISK_NAMES.get(risk_code, "informational")
        threshold = thresholds.get(risk_name, 9999)
        count = int(alert.get("count", len(alert.get("instances", []))))
        fp, fp_reason = is_false_positive(alert, fp_rules)
        results.append({
            "name": alert.get("name", alert.get("alert", "Unknown")),
            "alertRef": str(alert.get("alertRef", alert.get("pluginid", ""))),
            "riskName": risk_name,
            "count": count,
            "threshold": threshold,
            "isFalsePositive": fp,
            "fpReason": fp_reason,
            "fails": not fp and count > threshold,
            "instances": [i.get("uri", "") for i in alert.get("instances", [])[:5]],
        })
    return results


def write_junit(results, output_path):
    total = len(results)
    failures = sum(1 for r in results if r["fails"])
    skipped = sum(1 for r in results if r["isFalsePositive"])

    root = ET.Element("testsuites")
    suite = ET.SubElement(root, "testsuite", {
        "name": "DAST Scan",
        "tests": str(total),
        "failures": str(failures),
        "errors": "0",
        "skipped": str(skipped),
    })

    for r in results:
        tc = ET.SubElement(suite, "testcase", {
            "name": f"[{r['riskName'].upper()}] {r['name']} (alertRef={r['alertRef']})",
            "classname": f"dast.{r['riskName']}",
        })
        if r["isFalsePositive"]:
            ET.SubElement(tc, "skipped", message=f"Suppressed: {r['fpReason']}")
        elif r["fails"]:
            detail = (
                f"Alert count {r['count']} exceeds threshold {r['threshold']}\n"
                f"Risk: {r['riskName'].upper()}  AlertRef: {r['alertRef']}\n"
                f"Instances (first {len(r['instances'])}):\n"
                + "\n".join(f"  {u}" for u in r["instances"])
            )
            ET.SubElement(tc, "failure", {
                "message": f"count={r['count']} > threshold={r['threshold']}",
            }).text = detail

    ET.ElementTree(root).write(output_path, encoding="unicode", xml_declaration=True)
    return failures


def write_error_junit(output_path, message):
    root = ET.Element("testsuites")
    suite = ET.SubElement(root, "testsuite",
                          {"name": "DAST Scan", "tests": "1", "failures": "1",
                           "errors": "0", "skipped": "0"})
    tc = ET.SubElement(suite, "testcase",
                       {"name": "ZAP results", "classname": "dast"})
    ET.SubElement(tc, "failure", {"message": message}).text = message
    ET.ElementTree(root).write(output_path, encoding="unicode", xml_declaration=True)


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <results-dir> <output-junit-xml>", file=sys.stderr)
        sys.exit(1)

    results_dir, output_path = sys.argv[1], sys.argv[2]

    cfg = load_config()
    thresholds = cfg["thresholds"]
    fp_rules = cfg["falsePositives"]
    print(f"Thresholds: {thresholds}")
    print(f"Suppression rules: {len(fp_rules)}")

    zap_json = find_zap_json(results_dir)
    if not zap_json:
        msg = f"No zap-report.json found in {results_dir}"
        print(f"ERROR: {msg}", file=sys.stderr)
        write_error_junit(output_path, msg)
        sys.exit(1)

    print(f"Parsing: {zap_json}")
    results = parse_alerts(zap_json, fp_rules, thresholds)
    failures = write_junit(results, output_path)

    passed = sum(1 for r in results if not r["fails"] and not r["isFalsePositive"])
    suppressed = sum(1 for r in results if r["isFalsePositive"])
    print(f"Alert types: {len(results)} total — "
          f"{passed} within threshold, {failures} exceeded, {suppressed} suppressed")

    if failures > 0:
        print(f"\nFailed alerts ({failures}):")
        for r in results:
            if r["fails"]:
                print(f"  [{r['riskName'].upper()}] {r['name']} "
                      f"count={r['count']} threshold={r['threshold']}")

    sys.exit(0 if failures == 0 else 1)


if __name__ == "__main__":
    main()
