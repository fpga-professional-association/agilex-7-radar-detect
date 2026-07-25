#!/usr/bin/env python3
"""Generate the register map artefacts from the single source of truth.

    scripts/gen_regmap.py [--check] [--source control/regmap.json] [--quiet]

Reads ``control/regmap.json`` (SPEC 9, issue #7) and emits four artefacts:

    rtl/control/generated/regmap_pkg.sv   addresses, table constants, field slices
    model/cpp/regmap/regmap.hpp           the same constants for the C++ harness
    docs/regmap.md                        the human table
    results/regmap/regmap.json            the fully resolved machine-readable map

The first three are committed, because a clean checkout must lint and simulate
without running a generator first, and because a register-map change should show
up as a reviewable diff in the artefacts people actually read. What keeps that
safe is ``--check``: it regenerates everything in memory and compares against
what is on disk, exiting non-zero on any difference. ``make regmap-check`` runs
it, and both ``make lint`` and ``make sim-tiny`` depend on it, so a hand-edited
generated file — or a source-of-truth edit that was never regenerated — fails the
gate rather than drifting.

The fourth is not committed: ``results/`` is generated output by SPEC 10 and is
gitignored. It is the artefact downstream tooling (register dumps, telemetry
decoders, issue #19) should consume, and it is reproduced by running this script.

Determinism: the output is a pure function of the source file. No timestamps, no
git state, no host paths, no dictionary-iteration order. That is what makes
``--check`` meaningful, and it is why VERSION in the ID block is a static number
from the source of truth rather than a ``git describe``.
"""

from __future__ import annotations

import argparse
import json
import sys
import textwrap
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

DEFAULT_SOURCE = Path("control/regmap.json")
SV_OUT = Path("rtl/control/generated/regmap_pkg.sv")
HPP_OUT = Path("model/cpp/regmap/regmap.hpp")
MD_OUT = Path("docs/regmap.md")
JSON_OUT = Path("results/regmap/regmap.json")

# The SPEC 9 register-group checklist, verbatim. Every group must be claimed by
# exactly the blocks that own it, and no block may claim a group that is not on
# this list. A register plane that quietly drops a group is the failure mode this
# check exists to prevent.
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

# Field access types. The tuple is (software-writable storage, write-1-to-clear,
# write-1-pulse, hardware-driven read) — i.e. which of the four per-bit mask
# tables the field contributes to. The RTL engine (rtl/control/reg_csr_block.sv)
# implements exactly these four masks and nothing else, so an access type that
# cannot be expressed as a combination of them cannot be added here by accident.
ACCESS = {
    #        wmask  w1c    pulse  hw
    "RO":   (False, False, False, False),
    "ROHW": (False, False, False, True),
    "RW":   (True,  False, False, False),
    "W1C":  (False, True,  False, False),
    "RWP":  (False, False, True,  False),
}


class RegmapError(Exception):
    """A defect in the source of truth. Always fatal; never warned around."""


# ---------------------------------------------------------------------------
# Loading and validation
# ---------------------------------------------------------------------------


def parse_int(value, what: str) -> int:
    if isinstance(value, bool):
        raise RegmapError(f"{what}: expected an integer, got a boolean")
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        try:
            return int(value, 0)
        except ValueError as exc:
            raise RegmapError(f"{what}: cannot parse '{value}' as an integer") from exc
    raise RegmapError(f"{what}: expected an integer or a numeric string, got {value!r}")


def ident(name: str, what: str) -> str:
    if not name or not all(c.isalnum() or c == "_" for c in name):
        raise RegmapError(f"{what}: '{name}' is not a legal identifier")
    if name[0].isdigit():
        raise RegmapError(f"{what}: '{name}' starts with a digit")
    return name


def resolve_reset(raw, ctx: dict, what: str) -> int:
    """Resolves a reset value, including the computed ``$TOKEN`` forms."""
    if raw is None:
        return 0
    if isinstance(raw, str) and raw.startswith("$"):
        token = raw[1:]
        if token not in ctx:
            known = ", ".join(sorted(ctx))
            raise RegmapError(f"{what}: unknown computed token '${token}' (known: {known})")
        return int(ctx[token])
    return parse_int(raw, what)


def load(source: Path) -> dict:
    if not source.is_file():
        raise RegmapError(f"source of truth not found: {source}")
    with source.open("r", encoding="utf-8") as fh:
        return json.load(fh)


