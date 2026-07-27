#!/usr/bin/env python3
"""SPEC 9 register-map completeness check (issue #19).

Cross-checks the generated register map against the manifest of expected §9
groups; fails if any group is missing, undocumented, or claimed by no block.

Also asserts that every register in every block has a non-empty description --
the argument that the map is DOCUMENTED and not just present.

Called by `make regmap-completeness` (which is a prerequisite of `make sim-tiny`,
matching the existing `make regmap-check`).
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
SPEC9_GROUPS = [
    "Global identification",
    "Build parameters",
    "Per-block enable and reset",
    "Coefficient and weight programming",
    "Active bank selection",
    "CFAR settings",
    "Integration settings",
    "Stream counters",
    "Stall counters",
    "FIFO high-water marks",
    "Overflow and saturation counts",
    "Frame counts",
    "Sequence errors",
    "CDC errors",
    "Fault injection",
    "Snapshot and debug control",
]


class Fail(Exception):
    pass


def load_source_of_truth() -> dict:
    path = REPO_ROOT / "control" / "regmap.json"
    if not path.is_file():
        raise Fail(f"source of truth not found at {path}")
    with path.open("r", encoding="utf-8") as fh:
        return json.load(fh)


def main() -> int:
    print("=== test_regmap_completeness (issue #19) ===")
    try:
        doc = load_source_of_truth()
    except Fail as e:
        print(f"FAIL: {e}", file=sys.stderr)
        return 1

    blocks = doc.get("blocks", [])
    if not blocks:
        print("FAIL: no blocks declared in the register map", file=sys.stderr)
        return 1

    errors: list[str] = []

    # 1. Every SPEC §9 group must be claimed by at least one block, and that
    #    block must be IMPLEMENTED (i.e. the group is not just planned).
    claimed_groups: dict[str, list[str]] = {}
    for b in blocks:
        for g in b.get("spec_groups", []):
            claimed_groups.setdefault(g, []).append(b["name"])
    for group in SPEC9_GROUPS:
        if group not in claimed_groups:
            errors.append(f"SPEC 9 group not claimed by any block: {group!r}")
            continue
        # At least one claim must be by an implemented block.
        impls = [b for b in blocks
                 if b["name"] in claimed_groups[group] and b.get("implemented", False)]
        if not impls:
            errors.append(
                f"SPEC 9 group {group!r} claimed only by planned blocks: "
                f"{claimed_groups[group]}"
            )
        else:
            names = ", ".join(sorted(b["name"] for b in impls))
            print(f"  [ok] {group:<40s} <- {names}")

    # 2. Every implemented block must have at least one register.
    for b in blocks:
        if b.get("implemented", False) and not b.get("registers", []):
            errors.append(
                f"block '{b['name']}' is implemented but has no registers"
            )

    # 3. Every register must have a non-empty description AND every field.
    reg_count = 0
    field_count = 0
    for b in blocks:
        if not b.get("implemented", False):
            continue
        for r in b.get("registers", []):
            reg_count += 1
            if not r.get("description", "").strip():
                errors.append(
                    f"register {b['name']}.{r['name']} has an empty description"
                )
            for f in r.get("fields", []):
                field_count += 1
                if not f.get("description", "").strip():
                    errors.append(
                        f"field {b['name']}.{r['name']}.{f['name']} has an "
                        "empty description"
                    )

    # 4. The Phase-4 groups (Fault injection, Snapshot and debug control) must
    #    be claimed by BOTH the 0x3000 fault block and the 0x8000 debug block.
    #    That is the two-window arrangement described in the debug block's own
    #    description; a claim by only one would mean Phase-4 was not landed.
    fault_owners = claimed_groups.get("Fault injection", [])
    if "fault" not in fault_owners:
        errors.append("Fault injection must be owned by the 'fault' block at 0x3000")
    if "debug" not in fault_owners:
        errors.append(
            "Fault injection must ALSO be owned by the 'debug' block at 0x8000 "
            "(Phase-4 per-block fault selection)"
        )
    snap_owners = claimed_groups.get("Snapshot and debug control", [])
    if "counters" not in snap_owners:
        errors.append(
            "Snapshot and debug control must be owned by the 'counters' block "
            "at 0x7000 (TELEM_CTRL snapshot strobe)"
        )
    if "scratch" not in snap_owners:
        errors.append(
            "Snapshot and debug control must be owned by the 'scratch' block "
            "at 0x4000 (SCRATCH register semantics)"
        )
    if "debug" not in snap_owners:
        errors.append(
            "Snapshot and debug control must be owned by the 'debug' block "
            "at 0x8000 (DBG_SNAP_* registers)"
        )

    # 5. The Phase-4 telemetry block must be present and implemented.
    tel_block = next((b for b in blocks if b["name"] == "telemetry"), None)
    if tel_block is None:
        errors.append("telemetry block (issue #19) is missing")
    elif not tel_block.get("implemented", False):
        errors.append("telemetry block is declared but not implemented")

    # 6. The Phase-4 debug block must expose the DBG_MEM_CTRL / DBG_MEM_STATUS
    #    memory-interface handles required by SPEC 4.3.
    debug_block = next((b for b in blocks if b["name"] == "debug"), None)
    if debug_block is None:
        errors.append("debug block (issue #19) is missing")
    else:
        if not debug_block.get("implemented", False):
            errors.append("debug block is declared but not implemented")
        else:
            reg_names = {r["name"] for r in debug_block.get("registers", [])}
            for required in ("DBG_MEM_CTRL", "DBG_MEM_STATUS", "DBG_MEM_REQ_COUNT",
                             "DBG_MEM_RSP_COUNT", "DBG_SNAP_CTRL", "DBG_SNAP_STATUS",
                             "DBG_SNAP_DATA", "DBG_FAULT_TARGET"):
                if required not in reg_names:
                    errors.append(
                        f"debug block missing required register {required!r}"
                    )

    # 7. Report and exit.
    print(f"\n[summary] {len(blocks)} blocks, {reg_count} registers, "
          f"{field_count} fields")
    if errors:
        print(f"\nFAIL: {len(errors)} issue(s):", file=sys.stderr)
        for e in errors:
            print(f"  * {e}", file=sys.stderr)
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
