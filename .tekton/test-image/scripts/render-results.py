#!/usr/bin/env python3
"""Render results.jsonl into a navigable directory of Markdown files.

Four levels of README are generated so any directory in GitHub shows a
useful at-a-glance summary:

    README.md                                           top-level overview
    {product}/README.md                                 per-version summary
    {product}/{version}/README.md                       per-OCP summary
    {product}/{version}/ocp-{ocp}/README.md             per-config summary
    {product}/{version}/ocp-{ocp}/{variant}/README.md   full run history (leaf)
"""
import json
import os
import re
import shutil
import sys
from collections import defaultdict

MAX_LEAF_RUNS = 10
MAX_HISTORY_ICONS = 4
FAIL_DETAIL_THRESHOLD = 3  # show test names when fewer than this many failures

PRODUCT_DIRS = {
    "gitops-operator-e2e": "gitops-operator",
    "gitops-operator-dast": "gitops-operator-dast",
    "argocd-e2e": "argocd",
}

VARIANTS = ["default", "upgrade", "fips", "fips-upgrade"]


# ── Data loading and grouping ─────────────────────────────────────────────────

def load_records(repo_dir):
    path = os.path.join(repo_dir, "results.jsonl")
    if not os.path.exists(path):
        return []
    records = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return records


def get_version(record):
    csv = record.get("installedCSV", "")
    if csv:
        parts = csv.rsplit(".", 1)
        if len(parts) == 2 and parts[1].startswith("v"):
            return parts[1]
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


def get_product_dir(record):
    return PRODUCT_DIRS.get(record.get("pipeline", ""), record.get("pipeline", "unknown"))


def group_records(records):
    """Return dict (product, version, ocp, variant) -> [records newest-first]."""
    groups = defaultdict(list)
    for r in records:
        key = (
            get_product_dir(r),
            get_version(r),
            r.get("openshiftVersion", "unknown"),
            get_variant(r),
        )
        groups[key].append(r)
    for key in groups:
        groups[key].sort(key=lambda r: r.get("timestamp", ""), reverse=True)
    return groups


# ── Status helpers ────────────────────────────────────────────────────────────

def short_test_name(full_name):
    """Extract a compact identifier from a long test name."""
    # Ginkgo: extract 1-031_validate_toolchain style ID
    m = re.search(r"(\d+-\d+[a-zA-Z0-9_]+)", full_name)
    if m:
        return m.group(1)
    # DAST: "classname/[RISK] Alert Name (alertRef=NNN)" → "[RISK] Alert Name"
    m = re.search(
        r"(\[(?:HIGH|MEDIUM|LOW|INFORMATIONAL)\]\s+[^(]+?)(?:\s+\(alertRef=|\s*$)",
        full_name,
    )
    if m:
        name = m.group(1).strip()
        return (name[:40] + "…") if len(name) > 40 else name
    parts = re.split(r"[/: ]+", full_name)
    last = parts[-1].strip()
    return (last[:35] + "…") if len(last) > 35 else last


def status_cell(record):
    """Rich status cell: shows fail count and test names when < FAIL_DETAIL_THRESHOLD."""
    status = record.get("status", "")
    failed_count = (record.get("testsFailed") or 0) + (record.get("testsErrors") or 0)
    failed_tests = record.get("failedTests", [])

    if status == "Succeeded":
        passed = record.get("testsPassed")
        return f"✅ {passed} pass" if passed is not None else "✅ pass"

    if not failed_count:
        return "❌ ERROR"

    if failed_tests and failed_count < FAIL_DETAIL_THRESHOLD:
        names = ", ".join(short_test_name(t) for t in failed_tests[:failed_count])
        return f"❌ {failed_count} fail: {names}"

    return f"❌ {failed_count} fail"


def status_icon(record):
    """Single icon for history sparklines."""
    return "✅" if record.get("status") == "Succeeded" else "❌"


def history_icons(records, skip=1, n=MAX_HISTORY_ICONS):
    """Compact sparkline of the last n runs (skipping the most recent)."""
    icons = [status_icon(r) for r in records[skip : skip + n]]
    return " ".join(icons) if icons else "—"


def build_meta_line(record):
    """One-liner component version string from buildMetadata."""
    bm = record.get("buildMetadata") or {}
    labels = {
        "build": "Build", "argocd": "Argo CD", "dex": "Dex",
        "redis": "Redis", "kustomize": "Kustomize", "helm": "Helm",
        "gitLfs": "git-lfs", "agent": "Agent",
    }
    parts = [f"**{labels.get(k, k)}:** {v}" for k, v in bm.items() if v]
    return ("*Component versions:* " + " | ".join(parts)) if parts else ""


def version_sort_key(v):
    return [int(x) if x.isdigit() else x for x in re.split(r"[.\-]", v.lstrip("v"))]