def elaborate(doc: dict, source_name: str) -> dict:
    """Validates the source of truth and returns the fully resolved map."""
    if doc.get("schema_version") != 1:
        raise RegmapError(
            f"schema_version {doc.get('schema_version')!r} is not supported (this "
            "generator implements schema 1)"
        )

    data_w = parse_int(doc.get("data_width", 32), "data_width")
    addr_w = parse_int(doc.get("address_width", 16), "address_width")
    window = parse_int(doc.get("block_window_bytes", 4096), "block_window_bytes")
    if data_w != 32:
        raise RegmapError("data_width must be 32: SPEC 9 fixes the register plane at 32 bits")
    if not 8 <= addr_w <= 32:
        raise RegmapError(f"address_width {addr_w} out of range 8..32")
    if window & (window - 1) or window < 4:
        raise RegmapError(f"block_window_bytes {window} is not a power of two >= 4")

    version = doc.get("regmap_version", {})
    for key in ("major", "minor", "patch"):
        if key not in version:
            raise RegmapError(f"regmap_version.{key} is missing")

    blocks_in = doc.get("blocks", [])
    if not blocks_in:
        raise RegmapError("no blocks declared")

    # Pass 1: geometry, so the computed reset tokens can be resolved in pass 2.
    n_blocks = len(blocks_in)
    n_regs_total = sum(len(b.get("registers", [])) for b in blocks_in)
    block_mask = 0
    for i, b in enumerate(blocks_in):
        if b.get("implemented", False):
            block_mask |= 1 << i
    ctx = {
        "N_BLOCKS": n_blocks,
        "N_REGS_TOTAL": n_regs_total,
        "BLOCK_MASK": block_mask,
        "DATA_W": data_w,
        "ADDR_W": addr_w,
        "VERSION_MAJOR": parse_int(version["major"], "regmap_version.major"),
        "VERSION_MINOR": parse_int(version["minor"], "regmap_version.minor"),
        "VERSION_PATCH": parse_int(version["patch"], "regmap_version.patch"),
    }

    # Pass 2: registers and fields.
    blocks = []
    seen_block_names = set()
    windows = []  # (base, limit, name) for the overlap check
    claimed_groups = []
    for index, b in enumerate(blocks_in):
        name = ident(b.get("name", ""), f"blocks[{index}].name")
        if name in seen_block_names:
            raise RegmapError(f"duplicate block name '{name}'")
        seen_block_names.add(name)
        where = f"block '{name}'"

        base = parse_int(b.get("base"), f"{where}.base")
        size = parse_int(b.get("size", window), f"{where}.size")
        implemented = bool(b.get("implemented", False))
        if base % window:
            raise RegmapError(f"{where}: base 0x{base:X} is not aligned to the {window}-byte window")
        if size != window:
            raise RegmapError(
                f"{where}: size 0x{size:X} differs from block_window_bytes 0x{window:X}; "
                "uniform windows keep the decode an address-bit compare"
            )
        if base + size > (1 << addr_w):
            raise RegmapError(f"{where}: window 0x{base:X}+0x{size:X} exceeds the {addr_w}-bit address space")
        for (obase, olimit, oname) in windows:
            if base < olimit and obase < base + size:
                raise RegmapError(f"{where}: window overlaps block '{oname}'")
        windows.append((base, base + size, name))

        groups = b.get("spec_groups", [])
        if not groups:
            raise RegmapError(f"{where}: spec_groups is empty; every block must name the SPEC 9 group(s) it owns")
        for g in groups:
            if g not in SPEC9_GROUPS:
                raise RegmapError(f"{where}: '{g}' is not a SPEC 9 register group")
            claimed_groups.append(g)

        regs_in = b.get("registers", [])
        if not implemented and regs_in:
            raise RegmapError(f"{where}: declared unimplemented but carries {len(regs_in)} registers")
        if implemented and not regs_in:
            raise RegmapError(f"{where}: declared implemented but carries no registers")
        if len(regs_in) * 4 > size:
            raise RegmapError(f"{where}: {len(regs_in)} registers do not fit in a 0x{size:X}-byte window")

        regs = []
        seen_reg_names = set()
        for r_index, r in enumerate(regs_in):
            rname = ident(r.get("name", ""), f"{where}.registers[{r_index}].name")
            if rname in seen_reg_names:
                raise RegmapError(f"{where}: duplicate register name '{rname}'")
            seen_reg_names.add(rname)
            rwhere = f"{where} register '{rname}'"

            offset = parse_int(r.get("offset"), f"{rwhere}.offset")
            if offset != r_index * 4:
                raise RegmapError(
                    f"{rwhere}: offset 0x{offset:X} is not 0x{r_index * 4:X}. Register offsets "
                    "must be dense from 0 within a block, because the RTL decode is a word-index "
                    "compare. Declare an explicit reserved register to leave a hole."
                )

            reset = 0
            wmask = 0
            w1c = 0
            pulse = 0
            hwmask = 0
            occupied = 0
            fields = []
            seen_field_names = set()
            for f_index, f in enumerate(r.get("fields", [])):
                fname = ident(f.get("name", ""), f"{rwhere}.fields[{f_index}].name")
                if fname in seen_field_names:
                    raise RegmapError(f"{rwhere}: duplicate field name '{fname}'")
                seen_field_names.add(fname)
                fwhere = f"{rwhere} field '{fname}'"

                lsb = parse_int(f.get("lsb", 0), f"{fwhere}.lsb")
                width = parse_int(f.get("width", 1), f"{fwhere}.width")
                if width < 1 or lsb < 0 or lsb + width > data_w:
                    raise RegmapError(f"{fwhere}: [{lsb + width - 1}:{lsb}] does not fit in {data_w} bits")
                mask = ((1 << width) - 1) << lsb
                if occupied & mask:
                    raise RegmapError(f"{fwhere}: overlaps another field in the same register")
                occupied |= mask

                access = f.get("access", "RW")
                if access not in ACCESS:
                    raise RegmapError(
                        f"{fwhere}: access '{access}' is not one of {', '.join(sorted(ACCESS))}"
                    )
                is_w, is_w1c, is_pulse, is_hw = ACCESS[access]

                freset = resolve_reset(f.get("reset"), ctx, f"{fwhere}.reset")
                if freset >> width:
                    raise RegmapError(f"{fwhere}: reset 0x{freset:X} does not fit in {width} bits")
                if freset and access != "RO" and access != "RW":
                    raise RegmapError(
                        f"{fwhere}: access {access} must reset to 0 (a hardware-driven, sticky or "
                        "pulse field has no meaningful stored reset value)"
                    )

                reset |= freset << lsb
                if is_w:
                    wmask |= mask
                if is_w1c:
                    w1c |= mask
                if is_pulse:
                    pulse |= mask
                if is_hw:
                    hwmask |= mask

                fields.append(
                    {
                        "name": fname,
                        "lsb": lsb,
                        "width": width,
                        "msb": lsb + width - 1,
                        "mask": mask,
                        "access": access,
                        "reset": freset,
                        "source": f.get("source", ""),
                        "description": f.get("description", ""),
                    }
                )

            if not fields:
                raise RegmapError(f"{rwhere}: has no fields")

            writable = wmask | w1c | pulse
            accesses = sorted({f["access"] for f in fields})
            regs.append(
                {
                    "name": rname,
                    "index": r_index,
                    "offset": offset,
                    "address": base + offset,
                    "access": accesses[0] if len(accesses) == 1 else "MIXED",
                    "accesses": accesses,
                    "reset": reset,
                    "wmask": wmask,
                    "w1c_mask": w1c,
                    "pulse_mask": pulse,
                    "hw_mask": hwmask,
                    "writable_mask": writable,
                    "writable": writable != 0,
                    "description": r.get("description", ""),
                    "fields": fields,
                }
            )

        blocks.append(
            {
                "name": name,
                "index": index,
                "base": base,
                "size": size,
                "implemented": implemented,
                "planned_by": b.get("planned_by", ""),
                "spec_groups": groups,
                "description": b.get("description", ""),
                "n_regs": len(regs),
                "registers": regs,
            }
        )

    missing = [g for g in SPEC9_GROUPS if g not in claimed_groups]
    if missing:
        raise RegmapError(
            "SPEC 9 register groups not claimed by any block: " + "; ".join(missing)
        )

    impl = [b for b in blocks if b["implemented"]]
    if not impl:
        raise RegmapError("no implemented blocks; the fabric would have nothing to decode")

    return {
        "schema_version": 1,
        "generated_by": "scripts/gen_regmap.py",
        "source": source_name,
        "name": doc.get("name", "regmap"),
        "spec_reference": doc.get("spec_reference", "SPEC.md 9"),
        "regmap_version": {
            "major": ctx["VERSION_MAJOR"],
            "minor": ctx["VERSION_MINOR"],
            "patch": ctx["VERSION_PATCH"],
        },
        "data_width": data_w,
        "address_width": addr_w,
        "strobe_width": data_w // 8,
        "block_window_bytes": window,
        "n_blocks": n_blocks,
        "n_blocks_implemented": len(impl),
        "n_regs_total": n_regs_total,
        "block_mask": ctx["BLOCK_MASK"],
        "blocks": blocks,
    }


