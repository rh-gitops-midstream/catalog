#!/usr/bin/env python3
"""Split one suite's failures into new and known, for the release run's Slack summary.

Usage: classify-failures.py <known-failures.yaml> <counts.json> <suite> <channel> <ocp>

<known-failures.yaml> is the hand-maintained list in rh-gitops-release-qa/catalog-results
(see the comment at the top of that file for its format). Either file may be missing: no
list means every failure is new, no counts means the suite reported no test names and only
a suite-wide entry can mark it known.

Prints tab-separated lines, each starting with a tab so the summary can tell them from the
suite line they belong to:

    <TAB>new<TAB><short name>          at most MAX_NEW of these
    <TAB>new-more<TAB><count>          the new failures not listed
    <TAB>known<TAB><count><TAB><reasons>
    <TAB>known-suite<TAB><reason>      a nameless failure covered by a suite-wide entry

Capped because this travels as a Tekton result, which is limited to a few KB per task, and
ends up in a Slack message. The full list is in the suite's row in catalog-results.
"""

import datetime
import json
import os
import re
import sys

MAX_NEW = 5
MAX_NAME = 80
MAX_REASONS = 3


def load_known(path):
    if not os.path.isfile(path):
        return []
    import yaml  # only needed when there is a list to read

    with open(path) as f:
        data = yaml.safe_load(f) or {}
    entries = data.get("knownFailures", []) if isinstance(data, dict) else data
    return [e for e in entries or [] if isinstance(e, dict) and e.get("reason")]


def one_line(s):
    return " ".join(str(s).split())


def as_list(v):
    if v is None:
        return []
    return [str(x) for x in (v if isinstance(v, list) else [v])]


def short_name(name):
    """The part of a test name a person recognises.

    Ginkgo names carry the whole describe chain ("GitOps Operator Parallel E2E Tests
    1-031_validate_toolchain [It] verifies that ..."); the kuttl-style test id is the useful
    bit. Go test names are already short.
    """
    m = re.search(r"\b\d+-\d{3}_[A-Za-z0-9_-]+", name)
    if m:
        return m.group(0)
    name = name.split("[It] ", 1)[-1].strip()
    return name if len(name) <= MAX_NAME else name[: MAX_NAME - 1] + "…"


def applies(entry, suite, channel, ocp, today):
    if entry.get("expires") and str(entry["expires"]) < today:
        return False
    suites = [s.removesuffix(".sh") for s in as_list(entry.get("suite"))]
    if suites and suite.removesuffix(".sh") not in suites:
        return False
    if as_list(entry.get("channels")) and channel not in as_list(entry.get("channels")):
        return False
    if as_list(entry.get("ocp")) and ocp not in as_list(entry.get("ocp")):
        return False
    return True


def matches(entry, name):
    if entry.get("test") is not None:
        return str(entry["test"]) in (name, short_name(name))
    if entry.get("pattern") is not None:
        return re.search(str(entry["pattern"]), name) is not None
    return True  # suite-wide entry


def main():
    if len(sys.argv) != 6:
        print(__doc__, file=sys.stderr)
        sys.exit(1)
    known_path, counts_path, suite, channel, ocp = sys.argv[1:]
    today = datetime.date.today().isoformat()

    try:
        entries = [e for e in load_known(known_path) if applies(e, suite, channel, ocp, today)]
    except Exception as e:  # a broken list must not hide the failures
        print(f"could not read {known_path}: {e}", file=sys.stderr)
        entries = []

    failed = []
    if os.path.isfile(counts_path):
        with open(counts_path) as f:
            failed = json.load(f).get("failedTests", []) or []

    if not failed:
        wide = [e for e in entries if e.get("test") is None and e.get("pattern") is None]
        if wide:
            print(f"\tknown-suite\t{one_line(wide[0]['reason'])}")
        return

    new, known_reasons, known_count = [], [], 0
    for name in failed:
        hit = next((e for e in entries if matches(e, name)), None)
        if hit is None:
            new.append(short_name(name))
        else:
            known_count += 1
            reason = one_line(hit["reason"])
            if reason not in known_reasons:
                known_reasons.append(reason)

    for name in new[:MAX_NEW]:
        print(f"\tnew\t{name}")
    if len(new) > MAX_NEW:
        print(f"\tnew-more\t{len(new) - MAX_NEW}")
    if known_count:
        reasons = "; ".join(known_reasons[:MAX_REASONS])
        if len(known_reasons) > MAX_REASONS:
            reasons += f"; +{len(known_reasons) - MAX_REASONS} more"
        print(f"\tknown\t{known_count}\t{reasons}")


if __name__ == "__main__":
    main()