# ── Leaf README (full run history) ───────────────────────────────────────────

def render_leaf_readme(records, product, version, ocp, variant):
    parts = [product, version, f"OCP {ocp}"]
    if variant != "default":
        parts.append(variant.upper())

    lines = [f"# {' / '.join(parts)}", ""]
    lines += [
        "| Date | Status | Passed | Failed | Skipped | Channel | Logs |",
        "|------|--------|--------|--------|---------|---------|------|",
    ]
    for r in records[:MAX_LEAF_RUNS]:
        ts = r.get("timestamp", "")[:10]
        st = status_cell(r)
        passed  = str(r["testsPassed"])  if "testsPassed"  in r else "-"
        failed  = str(r["testsFailed"])  if "testsFailed"  in r else "-"
        skipped = str(r["testsSkipped"]) if "testsSkipped" in r else "-"
        channel = r.get("operatorChannel", "")
        log_parts = []
        if r.get("logUrl"):
            log_parts.append(f"[UI]({r['logUrl']})")
        if r.get("logsArtifact"):
            log_parts.append(f"`oras pull {r['logsArtifact']}`")
        lines.append(
            f"| {ts} | {st} | {passed} | {failed} | {skipped} | {channel} | {' / '.join(log_parts)} |"
        )

    meta = build_meta_line(records[0])
    if meta:
        lines += ["", meta]
    if len(records) > MAX_LEAF_RUNS:
        lines += ["", f"*Showing {MAX_LEAF_RUNS} of {len(records)} runs.*"]
    lines.append("")
    return "\n".join(lines)


# ── OCP-level README (config summary for one OCP version) ────────────────────

def render_ocp_readme(variant_map, product, version, ocp):
    """variant_map: {variant: [records newest-first]}"""
    lines = [f"# {product} / {version} / OCP {ocp}", ""]

    for v in VARIANTS:
        if variant_map.get(v):
            meta = build_meta_line(variant_map[v][0])
            if meta:
                lines += [meta, ""]
            break

    lines += [
        "| Config | Channel | Updated | Latest Result | History |",
        "|--------|---------|---------|---------------|---------|",
    ]
    for variant in VARIANTS:
        recs = variant_map.get(variant, [])
        if not recs:
            lines.append(f"| [{variant}](./{variant}/) | — | — | — | — |")
            continue
        latest = recs[0]
        ts = latest.get("timestamp", "")[:10]
        channel = latest.get("operatorChannel", "")
        st = status_cell(latest)
        hist = history_icons(recs)
        lines.append(f"| [{variant}](./{variant}/) | {channel} | {ts} | {st} | {hist} |")

    lines.append("")
    return "\n".join(lines)


# ── Version-level README (OCP summary for one operator version) ───────────────

def render_version_readme(ocp_variant_map, product, version):
    """ocp_variant_map: {(ocp, variant): [records newest-first]}"""
    lines = [f"# {product} / {version}", ""]

    for recs in ocp_variant_map.values():
        if recs:
            meta = build_meta_line(recs[0])
            if meta:
                lines += [meta, ""]
            break

    ocps = sorted({ocp for ocp, _ in ocp_variant_map}, reverse=True)
    present_variants = [v for v in VARIANTS if any((ocp, v) in ocp_variant_map for ocp in ocps)]

    col_hdr = " | ".join(f"**{v}**" for v in present_variants)
    sep = " | ".join(["---"] * (2 + len(present_variants)))
    lines += [f"| OCP | {col_hdr} | Updated |", f"| {sep} |"]

    for ocp in ocps:
        cells, latest_ts = [], ""
        for variant in present_variants:
            recs = ocp_variant_map.get((ocp, variant), [])
            if not recs:
                cells.append("—")
            else:
                cells.append(status_cell(recs[0]))
                ts = recs[0].get("timestamp", "")
                if ts > latest_ts:
                    latest_ts = ts
        lines.append(f"| [{ocp}](./ocp-{ocp}/) | {' | '.join(cells)} | {latest_ts[:10]} |")

    lines.append("")
    return "\n".join(lines)


# ── Product-level README (version summary) ────────────────────────────────────