# ---------------------------------------------------------------------------
# Rendering helpers
# ---------------------------------------------------------------------------


def clog2(n: int) -> int:
    return 0 if n <= 1 else (n - 1).bit_length()


def hex32(v: int) -> str:
    return f"32'h{v & 0xFFFFFFFF:08X}"


def flat_table(values: list[int]) -> str:
    """A flat concatenation, MSB entry first, one entry per line.

    Emitted as a concatenation of 32-bit literals rather than a packed-array
    assignment pattern: a flat vector plus ``[i*32 +: 32]`` indexing is the form
    every tool in this project agrees on, and it survives being passed through a
    module parameter without depending on packed-array parameter support.
    """
    if not values:
        return "32'h00000000"
    lines = []
    for i in range(len(values) - 1, -1, -1):
        sep = "," if i > 0 else ""
        lines.append(f"      {hex32(values[i])}{sep}  // [{i}]")
    return "{\n" + "\n".join(lines) + "\n  }"


def sv_name(*parts: str) -> str:
    return "REGMAP_" + "_".join(p.upper() for p in parts)


def comment_block(text: str, prefix: str = "  // ", width: int = 88) -> list[str]:
    """Wraps `text` into comment lines. Deterministic: textwrap with fixed inputs."""
    if not text.strip():
        return []
    return textwrap.wrap(
        " ".join(text.split()),
        width=width,
        initial_indent=prefix,
        subsequent_indent=prefix,
        break_long_words=False,
        break_on_hyphens=False,
    )


