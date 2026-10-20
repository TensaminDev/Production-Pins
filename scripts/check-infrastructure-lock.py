#!/usr/bin/env python3
"""Reject unrelated lock updates and verify the selected immutable pins."""

import json
import sys
from pathlib import Path

before_path, after_path, selected, revision = sys.argv[1:]
before = json.loads(Path(before_path).read_text())
after = json.loads(Path(after_path).read_text())


def require(condition, message):
    if not condition:
        sys.exit(message)


def resolve(lock, reference):
    if isinstance(reference, str):
        return reference
    node = lock["root"]
    for name in reference:
        node = resolve(lock, lock["nodes"][node]["inputs"][name])
    return node


def same_graph(old_reference, new_reference, seen=None):
    if seen is None:
        seen = set()
    old_name = resolve(before, old_reference)
    new_name = resolve(after, new_reference)
    pair = (old_name, new_name)
    if pair in seen:
        return True
    seen.add(pair)
    old_node, new_node = before["nodes"][old_name], after["nodes"][new_name]
    if ({key: value for key, value in old_node.items() if key != "inputs"}
            != {key: value for key, value in new_node.items() if key != "inputs"}):
        return False
    old_children, new_children = old_node.get("inputs", {}), new_node.get("inputs", {})
    return old_children.keys() == new_children.keys() and all(
        same_graph(old_children[name], new_children[name], seen) for name in old_children)


require(before["version"] == after["version"], "Lock format changed unexpectedly")
require(before["root"] == after["root"], "Lock root changed unexpectedly")
old_inputs = before["nodes"][before["root"]]["inputs"]
new_inputs = after["nodes"][after["root"]]["inputs"]
require(old_inputs.keys() == new_inputs.keys(), "Infrastructure inputs changed unexpectedly")
for name in old_inputs:
    if name != selected:
        # Nix may rename deduplicated nodes during a targeted update. Compare
        # resolved dependency graphs, not those incidental node identifiers.
        require(same_graph(old_inputs[name], new_inputs[name]),
                f"Unrelated input or shared dependency changed: {name}")
locked = after["nodes"][resolve(after, new_inputs[selected])]["locked"]
require(
    locked.get("type") == "github"
    and locked.get("owner") == "TensaminDev"
    and locked.get("repo") == "Production-Pins"
    and locked.get("rev") == revision,
    "Selected channel does not lock the requested Production-Pins commit",
)