def render_product_readme(prod_groups, product):
    """prod_groups: {(version, ocp, variant): [records newest-first]}"""
    lines = [f"# {product}", ""]

    versions = sorted(
        {version for version, _, _ in prod_groups},
        key=version_sort_key,
        reverse=True,
    )

    for version in versions:
        ocps = sorted(
            {ocp for v, ocp, _ in prod_groups if v == version},
            reverse=True,
        )
        present_variants = [
            var for var in VARIANTS
            if any((version, ocp, var) in prod_groups for ocp in ocps)
        ]

        col_hdr = " | ".join(f"**{v}**" for v in present_variants)
        sep = " | ".join(["---"] * (3 + len(present_variants)))

        lines += [
            f"## [{version}](./{version}/)",
            "",
            f"| OCP | {col_hdr} | ArgoCD | Updated |",
            f"| {sep} |",
        ]

        for ocp in ocps:
            cells, latest_ts, argocd_ver = [], "", ""
            for variant in present_variants:
                recs = prod_groups.get((version, ocp, variant), [])
                if not recs:
                    cells.append("—")
                else:
                    cells.append(status_cell(recs[0]))
                    ts = recs[0].get("timestamp", "")
                    if ts > latest_ts:
                        latest_ts = ts
                    if not argocd_ver:
                        argocd_ver = (recs[0].get("buildMetadata") or {}).get("argocd", "")
            lines.append(
                f"| [{ocp}](./{version}/ocp-{ocp}/) | {' | '.join(cells)} | {argocd_ver} | {latest_ts[:10]} |"
            )

        lines.append("")

    lines += ["---", "*Auto-generated by Konflux pipeline.*", ""]
    return "\n".join(lines)


# ── Top-level README ──────────────────────────────────────────────────────────

def render_top_readme(all_groups):
    lines = ["# Catalog Test Results", ""]

    # Nest: product -> version -> ocp -> variant -> records
    tree = defaultdict(lambda: defaultdict(lambda: defaultdict(dict)))
    for (product, version, ocp, variant), recs in all_groups.items():
        tree[product][version][ocp][variant] = recs

    for product in sorted(tree):
        lines.append(f"## [{product}](./{product}/)")
        lines.append("")
        versions = sorted(tree[product], key=version_sort_key, reverse=True)
        for version in versions[:3]:
            for ocp in sorted(tree[product][version], reverse=True):
                variant_data = tree[product][version][ocp]
                parts, latest_ts = [], ""
                for var in VARIANTS:
                    recs = variant_data.get(var, [])
                    if recs:
                        parts.append(f"{var}: {status_icon(recs[0])}")
                        ts = recs[0].get("timestamp", "")
                        if ts > latest_ts:
                            latest_ts = ts
                summary = " · ".join(parts)
                lines.append(
                    f"- **[{version} / OCP {ocp}](./{product}/{version}/ocp-{ocp}/)** "
                    f"— {summary} *(updated {latest_ts[:10]})*"
                )
        lines.append("")

    lines += ["---", "*Auto-generated by Konflux pipeline.*", ""]
    return "\n".join(lines)


# ── Main ──────────────────────────────────────────────────────────────────────

def clean_generated_dirs(repo_dir):
    for dirname in set(PRODUCT_DIRS.values()):
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

    all_groups = group_records(records)
    clean_generated_dirs(repo_dir)

    by_product = defaultdict(dict)
    for (product, version, ocp, variant), recs in all_groups.items():
        by_product[product][(version, ocp, variant)] = recs

    total_groups = 0
    for product, prod_groups in by_product.items():
        # Leaf READMEs
        for (version, ocp, variant), recs in prod_groups.items():
            leaf_dir = os.path.join(repo_dir, product, version, f"ocp-{ocp}", variant)
            os.makedirs(leaf_dir, exist_ok=True)
            with open(os.path.join(leaf_dir, "README.md"), "w") as f:
                f.write(render_leaf_readme(recs, product, version, ocp, variant))
            total_groups += 1

        # OCP-level READMEs
        ocp_buckets = defaultdict(dict)
        for (version, ocp, variant), recs in prod_groups.items():
            ocp_buckets[(version, ocp)][variant] = recs
        for (version, ocp), variant_map in ocp_buckets.items():
            ocp_dir = os.path.join(repo_dir, product, version, f"ocp-{ocp}")
            with open(os.path.join(ocp_dir, "README.md"), "w") as f:
                f.write(render_ocp_readme(variant_map, product, version, ocp))

        # Version-level READMEs
        ver_buckets = defaultdict(dict)
        for (version, ocp, variant), recs in prod_groups.items():
            ver_buckets[version][(ocp, variant)] = recs
        for version, ocp_variant_map in ver_buckets.items():
            ver_dir = os.path.join(repo_dir, product, version)
            with open(os.path.join(ver_dir, "README.md"), "w") as f:
                f.write(render_version_readme(ocp_variant_map, product, version))

        # Product-level README
        prod_dir = os.path.join(repo_dir, product)
        with open(os.path.join(prod_dir, "README.md"), "w") as f:
            f.write(render_product_readme(prod_groups, product))

    # Top-level README
    with open(os.path.join(repo_dir, "README.md"), "w") as f:
        f.write(render_top_readme(all_groups))

    print(f"Rendered {total_groups} result groups from {len(records)} records")


if __name__ == "__main__":
    main()