# ---------------------------------------------------------------------------
# SystemVerilog package
# ---------------------------------------------------------------------------


def render_sv(m: dict) -> str:
    addr_w = m["address_width"]
    window = m["block_window_bytes"]
    impl = [b for b in m["blocks"] if b["implemented"]]

    L: list[str] = []
    A = L.append
    A("// GENERATED FILE - DO NOT EDIT.")
    A("//")
    A(f"// Produced by scripts/gen_regmap.py from {m['source']} (SPEC 9, issue #7).")
    A("// Hand edits are erased by the next run and, before that, fail `make regmap-check`,")
    A("// which `make lint` and `make sim-tiny` both depend on.")
    A("//")
    A("// This package is DATA, not behaviour: addresses, window geometry, per-bit access")
    A("// masks and reset values. The behaviour that consumes it is hand written and lives")
    A("// in rtl/control/reg_csr_block.sv (the access-type engine) and rtl/control/")
    A("// reg_fabric.sv (the decode). Generating tables and hand-writing logic is the split")
    A("// this project keeps: a generated always_ff is a thing nobody reviews.")
    A("//")
    A("// Table layout: each per-block table is a flat vector of N_REGS 32-bit entries,")
    A("// entry i at [i*32 +: 32], where i is the register's word index within the block.")
    A("")
    A("package regmap_pkg;")
    A("")
    A("  // ---- plane geometry ----")
    A(f"  localparam int unsigned {sv_name('ADDR_W')} = {addr_w};")
    A(f"  localparam int unsigned {sv_name('DATA_W')} = {m['data_width']};")
    A(f"  localparam int unsigned {sv_name('STRB_W')} = {m['strobe_width']};")
    A(f"  localparam int unsigned {sv_name('WINDOW_BYTES')} = {window};")
    A(f"  localparam int unsigned {sv_name('WINDOW_W')} = {clog2(window)};")
    A(f"  localparam int unsigned {sv_name('N_BLOCKS')} = {m['n_blocks']};")
    A(f"  localparam int unsigned {sv_name('N_BLOCKS_IMPL')} = {m['n_blocks_implemented']};")
    A(f"  localparam int unsigned {sv_name('N_REGS_TOTAL')} = {m['n_regs_total']};")
    A(f"  localparam logic [31:0] {sv_name('BLOCK_MASK')} = {hex32(m['block_mask'])};")
    A("")
    A("  // ---- implemented block windows, in fabric port order ----")
    A("  // The fabric decodes one master port onto these windows; index i here is index i")
    A("  // on every per-block port array of rtl/control/reg_fabric.sv.")
    base_entries = ", ".join(f"{addr_w}'h{b['base']:04X}" for b in reversed(impl))
    A(f"  localparam logic [{sv_name('N_BLOCKS_IMPL')}*{sv_name('ADDR_W')}-1:0] "
      f"{sv_name('IMPL_BASE')} = {{{base_entries}}};")
    for i, b in enumerate(impl):
        A(f"  //   [{i}] {b['name']:<13} base 0x{b['base']:04X}  {b['n_regs']} registers")
    A("")

    for b in m["blocks"]:
        A("  // -------------------------------------------------------------------------")
        status = "implemented" if b["implemented"] else f"PLANNED ({b['planned_by']})"
        A(f"  // Block {b['index']}: {b['name']} — {status}")
        A(f"  // SPEC 9 groups: {'; '.join(b['spec_groups'])}")
        for line in comment_block(b["description"], "  // "):
            A(line)
        A("  // -------------------------------------------------------------------------")
        A(f"  localparam logic [{sv_name('ADDR_W')}-1:0] {sv_name(b['name'], 'BASE')} = "
          f"{addr_w}'h{b['base']:04X};")
        A(f"  localparam int unsigned {sv_name(b['name'], 'SIZE')} = {b['size']};")
        A(f"  localparam int unsigned {sv_name(b['name'], 'N_REGS')} = {b['n_regs']};")
        if not b["implemented"]:
            A(f"  // No registers in this build: every access to 0x{b['base']:04X}.."
              f"0x{b['base'] + b['size'] - 1:04X} returns error=1.")
            A("")
            continue
        A(f"  localparam int unsigned {sv_name(b['name'], 'INDEX')} = "
          f"{[x['name'] for x in impl].index(b['name'])};  // fabric port index")
        A("")
        for r in b["registers"]:
            A(f"  // {r['name']} @ 0x{r['address']:04X} ({r['access']})")
            for line in comment_block(r["description"], "  //   "):
                A(line)
            for f in r["fields"]:
                src = f" <- {f['source']}" if f["source"] else ""
                A(f"  //   [{f['msb']}:{f['lsb']}] {f['name']} ({f['access']}){src}")
                for line in comment_block(f["description"], "  //       "):
                    A(line)
            A(f"  localparam int unsigned {sv_name(b['name'], r['name'], 'INDEX')} = {r['index']};")
            A(f"  localparam logic [{sv_name('ADDR_W')}-1:0] {sv_name(b['name'], r['name'], 'ADDR')} = "
              f"{addr_w}'h{r['address']:04X};")
            for f in r["fields"]:
                A(f"  localparam int unsigned {sv_name(b['name'], r['name'], f['name'], 'LSB')} = {f['lsb']};")
                A(f"  localparam int unsigned {sv_name(b['name'], r['name'], f['name'], 'WIDTH')} = {f['width']};")
                A(f"  localparam logic [31:0] {sv_name(b['name'], r['name'], f['name'], 'MASK')} = "
                  f"{hex32(f['mask'])};")
            A("")
        width = f"{sv_name(b['name'], 'N_REGS')}*32-1:0"
        for tag, key, doc in (
            ("RESET", "reset", "reset value of the stored bits"),
            ("WMASK", "wmask", "bits a software write may set or clear (RW)"),
            ("W1CMASK", "w1c_mask", "bits cleared by writing 1, set by hardware (W1C)"),
            ("PULSEMASK", "pulse_mask", "bits that pulse for one cycle and read 0 (RWP)"),
            ("HWMASK", "hw_mask", "bits read from the hardware input, not from storage (ROHW)"),
        ):
            A(f"  // {doc}")
            A(f"  localparam logic [{width}] {sv_name(b['name'], tag)} = "
              f"{flat_table([r[key] for r in b['registers']])};")
        A("")

    A("endpackage : regmap_pkg")
    A("")
    return "\n".join(L)


