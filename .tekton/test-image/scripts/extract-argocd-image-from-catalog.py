#!/usr/bin/env python3
"""Extract ArgoCD server image from an operator catalog.

Parses a File-Based Catalog (FBC) to find the latest bundle for
openshift-gitops-operator, then extracts the ArgoCD server image
from the bundle's relatedImages in its ClusterServiceVersion.

Environment variables:
  CATALOG_IMAGE   (required) Full catalog image reference
  OPERATOR_CHANNEL          Operator channel (default: latest)
  OPERATOR_NAME             Package name (default: openshift-gitops-operator)

Output:
  Writes image ref to /shared/argocd-image.txt and prints to stdout.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

PULL_CREDS = Path("/quay-pull-credentials/.dockerconfigjson")


def run_cmd(cmd, *, env=None):
    result = subprocess.run(
        cmd, shell=True, capture_output=True, text=True, timeout=300, env=env,
    )
    if result.returncode != 0:
        print(f"Command failed: {cmd}", file=sys.stderr)
        if result.stdout:
            print(result.stdout, file=sys.stderr)
        if result.stderr:
            print(result.stderr, file=sys.stderr)
    return result


def setup_registry_auth(work_dir):
    if not PULL_CREDS.is_file():
        print("WARNING: Pull credentials not found at", PULL_CREDS)
        return None

    print("Configuring registry authentication...")
    auth_dir = Path(work_dir) / "docker-auth"
    auth_dir.mkdir()
    shutil.copy2(PULL_CREDS, auth_dir / "config.json")

    with open(PULL_CREDS) as f:
        creds = json.load(f)
    registries = list(creds.get("auths", {}).keys())
    if "registry.redhat.io" in registries:
        print("  Found registry.redhat.io credentials in pull secret")
    else:
        print("  WARNING: registry.redhat.io NOT found in pull secret")
        print("  Available registries:", ", ".join(registries))

    return str(auth_dir)


def extract_catalog_json(catalog_image, operator_name, work_dir, docker_config):
    extract_dir = Path(work_dir) / "extract"
    extract_dir.mkdir()

    print("Extracting catalog.json...")
    env = dict(os.environ)
    if docker_config:
        env["DOCKER_CONFIG"] = docker_config

    result = run_cmd(
        f"oc image extract {catalog_image}"
        f" --path /configs/{operator_name}/catalog.json:{extract_dir}",
        env=env,
    )
    if result.returncode != 0:
        print(f"ERROR: Failed to extract catalog.json from {catalog_image}")
        sys.exit(1)

    catalog_json = extract_dir / "catalog.json"
    if not catalog_json.is_file() or catalog_json.stat().st_size == 0:
        print("ERROR: catalog.json not found or empty")
        sys.exit(1)

    print(f"Successfully extracted catalog.json ({catalog_json.stat().st_size} bytes)")
    return catalog_json


def parse_fbc_entries(catalog_json):
    """Parse FBC catalog into a list of dicts.

    Handles both NDJSON (one object per line) and pretty-printed
    multi-document JSON (multiple objects concatenated across lines).
    """
    with open(catalog_json) as f:
        raw = f.read()

    decoder = json.JSONDecoder()
    entries = []
    pos = 0
    length = len(raw)
    while pos < length:
        while pos < length and raw[pos] in " \t\n\r":
            pos += 1
        if pos >= length:
            break
        try:
            obj, end = decoder.raw_decode(raw, pos)
            entries.append(obj)
            pos = end
        except json.JSONDecodeError:
            pos += 1

    return entries


def find_bundle_in_catalog(catalog_json, operator_name, channel):
    print(f"Parsing catalog for package: {operator_name}, channel: {channel}")
    entries = parse_fbc_entries(catalog_json)

    channel_entries = [
        e for e in entries
        if e.get("schema") == "olm.channel"
        and e.get("package") == operator_name
        and e.get("name") == channel
    ]

    if not channel_entries:
        print(f"ERROR: Channel {channel} not found for package {operator_name}")
        available = [
            e["name"] for e in entries
            if e.get("schema") == "olm.channel" and e.get("package") == operator_name
        ]
        if available:
            print("Available channels:", ", ".join(available))
        sys.exit(1)

    channel_entry = channel_entries[0]
    entry_list = channel_entry.get("entries", [])
    if not entry_list:
        print("ERROR: No entries in channel")
        sys.exit(1)

    bundle_name = entry_list[-1].get("name") or entry_list[0].get("name")
    if not bundle_name:
        print("ERROR: Channel entries have no bundle name")
        sys.exit(1)
    print(f"Found latest bundle: {bundle_name}")

    bundle_entries = [
        e for e in entries
        if e.get("schema") == "olm.bundle" and e.get("name") == bundle_name
    ]
    if not bundle_entries:
        print(f"ERROR: Could not find bundle entry for {bundle_name}")
        sys.exit(1)

    bundle_image = bundle_entries[0].get("image")
    if not bundle_image:
        print(f"ERROR: No image field in bundle {bundle_name}")
        sys.exit(1)

    print(f"Found bundle image from catalog: {bundle_image}")
    return bundle_name, bundle_image


def remap_bundle_image(bundle_name, bundle_image):
    if not bundle_image.startswith("registry.redhat.io/"):
        return bundle_image

    print("Remapping bundle from registry.redhat.io to Quay...")
    match = re.search(r"\.(v\d+\.\d+\.\d+)", bundle_name)
    if match:
        version = match.group(1)
    else:
        print(f"WARNING: Could not extract version from: {bundle_name}")
        version = bundle_name

    quay_bundle = (
        f"quay.io/redhat-user-workloads/rh-openshift-gitops-tenant"
        f"/gitops-operator-bundle:{version}"
    )
    print(f"  Original: {bundle_image}")
    print(f"  Remapped: {quay_bundle}")
    return quay_bundle


def extract_argocd_image_from_bundle(bundle_image, work_dir, docker_config):
    bundle_dir = Path(work_dir) / "bundle-extract"
    bundle_dir.mkdir()

    print(f"Extracting bundle from: {bundle_image}")
    env = dict(os.environ)
    if docker_config:
        env["DOCKER_CONFIG"] = docker_config

    result = run_cmd(
        f"oc image extract {bundle_image} --path /:{bundle_dir}", env=env,
    )
    if result.returncode != 0:
        print(f"ERROR: Failed to extract bundle from {bundle_image}")
        sys.exit(1)

    manifests = bundle_dir / "manifests"
    if not manifests.is_dir():
        print("ERROR: /manifests directory not found in bundle image")
        sys.exit(1)

    csv_files = list(manifests.glob("*.clusterserviceversion.yaml"))
    if not csv_files:
        print("ERROR: No ClusterServiceVersion found in bundle")
        sys.exit(1)

    csv_file = csv_files[0]
    print(f"Found CSV: {csv_file}")

    with open(csv_file) as f:
        csv_data = yaml.safe_load(f)

    related = csv_data.get("spec", {}).get("relatedImages", [])
    if not related:
        print("ERROR: No relatedImages in CSV")
        sys.exit(1)

    print("Extracting ArgoCD server image from CSV...")

    # Try exact name match first
    for img in related:
        if img.get("name") in ("argocd-server", "argocd"):
            return img["image"]

    # Fall back to image path containing "argocd-rhel" but not agent/extension
    exclude = {"agent", "extension"}
    for img in related:
        image = img.get("image", "")
        if "argocd-rhel" in image and not any(x in image for x in exclude):
            return image

    # Last resort: name contains "argocd" but not agent/extension/rollouts
    exclude_name = {"agent", "extension", "rollouts"}
    for img in related:
        name = img.get("name", "")
        if "argocd" in name and not any(x in name for x in exclude_name):
            return img["image"]

    print("ERROR: Could not extract ArgoCD server image from bundle")
    print("Related images in CSV:")
    for img in related:
        print(f"  {img.get('name', '?')}: {img.get('image', '?')}")
    sys.exit(1)


def main():
    catalog_image = os.environ.get("CATALOG_IMAGE")
    if not catalog_image:
        print("ERROR: CATALOG_IMAGE must be set", file=sys.stderr)
        sys.exit(1)

    channel = os.environ.get("OPERATOR_CHANNEL", "latest")
    operator_name = os.environ.get("OPERATOR_NAME", "openshift-gitops-operator")

    print(f"Extracting ArgoCD image from catalog: {catalog_image}")
    print(f"  Channel: {channel}")
    print(f"  Package: {operator_name}")

    work_dir = tempfile.mkdtemp()
    try:
        docker_config = setup_registry_auth(work_dir)

        catalog_json = extract_catalog_json(
            catalog_image, operator_name, work_dir, docker_config,
        )

        bundle_name, bundle_image = find_bundle_in_catalog(
            catalog_json, operator_name, channel,
        )

        bundle_image = remap_bundle_image(bundle_name, bundle_image)

        argocd_image = extract_argocd_image_from_bundle(
            bundle_image, work_dir, docker_config,
        )

        print(f"Successfully extracted ArgoCD image: {argocd_image}")

        shared = Path("/shared")
        if shared.is_dir():
            (shared / "argocd-image.txt").write_text(argocd_image)
            print("Wrote ArgoCD image to /shared/argocd-image.txt")
        else:
            print("WARNING: /shared directory not found, save-result step may fail")

        print(argocd_image)
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
