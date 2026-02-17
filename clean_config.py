#!/usr/bin/env python3
import argparse
import sys
from pathlib import Path
from typing import Dict, List, Set, Tuple

from ruamel.yaml import YAML

ROOT = Path(__file__).resolve().parent
CONFIG_PATH = ROOT / "config.yaml"
TEMPLATE_GLOB = "catalog/**/template.yaml"


def load_config() -> Tuple[YAML, dict]:
    yaml = YAML()
    yaml.preserve_quotes = True
    yaml.indent(mapping=2, sequence=4, offset=2)
    yaml.width = 4096
    with CONFIG_PATH.open("r", encoding="utf-8") as handle:
        data = yaml.load(handle)
    return yaml, data


def find_channel(channels: List[dict], channel_name: str) -> Tuple[int, dict]:
    for index, channel in enumerate(channels or []):
        if channel.get("name") == channel_name:
            return index, channel
    return -1, {}


def collect_quay_bundles(channel: dict) -> Dict[str, str]:
    replacements: Dict[str, str] = {}
    for version in channel.get("versions", []):
        bundle = version.get("bundle")
        if isinstance(bundle, str) and bundle.startswith("quay.io/"):
            replacements[bundle] = bundle.replace("quay.io/redhat-user-workloads/rh-openshift-gitops-tenant/", "registry.redhat.io/openshift-gitops-1/", 1)
    return replacements


def replace_in_templates(replacements: Dict[str, str]) -> Tuple[int, int]:
    if not replacements:
        return 0, 0
    files_changed = 0
    total_replacements = 0
    for path in ROOT.glob(TEMPLATE_GLOB):
        text = path.read_text(encoding="utf-8")
        original = text
        for old, new in replacements.items():
            if old in text:
                text = text.replace(old, new)
        if text != original:
            files_changed += 1
            total_replacements += sum(original.count(old) for old in replacements)
            path.write_text(text, encoding="utf-8")
    return files_changed, total_replacements


def remove_channel(config: dict, channel_index: int) -> None:
    channels = config.get("channels") or []
    channels.pop(channel_index)
    config["channels"] = channels


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Replace quay.io bundle references for a channel in catalog templates "
            "and remove the channel from config.yaml."
        )
    )
    parser.add_argument("channel", help="Channel name to remove from config.yaml")
    args = parser.parse_args()

    if not CONFIG_PATH.exists():
        print(f"Error: {CONFIG_PATH} not found.", file=sys.stderr)
        return 1

    yaml, config = load_config()
    channels = config.get("channels")
    if not isinstance(channels, list):
        print("Error: config.yaml has no channels list.", file=sys.stderr)
        return 1

    channel_index, channel = find_channel(channels, args.channel)
    if channel_index == -1:
        print(f"Error: channel '{args.channel}' not found in config.yaml.", file=sys.stderr)
        return 1

    replacements = collect_quay_bundles(channel)
    files_changed, total_replacements = replace_in_templates(replacements)

    remove_channel(config, channel_index)
    with CONFIG_PATH.open("w", encoding="utf-8") as handle:
        yaml.dump(config, handle)

    print(
        "Done: removed channel '{channel}'. Updated {files} template file(s) "
        "with {replacements} replacement(s).".format(
            channel=args.channel,
            files=files_changed,
            replacements=total_replacements,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