# ---------------------------------------------------------------------------
# C++ header
# ---------------------------------------------------------------------------


def render_hpp(m: dict) -> str:
    impl = [b for b in m["blocks"] if b["implemented"]]
    L: list[str] = []
    A = L.append
    A("// GENERATED FILE - DO NOT EDIT.")
    A("//")
    A(f"// Produced by scripts/gen_regmap.py from {m['source']} (SPEC 9, issue #7).")
    A("// The C++ half of the single source of truth: the harness addresses registers with")
    A("// these constants, the RTL decodes with rtl/control/generated/regmap_pkg.sv, and both")
    A("// come from one file. `make regmap-check` fails if either drifts.")
    A("//")
    A("// Two shapes are provided, deliberately:")
    A("//   * named constants, for a test that means a specific register;")
    A("//   * kBlocks / kRegisters / kFields tables, for a test that walks the whole map")
    A("//     (reset-default sweep, randomized soak) without naming anything. A generated")
    A("//     table is what makes 'every documented register' a checkable claim.")
    A("")
    A("#ifndef MODEL_CPP_REGMAP_REGMAP_HPP_")
    A("#define MODEL_CPP_REGMAP_REGMAP_HPP_")
    A("")
    A("#include <cstddef>")
    A("#include <cstdint>")
    A("")
    A("namespace regmap {")
    A("")
    A(f"inline constexpr unsigned kAddrWidth = {m['address_width']};")
    A(f"inline constexpr unsigned kDataWidth = {m['data_width']};")
    A(f"inline constexpr unsigned kStrobeWidth = {m['strobe_width']};")
    A(f"inline constexpr std::uint32_t kWindowBytes = 0x{m['block_window_bytes']:X}u;")
    A(f"inline constexpr std::uint32_t kAddrMask = 0x{(1 << m['address_width']) - 1:X}u;")
    A(f"inline constexpr unsigned kBlockCount = {m['n_blocks']};")
    A(f"inline constexpr unsigned kBlockCountImplemented = {m['n_blocks_implemented']};")
    A(f"inline constexpr unsigned kRegisterCount = {m['n_regs_total']};")
    A(f"inline constexpr std::uint32_t kBlockMask = 0x{m['block_mask']:08X}u;")
    A(f"inline constexpr unsigned kVersionMajor = {m['regmap_version']['major']};")
    A(f"inline constexpr unsigned kVersionMinor = {m['regmap_version']['minor']};")
    A(f"inline constexpr unsigned kVersionPatch = {m['regmap_version']['patch']};")
    A("")
    A("// Per-bit access classification, matching rtl/control/reg_csr_block.sv.")
    A("enum class Access : std::uint8_t { kRo, kRoHw, kRw, kW1c, kRwp, kMixed };")
    A("")
    A("struct FieldInfo {")
    A("  const char* block;")
    A("  const char* reg;")
    A("  const char* name;")
    A("  unsigned lsb;")
    A("  unsigned width;")
    A("  std::uint32_t mask;")
    A("  Access access;")
    A("  std::uint32_t reset;")
    A("};")
    A("")
    A("struct RegInfo {")
    A("  const char* block;")
    A("  const char* name;")
    A("  std::uint32_t address;")
    A("  unsigned block_index;   // index among implemented blocks")
    A("  unsigned index;         // word index inside the block")
    A("  Access access;")
    A("  std::uint32_t reset;         // reset value of the stored bits")
    A("  std::uint32_t wmask;         // plain read-write bits")
    A("  std::uint32_t w1c_mask;      // write-1-to-clear bits")
    A("  std::uint32_t pulse_mask;    // write-1-pulse bits (always read 0)")
    A("  std::uint32_t hw_mask;       // bits read from hardware, not storage")
    A("  std::uint32_t writable_mask; // wmask | w1c_mask | pulse_mask")
    A("};")
    A("")
    A("struct BlockInfo {")
    A("  const char* name;")
    A("  std::uint32_t base;")
    A("  std::uint32_t size;")
    A("  bool implemented;")
    A("  unsigned reg_count;")
    A("};")
    A("")
    A("// ---- named register addresses -------------------------------------------")
    for b in impl:
        A(f"// {b['name']}: {b['description'].split('.')[0]}.")
        A(f"inline constexpr std::uint32_t {b['name'].upper()}_BASE = 0x{b['base']:04X}u;")
        for r in b["registers"]:
            n = f"{b['name'].upper()}_{r['name']}"
            A(f"inline constexpr std::uint32_t {n}_ADDR = 0x{r['address']:04X}u;")
            A(f"inline constexpr std::uint32_t {n}_RESET = 0x{r['reset']:08X}u;")
            for f in r["fields"]:
                fn = f"{n}_{f['name']}"
                A(f"inline constexpr unsigned {fn}_LSB = {f['lsb']};")
                A(f"inline constexpr unsigned {fn}_WIDTH = {f['width']};")
                A(f"inline constexpr std::uint32_t {fn}_MASK = 0x{f['mask']:08X}u;")
        A("")
    A("// ---- planned windows (declared, not implemented in this build) ----------")
    for b in m["blocks"]:
        if b["implemented"]:
            continue
        A(f"// {b['name']} 0x{b['base']:04X}: planned by {b['planned_by']}. Accesses return error=1.")
        A(f"inline constexpr std::uint32_t {b['name'].upper()}_BASE = 0x{b['base']:04X}u;")
    A("")
    A("// ---- tables --------------------------------------------------------------")
    A(f"inline constexpr BlockInfo kBlocks[{m['n_blocks']}] = {{")
    for b in m["blocks"]:
        A(f'    {{"{b["name"]}", 0x{b["base"]:04X}u, 0x{b["size"]:04X}u, '
          f'{"true" if b["implemented"] else "false"}, {b["n_regs"]}}},')
    A("};")
    A("")

    def acc(a: str) -> str:
        return {
            "RO": "Access::kRo",
            "ROHW": "Access::kRoHw",
            "RW": "Access::kRw",
            "W1C": "Access::kW1c",
            "RWP": "Access::kRwp",
            "MIXED": "Access::kMixed",
        }[a]

    A(f"inline constexpr RegInfo kRegisters[{m['n_regs_total']}] = {{")
    for bi, b in enumerate(impl):
        for r in b["registers"]:
            A(f'    {{"{b["name"]}", "{r["name"]}", 0x{r["address"]:04X}u, {bi}, {r["index"]}, '
              f'{acc(r["access"])}, 0x{r["reset"]:08X}u, 0x{r["wmask"]:08X}u, '
              f'0x{r["w1c_mask"]:08X}u, 0x{r["pulse_mask"]:08X}u, 0x{r["hw_mask"]:08X}u, '
              f'0x{r["writable_mask"]:08X}u}},')
    A("};")
    A("")
    n_fields = sum(len(r["fields"]) for b in impl for r in b["registers"])
    A(f"inline constexpr FieldInfo kFields[{n_fields}] = {{")
    for b in impl:
        for r in b["registers"]:
            for f in r["fields"]:
                A(f'    {{"{b["name"]}", "{r["name"]}", "{f["name"]}", {f["lsb"]}, {f["width"]}, '
                  f'0x{f["mask"]:08X}u, {acc(f["access"])}, 0x{f["reset"]:08X}u}},')
    A("};")
    A("")
    A("inline constexpr std::size_t kBlockTableSize = sizeof(kBlocks) / sizeof(kBlocks[0]);")
    A("inline constexpr std::size_t kRegisterTableSize = sizeof(kRegisters) / sizeof(kRegisters[0]);")
    A("inline constexpr std::size_t kFieldTableSize = sizeof(kFields) / sizeof(kFields[0]);")
    A("")
    A("// True when `address` falls inside an implemented block window.")
    A("constexpr bool address_mapped(std::uint32_t address) {")
    A("  for (std::size_t i = 0; i < kBlockTableSize; ++i) {")
    A("    if (!kBlocks[i].implemented) continue;")
    A("    if (address >= kBlocks[i].base && address < kBlocks[i].base + kBlocks[i].size) {")
    A("      return address - kBlocks[i].base < kBlocks[i].reg_count * 4u;")
    A("    }")
    A("  }")
    A("  return false;")
    A("}")
    A("")
    A("// The RegInfo for `address`, or nullptr when the address is not a register.")
    A("constexpr const RegInfo* find(std::uint32_t address) {")
    A("  for (std::size_t i = 0; i < kRegisterTableSize; ++i) {")
    A("    if (kRegisters[i].address == address) return &kRegisters[i];")
    A("  }")
    A("  return nullptr;")
    A("}")
    A("")
    A("// Extracts a field from a register value read back from the DUT.")
    A("constexpr std::uint32_t field_get(std::uint32_t value, unsigned lsb, unsigned width) {")
    A("  return (value >> lsb) & (width >= 32u ? 0xFFFFFFFFu : ((1u << width) - 1u));")
    A("}")
    A("")
    A("// Inserts a field into a register value, leaving every other bit alone.")
    A("constexpr std::uint32_t field_set(std::uint32_t value, unsigned lsb, unsigned width,")
    A("                                  std::uint32_t field) {")
    A("  const std::uint32_t m = (width >= 32u ? 0xFFFFFFFFu : ((1u << width) - 1u)) << lsb;")
    A("  return (value & ~m) | ((field << lsb) & m);")
    A("}")
    A("")
    A("}  // namespace regmap")
    A("")
    A("#endif  // MODEL_CPP_REGMAP_REGMAP_HPP_")
    A("")
    return "\n".join(L)


