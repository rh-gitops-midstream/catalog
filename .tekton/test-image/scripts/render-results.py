#!/usr/bin/env python3
"""Render results.jsonl into a navigable directory of Markdown files.

Directory structure:
    README.md                                   # summary
    gitops-operator/<version>/ocp-<ver>/<variant>/README.md
    argocd/<version>/ocp-<ver>/<variant>/README.md

Variant is one of: default, fips, upgrade, fips-upgrade
"""
import json
import os
import shutil
import sys
from collections import defaultdict

MAX_RUNS = 10

PRODUCT_DIRS = {
    "gitops-operator-e2e": "gitops-operator",
    "argocd-e2e": "argocd",
}


def load_records(repo_dir):
    path = os.path.join(repo_dir, "results.jsonl")
    if not os.path.exists(path):
        return []
    records = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    records.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    return records


def get_version(record):
    csv = record.get("installedCSV", "")
    if csv:
        parts = csv.rsplit(".", 1)
        if len(parts) == 2 and parts[1][0:1] == "v":
            return parts[1]
        elif csv.startswith("gitops-operator."):
            return csv.replace("gitops-operator.", "")
        return csv
    return record.get("argocdVersion", "unknown")


def get_variant(record):
    fips = record.get("fipsEnabled", "false") == "true"
    upgrade = record.get("upgrade", "false") == "true"
    if fips and upgrade:
        return "fips-upgrade"
    if fips:
        return "fips"
    if upgrade:
        return "upgrade"
    return "default"


def get_ocp_version(record):
    return record.get("openshiftVersion", "unknown")


def get_product_dir(record):
    pipeline = record.get("pipeline", "")
    return PRODUCT_DIRS.get(pipeline, pipeline)


def status_icon(record):
    status = record.get("status", "")
    failed_count = record.get("testsFailed", 0)
    if status == "Succeeded":
        return "pass"
    if failed_count:
        return f"FAIL ({failed_count})"
    return "FAIL"


def group_records(records):
    """Group records by product/version/ocp/variant."""
    groups = defaultdict(list)
    for r in records:
        key = (
            get_product_dir(r),
            get_version(r),
            get_ocp_version(r),
            get_variant(r),
        )
        groups[key].append(r)
    for key in groups:
        groups[key].sort(key=lambda r: r.get("timestamp", ""), reverse=True)
    return groups


def render_leaf_readme(records, product, version, ocp, variant):
    title_parts = [product, version, f"OCP {ocp}"]
    if variant != "default":
        title_parts.append(variant.upper())
    title = " / ".join(title_parts)

    lines = [f"# {title}", ""]

    recent = records[:MAX_RUNS]

    lines.append("| Date | Status | Passed | Failed | Skipped | Channel | Logs |")
    lines.append("|------|--------|--------|--------|---------|---------|------|")

    for r in recent:
        ts = r.get("timestamp", "")[:10]
        status = status_icon(r)
        passed = str(r["testsPassed"]) if "testsPassed" in r else "-"
        failed = str(r["testsFailed"]) if "testsFailed" in r else "-"
        skipped_count = str(r["testsSkipped"]) if "testsSkipped" in r else "-"
        channel = r.get("operatorChannel", "")

        log_url = r.get("logUrl", "")
        artifact = r.get("logsArtifact", "")
        logs_parts = []
        if log_url:
            logs_parts.append(f"[UI]({log_url})")
        if artifact:
            logs_parts.append(f"`oras pull {artifact}`")
        logs = " / ".join(logs_parts)

        lines.append(f"| {ts} | {status} | {passed} | {failed} | {skipped_count} | {channel} | {logs} |")

    latest_meta = records[0].get("buildMetadata")
    if latest_meta:
        labels = {
            "build": "Build", "argocd": "Argo CD", "dex": "Dex",
            "redis": "Redis", "kustomize": "Kustomize", "helm": "Helm",
            "gitLfs": "git-lfs", "agent": "Agent",
        }
        meta_parts = [
            f"**{labels.get(k, k)}:** {v}" for k, v in latest_meta.items() if v
        ]
        if meta_parts:
            lines.append("")
            lines.append(f"*Latest component versions:* {' | '.join(meta_parts)}")

    if len(records) > MAX_RUNS:
        lines.append(f"")
        lines.append(f"*Showing {MAX_RUNS} of {len(records)} runs.*")

    lines.append("")
    return "\n".join(lines)


