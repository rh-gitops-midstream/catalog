from ruamel.yaml import YAML
from pathlib import Path
import os
import sys, re

yaml = YAML()
yaml.preserve_quotes = True
yaml.width = 100000
yaml.indent(mapping=2, sequence=2, offset=0)

REPO_ROOT = Path(__file__).resolve().parent
CONFIG_FILE = REPO_ROOT / "config.yaml"
CATALOG_DIR = REPO_ROOT / "catalog"


def load_yaml_file(path):
    with open(path, 'r') as f:
        return yaml.load(f)


def write_yaml_file(path, data):
    with open(path, 'w') as f:
        yaml.dump(data, f)


def load_catalog_templates(supported_ocp):
    templates = []
    for ocp in supported_ocp:
        path = CATALOG_DIR / ocp / "template.yaml"
        if not path.exists():
            print(f"Missing template for {ocp}")
            sys.exit(1)
        templates.append(path)
    return templates


def update_channel_entries(entries, name, replaces, skip_range):
    version_entry = {
        "name": name,
        "replaces": replaces,
    }
    if skip_range:
        version_entry["skipRange"] = skip_range

    def upsert(entry_list):
        for e in entry_list:
            if e.get("name") == name:
                e.update(version_entry)
                return
        entry_list.append(version_entry.copy())

    return upsert


def get_or_create_channel(entries, channel_name):
    for e in entries:
        if e.get("schema") == "olm.channel" and e.get("name") == channel_name:
            return e
    new_channel = {
        "name": channel_name,
        "package": "openshift-gitops-operator",
        "schema": "olm.channel",
        "entries": [],
    }
    entries.append(new_channel)
    return new_channel


def ensure_bundle_image(entries, bundle_image):
    for e in entries:
        if e.get("schema") == "olm.bundle" and e.get("image") == bundle_image:
            return
    entries.append({
        "schema": "olm.bundle",
        "image": bundle_image,
    })


def process_template(template_path, channel, version, allowed_images, latest_channel):
    template = load_yaml_file(template_path)
    entries = template.setdefault("entries", [])

    channel_name = channel.get("name", "")
    name = version.get("name", "")
    replaces = version.get("replaces", "")
    skip_range = version.get("skipRange", "")
    bundle = version.get("bundle", "")

    allowed_images.add(bundle)

    update_entry = update_channel_entries(entries, name, replaces, skip_range)

    # Update specified and latest channel(only if latest version)
    channels = [channel_name]
    if channel_name == latest_channel:
        channels.append("latest")
    for ch_name in channels:
        ch = get_or_create_channel(entries, ch_name)
        update_entry(ch["entries"])

    # Add bundle image entry
    ensure_bundle_image(entries, bundle)

    write_yaml_file(template_path, template)


def remove_old_images(template_path, allowed_images):
    template = load_yaml_file(template_path)
    entries = template.get("entries", [])
    original_len = len(entries)

    entries[:] = [
        e for e in entries
        if not (
            e.get("schema") == "olm.bundle"
            and e.get("image", "").startswith("quay.io/")
            and e.get("image") not in allowed_images
        )
    ]

    if len(entries) < original_len:
        print(f"Cleaned old bundle images in: {template_path.name}")
        write_yaml_file(template_path, template)

def latest_y_stream_channel(channels):
    """
    Given a list of Y-stream strings like ['gitops-1.15', 'gitops-1.16'],
    return the latest one.
    """
    def parse(v):
        # Extract major, minor as integers
        _, ver = v.split('-')
        major, minor = map(int, ver.split('.'))
        return major, minor
    return max(channels, key=parse)


def main():
    config = load_yaml_file(CONFIG_FILE)
    supported_ocp = config.get("supportedOCP", [])
    channels = config.get("channels", [])

    template_paths = load_catalog_templates(supported_ocp)
    allowed_images = set()

    channel_names = []
    for channel in channels:
        channel_names.append(channel.get("name", ""))
    latest_channel_name = latest_y_stream_channel(channel_names)

    for channel in channels:
        for version in channel.get("versions", []):
            for template_path in template_paths:
                process_template(template_path, channel, version, allowed_images, latest_channel_name)

    for template_path in template_paths:
        remove_old_images(template_path, allowed_images)

# TODO: fetch latest catalog from redhat instead of using local templates
if __name__ == "__main__":
    main()