# ---------------------------------------------------------------------------
# Markdown
# ---------------------------------------------------------------------------


def render_md(m: dict) -> str:
    L: list[str] = []
    A = L.append
    A("# Register Map")
    A("")
    A("<!-- GENERATED FILE - DO NOT EDIT. -->")
    A("")
    A(f"Generated by `scripts/gen_regmap.py` from `{m['source']}`, the single source of truth")
    A("for the register and control plane ([SPEC.md](../SPEC.md) §9, issue #7). Edit the source")
    A("and re-run the generator; `make regmap-check` fails the build on any hand edit here or")
    A("on a source change that was never regenerated.")
    A("")
    v = m["regmap_version"]
    A(f"- Register-map version: **{v['major']}.{v['minor']}.{v['patch']}** (schema {m['schema_version']})")
    A(f"- Interface: {m['data_width']}-bit data, {m['address_width']}-bit byte address, "
      f"{m['strobe_width']} byte enables")
    A(f"- Window per block: `0x{m['block_window_bytes']:X}` bytes")
    A(f"- Blocks declared: {m['n_blocks']} ({m['n_blocks_implemented']} implemented), "
      f"registers implemented: {m['n_regs_total']}")
    A("")
    A("## Access types")
    A("")
    A("| Type | Meaning |")
    A("|---|---|")
    A("| `RO` | Constant. The reset value is the value. Writes to a register whose fields are all `RO`/`ROHW` return `error=1`. |")
    A("| `ROHW` | Read-only, driven by hardware (build parameters, status, counters). |")
    A("| `RW` | Read-write storage, byte-enable maskable. |")
    A("| `W1C` | Sticky: set by hardware, cleared by writing 1. Writing 0 has no effect; a hardware set beats a simultaneous clear. |")
    A("| `RWP` | Write-1-pulse: emits a one-cycle pulse, always reads 0. |")
    A("")
    A("A register with a mix of writable and non-writable fields accepts writes and ignores")
    A("the non-writable bits (`error=0`).")
    A("")
    A("## Address map")
    A("")
    A("| Block | Window | Registers | Status | SPEC §9 groups |")
    A("|---|---|---|---|---|")
    for b in m["blocks"]:
        status = "implemented" if b["implemented"] else f"planned ({b['planned_by']})"
        A(f"| `{b['name']}` | `0x{b['base']:04X}`–`0x{b['base'] + b['size'] - 1:04X}` | "
          f"{b['n_regs']} | {status} | {'; '.join(b['spec_groups'])} |")
    A("")
    A("Any address outside every implemented window, any address inside a window but beyond")
    A("that block's last register, any unaligned address, a write with no byte enables set,")
    A("and a simultaneous read and write all complete with `ready=1, error=1` and no side")
    A("effect. The fabric never stalls indefinitely: see the response contract in")
    A("[DECISIONS.md](../DECISIONS.md).")
    A("")
    for b in m["blocks"]:
        A(f"## `{b['name']}` — `0x{b['base']:04X}`")
        A("")
        A(b["description"])
        A("")
        if not b["implemented"]:
            A(f"**Planned, not implemented in this build** (owning issues: {b['planned_by']}).")
            A("The window is reserved and every access to it returns `error=1`.")
            A("")
            continue
        A("| Offset | Address | Register | Access | Reset | Description |")
        A("|---|---|---|---|---|---|")
        for r in b["registers"]:
            A(f"| `0x{r['offset']:03X}` | `0x{r['address']:04X}` | `{r['name']}` | "
              f"{r['access']} | `0x{r['reset']:08X}` | {r['description']} |")
        A("")
        for r in b["registers"]:
            A(f"### `{b['name'].upper()}.{r['name']}` — `0x{r['address']:04X}`")
            A("")
            A("| Bits | Field | Access | Reset | Source | Description |")
            A("|---|---|---|---|---|---|")
            for f in r["fields"]:
                bits = f"{f['msb']}" if f["width"] == 1 else f"{f['msb']}:{f['lsb']}"
                src = f"`{f['source']}`" if f["source"] else "—"
                A(f"| `{bits}` | `{f['name']}` | {f['access']} | `0x{f['reset']:X}` | {src} | "
                  f"{f['description']} |")
            A("")
    A("## Regenerating")
    A("")
    A("```sh")
    A("python3 scripts/gen_regmap.py          # rewrite every artefact")
    A("python3 scripts/gen_regmap.py --check  # fail if any artefact is stale or hand edited")
    A("make regmap-check                      # the same check, as run by lint and sim-tiny")
    A("```")
    A("")
    return "\n".join(L)


