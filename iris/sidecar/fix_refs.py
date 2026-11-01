"""Strip Synthea's conditional references so resources load standalone.

Synthea writes references like

    "location": {"reference": "Location?identifier=https://github.com/
                               synthetichealth/synthea|051f1013-..."}

That form is legal inside a FHIR *transaction bundle*, where the server resolves
it during processing. Posting the same resource on its own is rejected:

    400  <HSFHIRErr>MalformedRelativeReference
    "The reference value 'Location?identifier=...' in property (location) of
     Type 'Immunization' is malformed"

IRIS refused 100% of Immunization, Encounter, Procedure and MedicationRequest
for this reason while reporting "Completed successfully".

We drop any reference whose value contains '?' -- i.e. the conditional ones --
and leave ordinary 'Type/id' references intact. The fields affected (location,
and a few others) are not read by the agent, whose queries need FactType, Code,
PatientId and FactDate.

Usage:  python3 fix_refs.py <in_dir> <out_dir>
"""
from __future__ import annotations

import json
import os
import sys

# Resource types that failed to load; the other four are already in.
WANTED = ("Immunization", "Encounter", "Procedure", "MedicationRequest")


def clean(node):
    """Recursively drop conditional references. Returns (node, n_removed)."""
    removed = 0
    if isinstance(node, dict):
        out = {}
        for key, val in node.items():
            # a Reference object whose .reference is conditional
            if (
                key == "reference"
                and isinstance(val, str)
                and "?" in val
            ):
                removed += 1
                continue
            cleaned, n = clean(val)
            removed += n
            # drop a Reference that is now empty of anything useful
            if isinstance(cleaned, dict) and not cleaned:
                continue
            out[key] = cleaned
        return out, removed
    if isinstance(node, list):
        items = []
        for val in node:
            cleaned, n = clean(val)
            removed += n
            if isinstance(cleaned, dict) and not cleaned:
                continue
            items.append(cleaned)
        return items, removed
    return node, removed


def main() -> int:
    src, dst = sys.argv[1], sys.argv[2]
    os.makedirs(dst, exist_ok=True)
    total_lines = total_removed = 0

    for name in sorted(os.listdir(src)):
        if not name.endswith(".ndjson"):
            continue
        rtype = name.split(".")[0].split("_")[0]
        if rtype not in WANTED:
            continue

        lines = 0
        removed = 0
        with open(os.path.join(src, name), encoding="utf-8", errors="replace") as fin, \
             open(os.path.join(dst, name), "w", encoding="utf-8") as fout:
            for line in fin:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                obj, n = clean(obj)
                removed += n
                fout.write(json.dumps(obj, separators=(",", ":")) + "\n")
                lines += 1

        total_lines += lines
        total_removed += removed
        print(f"  {name}: {lines} resources, {removed} conditional refs dropped")

    print(f"total: {total_lines} resources, {total_removed} conditional refs dropped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