def render_summary_readme(groups):
    lines = ["# Catalog Test Results", ""]

    products = defaultdict(list)
    for (product, version, ocp, variant), records in sorted(groups.items()):
        products[product].append((version, ocp, variant, records))

    for product in sorted(products.keys()):
        lines.append(f"## {product}")
        lines.append("")
        lines.append("| Version | OCP | Variant | Last Run | Status | Channel |")
        lines.append("|---------|-----|---------|----------|--------|---------|")

        for version, ocp, variant, records in sorted(products[product]):
            latest = records[0]
            ts = latest.get("timestamp", "")[:10]
            status = status_icon(latest)
            channel = latest.get("operatorChannel", "")
            link_path = f"{product}/{version}/ocp-{ocp}/{variant}"
            lines.append(
                f"| [{version}]({link_path}/) | {ocp} | {variant} | {ts} | {status} | {channel} |"
            )

        lines.append("")

    lines.append("---")
    lines.append("*Auto-generated by Konflux pipeline.*")
    lines.append("")
    return "\n".join(lines)


def render_mermaid_chart(groups):
    """Render a mermaid timeline of recent runs across all groups."""
    all_records = []
    for records in groups.values():
        all_records.extend(records[:MAX_RUNS])
    if not all_records:
        return ""

    all_records.sort(key=lambda r: r.get("timestamp", ""))
    recent = all_records[-30:]

    dates = []
    pass_counts = defaultdict(int)
    fail_counts = defaultdict(int)
    for r in recent:
        date = r.get("timestamp", "")[:10]
        if date not in dates:
            dates.append(date)
        if r.get("status") == "Succeeded":
            pass_counts[date] += 1
        else:
            fail_counts[date] += 1

    if len(dates) < 2:
        return ""

    lines = [
        "```mermaid",
        "xychart-beta",
        '  title "Pipeline runs (last 30)"',
        f'  x-axis [{", ".join(d[5:] for d in dates)}]',
        f'  y-axis "Runs"',
        f'  bar [{", ".join(str(pass_counts.get(d, 0)) for d in dates)}]',
        f'  bar [{", ".join(str(fail_counts.get(d, 0)) for d in dates)}]',
        "```",
        "",
    ]
    return "\n".join(lines)


def clean_generated_dirs(repo_dir):
    """Remove previously generated product directories."""
    for dirname in PRODUCT_DIRS.values():
        path = os.path.join(repo_dir, dirname)
        if os.path.isdir(path):
            shutil.rmtree(path)


def main():
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <repo-dir>")
        sys.exit(1)

    repo_dir = sys.argv[1]
    records = load_records(repo_dir)
    if not records:
        print("No records found in results.jsonl")
        return

    groups = group_records(records)

    clean_generated_dirs(repo_dir)

    for (product, version, ocp, variant), recs in groups.items():
        leaf_dir = os.path.join(repo_dir, product, version, f"ocp-{ocp}", variant)
        os.makedirs(leaf_dir, exist_ok=True)
        content = render_leaf_readme(recs, product, version, ocp, variant)
        with open(os.path.join(leaf_dir, "README.md"), "w") as f:
            f.write(content)

    summary = render_summary_readme(groups)
    chart = render_mermaid_chart(groups)
    with open(os.path.join(repo_dir, "README.md"), "w") as f:
        f.write(summary)
        if chart:
            f.write(chart)

    print(f"Rendered {len(groups)} result groups from {len(records)} records")


if __name__ == "__main__":
    main()