def render_json(m: dict) -> str:
    return json.dumps(m, indent=2, sort_keys=False) + "\n"


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------


def read_text(path: Path) -> str | None:
    if not path.is_file():
        return None
    with path.open("r", encoding="utf-8", newline="") as fh:
        return fh.read()


def write_text(path: Path, content: str) -> bool:
    path.parent.mkdir(parents=True, exist_ok=True)
    if read_text(path) == content:
        return False
    with path.open("w", encoding="utf-8", newline="\n") as fh:
        fh.write(content)
    return True


def first_difference(a: str, b: str) -> str:
    a_lines, b_lines = a.splitlines(), b.splitlines()
    for i in range(max(len(a_lines), len(b_lines))):
        old = a_lines[i] if i < len(a_lines) else "<end of file>"
        new = b_lines[i] if i < len(b_lines) else "<end of file>"
        if old != new:
            return f"    line {i + 1}:\n      on disk   : {old}\n      generated : {new}"
    return "    (files differ only in trailing newline)"


def main() -> int:
    p = argparse.ArgumentParser(
        description="Generate the register map from control/regmap.json (SPEC 9, issue #7).",
    )
    p.add_argument("--source", default=str(DEFAULT_SOURCE),
                   help=f"source of truth (default: {DEFAULT_SOURCE})")
    p.add_argument("--check", action="store_true",
                   help="do not write; exit 1 if any committed artefact differs from what "
                        "the source of truth generates")
    p.add_argument("--quiet", action="store_true", help="less chatter")
    args = p.parse_args()

    source = Path(args.source)
    if not source.is_absolute():
        source = REPO_ROOT / source
    source_name = source.relative_to(REPO_ROOT).as_posix() if source.is_relative_to(REPO_ROOT) \
        else source.name

    try:
        m = elaborate(load(source), source_name)
    except RegmapError as exc:
        print(f"ERROR: {source_name}: {exc}", file=sys.stderr)
        return 2
    except json.JSONDecodeError as exc:
        print(f"ERROR: {source_name}: not valid JSON: {exc}", file=sys.stderr)
        return 2

    committed = [
        (SV_OUT, render_sv(m)),
        (HPP_OUT, render_hpp(m)),
        (MD_OUT, render_md(m)),
    ]

    if args.check:
        stale = []
        for rel, content in committed:
            on_disk = read_text(REPO_ROOT / rel)
            if on_disk is None:
                stale.append((rel, "missing"))
            elif on_disk != content:
                stale.append((rel, first_difference(on_disk, content)))
        if stale:
            print("ERROR: generated register-map artefacts are out of date or hand edited.",
                  file=sys.stderr)
            for rel, detail in stale:
                print(f"  {rel.as_posix()}", file=sys.stderr)
                print(f"{detail}" if detail != "missing" else "    file does not exist",
                      file=sys.stderr)
            print(f"\nRegenerate with: python3 scripts/gen_regmap.py "
                  f"--source {source_name}", file=sys.stderr)
            return 1
        if not args.quiet:
            print(f"[regmap] check: {len(committed)} artefacts match {source_name} "
                  f"({m['n_regs_total']} registers, {m['n_blocks_implemented']}/"
                  f"{m['n_blocks']} blocks implemented)")
        return 0

    changed = []
    for rel, content in committed + [(JSON_OUT, render_json(m))]:
        if write_text(REPO_ROOT / rel, content):
            changed.append(rel)
    if not args.quiet:
        for rel, _ in committed + [(JSON_OUT, render_json(m))]:
            state = "written" if rel in changed else "unchanged"
            print(f"[regmap] {rel.as_posix()}: {state}")
        print(f"[regmap] {m['n_regs_total']} registers in "
              f"{m['n_blocks_implemented']}/{m['n_blocks']} blocks, "
              f"map version {m['regmap_version']['major']}."
              f"{m['regmap_version']['minor']}.{m['regmap_version']['patch']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
