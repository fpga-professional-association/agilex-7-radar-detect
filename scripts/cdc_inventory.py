#!/usr/bin/env python3
"""Generate the SPEC 8 CDC inventory report.

    scripts/cdc_inventory.py [--top MODULE] [--files LIST.f]
                             [--out results/simulation/cdc_inventory.json]
                             [--rtl-dir rtl] [--print] [--strict]

SPEC 8 ends its clock-domain requirements with "Generate an explicit CDC
inventory report". This script is that report: it enumerates every
clock-domain crossing in an elaborated design, with the instance path, the
crossing type, the source and destination clock nets resolved to top-level
names, the payload width and the synchronizer depth — and it fails when it finds
a crossing it cannot classify.

MECHANISM, AND WHY THIS ONE
---------------------------
Two halves, because neither alone is sufficient and each is authoritative for a
different thing.

1. THE CATALOG comes from a source scan of ``rtl/`` for a SystemVerilog
   attribute immediately above a module declaration::

       (* cdc_primitive = "async_fifo_gray", cdc_src_clk = "wr_clk",
          cdc_dst_clk = "rd_clk", cdc_width = "WIDTH",
          cdc_stages = "SYNC_STAGES" *)
       module async_fifo #(...

   The attribute declares what kind of crossing the module is, which of its
   PORTS carry the two clocks, and which of its PARAMETERS give the width and
   the synchronizer depth. It has no effect on synthesis — Quartus and Verilator
   both ignore an attribute they do not recognise — and it lives next to the RTL
   it describes, so it cannot drift the way a separate registry file would.

   Why the source and not the elaborated netlist: Verilator's lexer strips
   ``(* ... *)`` before the parser runs (measured, 5.020), so the attribute does
   not survive into any tool output. The declaration has to be read from the
   source.

2. THE INSTANCE TREE comes from ``verilator --xml-only`` on the same file list
   the simulation builds from. That gives the fully elaborated hierarchy — every
   instance path, the resolved value of every parameter, and the net connected
   to every port — after generate blocks, parameter propagation and hierarchy
   flattening decisions have all been made.

   Why not a source scan for this half as well: a regex over instantiations
   cannot resolve a parameter that was overridden two levels up, cannot expand a
   generate loop, and would list a module that is never instantiated. The
   inventory has to describe the design that exists, not the text that produced
   it.

   Why not the Quartus netlist: the inventory must be producible on the
   simulation side of the split-toolchain rule, from a clean checkout, with no
   licence and no fitter run.

The two halves are joined on the module's ``origName`` — its pre-parameterisation
name — because Verilator renames a parameterised module (``async_fifo`` becomes
``async_fifo__W28`` and so on) and the same source module may appear several
times under different names.

WHAT COUNTS AS AN UNKNOWN
-------------------------
The report is only worth having if it is complete, so the script actively hunts
for crossings it was not told about:

  * an instantiated module with two or more clock-like ports (a port whose name
    contains ``clk``) that carries NO ``cdc_primitive`` attribute is an
    unclassified crossing. This is the check that makes the inventory
    self-maintaining: add a two-clock module to the design without tagging it and
    the inventory fails.
  * a tagged module whose declared clock port does not exist, or whose clock net
    cannot be resolved to a name, or whose declared width or stage parameter is
    missing.

Either kind lands in ``unknown`` in the JSON, and with ``--strict`` (the default
under ``make``) a non-empty ``unknown`` list exits 1.

``cdc_src_clk = "@async"`` is a DECLARED value, not an unknown: a flip-flop
synchronizer has no source-side logic and therefore no source clock port. Its
source is an arbitrary asynchronous domain, constrained in SDC by a false path
onto the first stage rather than by a named clock. The report still says where it
sits by naming the nearest enclosing tagged primitive, whose own source clock IS
resolved.

OUTPUT
------
``results/simulation/cdc_inventory.json`` (SPEC 10 puts simulation artefacts
there; the directory is gitignored, per PLAN.md standing rule 3). Schema::

    {
      "schema_version": 1,
      "top": "<top module>",
      "files": "<file list>",
      "counts": {"crossings": N, "by_type": {...}, "unknown": N},
      "crossings": [
        {"instance": "top.u_scdc_f.u_fifo",
         "type": "async_fifo_gray",
         "module": "async_fifo",
         "declared_in": "rtl/cdc/async_fifo.sv:92",
         "source_clock": "clk_a",
         "dest_clock": "clk_b",
         "width": 54,
         "sync_stages": 2,
         "parent_primitive": "top.u_scdc_f"},
        ...
      ],
      "unknown": [...]
    }

Crossings are emitted in instance-path order, so two runs of the same design
produce byte-identical JSON.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

DEFAULT_TOP = "cdc_prims_top"
DEFAULT_FILES = Path("sim/verilator/files_cdc.f")
DEFAULT_OUT = Path("results/simulation/cdc_inventory.json")
DEFAULT_RTL_DIRS = ("rtl", "sim/verilator/tops")

SCHEMA_VERSION = 1

# A port is "clock-like" when its name contains this. Deliberately loose: the
# untagged-crossing detector should over-report rather than miss one, and a
# false positive is fixed by tagging the module, which is the right outcome
# anyway.
CLOCK_PORT_RE = re.compile(r"clk", re.IGNORECASE)

# `(* ... *)` attribute block immediately preceding a `module <name>`.
ATTR_BLOCK_RE = re.compile(
    r"\(\*(?P<body>[^*]*(?:\*(?!\))[^*]*)*)\*\)\s*module\s+(?P<module>\w+)",
    re.MULTILINE,
)
ATTR_KV_RE = re.compile(r"(\w+)\s*=\s*\"([^\"]*)\"")


# ---------------------------------------------------------------------------
# Half 1: the catalog, from the RTL source
# ---------------------------------------------------------------------------


def scan_catalog(rtl_dirs: list[Path]) -> dict:
    """module name -> declaration record, from the (* cdc_primitive *) attribute."""
    catalog: dict[str, dict] = {}
    for rtl_dir in rtl_dirs:
        base = REPO_ROOT / rtl_dir
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*.sv")):
            text = path.read_text(encoding="utf-8")
            for m in ATTR_BLOCK_RE.finditer(text):
                kv = dict(ATTR_KV_RE.findall(m.group("body")))
                if "cdc_primitive" not in kv:
                    continue
                module = m.group("module")
                line = text.count("\n", 0, m.start("module")) + 1
                try:
                    where = path.relative_to(REPO_ROOT).as_posix()
                except ValueError:
                    # --rtl-dir may point outside the repository; the negative
                    # test for the untagged-crossing detector does exactly that.
                    where = path.as_posix()
                catalog[module] = {
                    "type": kv["cdc_primitive"],
                    "src_clk": kv.get("cdc_src_clk", ""),
                    "dst_clk": kv.get("cdc_dst_clk", ""),
                    "width": kv.get("cdc_width", ""),
                    "stages": kv.get("cdc_stages", ""),
                    "declared_in": "{}:{}".format(where, line),
                }
    return catalog


# ---------------------------------------------------------------------------
# Half 2: the elaborated instance tree, from verilator --xml-only
# ---------------------------------------------------------------------------


def run_verilator_xml(verilator: str, top: str, files: Path, xml_path: Path) -> None:
    cmd = [
        verilator,
        "--xml-only",
        "--xml-output",
        str(xml_path),
        "--top-module",
        top,
        "-f",
        str(files),
        # The inventory is not a lint run: warnings belong to `make lint`, and a
        # waived warning must not stop the report from being produced.
        "-Wno-fatal",
    ]
    proc = subprocess.run(cmd, cwd=REPO_ROOT, capture_output=True, text=True)
    if proc.returncode != 0 or not xml_path.is_file():
        sys.stderr.write(proc.stdout)
        sys.stderr.write(proc.stderr)
        raise SystemExit(
            "ERROR: verilator --xml-only failed for top={} files={}".format(top, files)
        )


CONST_RE = re.compile(r"^(?:(\d+)'s?[hdbo])?([0-9a-fA-F]+)$")


def const_value(name: str):
    """Parse a Verilator <const name="32'sh4"> literal into an int, or None."""
    if name is None:
        return None
    txt = name.replace("&apos;", "'").strip()
    m = re.match(r"^\s*(\d+)?'s?([hdbo])([0-9a-fA-F_]+)\s*$", txt)
    if m:
        base = {"h": 16, "d": 10, "b": 2, "o": 8}[m.group(2)]
        try:
            return int(m.group(3).replace("_", ""), base)
        except ValueError:
            return None
    try:
        return int(txt, 0)
    except ValueError:
        return None


def parse_netlist(xml_path: Path) -> tuple[dict, list]:
    """Returns (modules, cells_roots).

    modules: elaborated module name -> {
        orig, top, params{name: int|str}, ports{name: dir}, instances{name: {
            def, ports{formal: net-or-None}}}}
    cells_roots: the <cells> hierarchy roots.
    """
    root = ET.parse(xml_path).getroot()
    modules: dict[str, dict] = {}

    netlist = root.find("netlist")
    if netlist is None:
        raise SystemExit("ERROR: verilator XML has no <netlist>")

    for m in netlist.findall("module"):
        name = m.get("name")
        rec = {
            "orig": m.get("origName", name),
            "top": m.get("topModule") == "1",
            "params": {},
            "ports": {},
            "instances": {},
        }
        for v in m.iter("var"):
            if v.get("param") == "true":
                c = v.find("const")
                val = const_value(c.get("name")) if c is not None else None
                rec["params"][v.get("name")] = (
                    val if val is not None else (c.get("name") if c is not None else None)
                )
        # Ports are the direct children carrying a pinIndex.
        for v in m.findall("var"):
            if v.get("pinIndex") is not None and v.get("dir") is not None:
                rec["ports"][v.get("name")] = v.get("dir")
        for inst in m.iter("instance"):
            pins = {}
            for p in inst.findall("port"):
                ref = p.find("varref")
                pins[p.get("name")] = ref.get("name") if ref is not None else None
            rec["instances"][inst.get("name")] = {
                "def": inst.get("defName"),
                "ports": pins,
            }
        modules[name] = rec

    cells = root.find("cells")
    roots = list(cells) if cells is not None else []
    return modules, roots


def walk_cells(roots, modules):
    """Yields (hier_path, module_name, stack) for every instance in the design.

    `stack` is the list of (containing_module_name, instance_name) from the top
    down to and including this instance, which is what the clock resolver walks
    back up.
    """
    out = []

    def rec(cell, stack, parent_module):
        name = cell.get("name")
        sub = cell.get("submodname")
        hier = cell.get("hier")
        if parent_module is None:
            # The root cell IS the top module, not an instance inside anything.
            new_stack = []
        else:
            new_stack = stack + [(parent_module, name)]
            out.append((hier, sub, list(new_stack)))
        for child in cell:
            rec(child, new_stack, sub)

    for r in roots:
        rec(r, [], None)
    return out


def resolve_net(modules: dict, stack: list, module_name: str, net: str):
    """Walks a net from an instance's port outward to the outermost scope it reaches.

    Returns (resolved_name, reached_top). `stack` is [(parent_module, inst), ...]
    from the top down to this instance.
    """
    cur_mod = module_name
    idx = len(stack) - 1
    while idx >= 0:
        parent_mod, inst = stack[idx]
        if net not in modules.get(cur_mod, {}).get("ports", {}):
            break
        conn = (
            modules.get(parent_mod, {})
            .get("instances", {})
            .get(inst, {})
            .get("ports", {})
            .get(net)
        )
        if conn is None:
            break
        net = conn
        cur_mod = parent_mod
        idx -= 1
    return net, modules.get(cur_mod, {}).get("top", False)


def param_or_literal(spec: str, params: dict):
    """A cdc_width / cdc_stages attribute value: a literal, or a parameter name."""
    if spec == "":
        return None
    if spec.isdigit():
        return int(spec)
    return params.get(spec)


# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------


def build_report(top: str, files: Path, catalog: dict, modules: dict, roots) -> dict:
    instances = walk_cells(roots, modules)

    # Instance path -> primitive type, so an inner synchronizer can name the
    # composite it belongs to.
    tagged_paths = {}
    for hier, mod_name, _stack in instances:
        orig = modules.get(mod_name, {}).get("orig", mod_name)
        if orig in catalog:
            tagged_paths[hier] = orig

    def nearest_parent_primitive(hier: str):
        parts = hier.split(".")
        for cut in range(len(parts) - 1, 0, -1):
            candidate = ".".join(parts[:cut])
            if candidate in tagged_paths:
                return candidate
        return None

    crossings = []
    unknown = []

    for hier, mod_name, stack in sorted(instances, key=lambda t: t[0]):
        mrec = modules.get(mod_name, {})
        orig = mrec.get("orig", mod_name)
        params = mrec.get("params", {})
        ports = mrec.get("ports", {})

        if orig not in catalog:
            clock_ports = [p for p in ports if CLOCK_PORT_RE.search(p)]
            if len(clock_ports) >= 2:
                unknown.append(
                    {
                        "instance": hier,
                        "module": orig,
                        "reason": "untagged module with {} clock ports ({}); add a "
                        "(* cdc_primitive = ... *) attribute above its module "
                        "declaration".format(len(clock_ports), ", ".join(sorted(clock_ports))),
                    }
                )
            continue

        decl = catalog[orig]
        entry = {
            "instance": hier,
            "type": decl["type"],
            "module": orig,
            "declared_in": decl["declared_in"],
        }
        problems = []

        # Source clock. "@async" is a declared value, not a missing one.
        if decl["src_clk"] == "@async":
            entry["source_clock"] = "@async"
        elif decl["src_clk"] == "":
            problems.append("no cdc_src_clk declared")
            entry["source_clock"] = None
        elif decl["src_clk"] not in ports:
            problems.append(
                "declared source clock port '{}' does not exist on the module".format(
                    decl["src_clk"]
                )
            )
            entry["source_clock"] = None
        else:
            net, at_top = resolve_net(modules, stack, mod_name, decl["src_clk"])
            entry["source_clock"] = net
            entry["source_clock_is_top_net"] = at_top

        # Destination clock. Always a real port.
        if decl["dst_clk"] == "" or decl["dst_clk"] not in ports:
            problems.append(
                "declared destination clock port '{}' does not exist on the "
                "module".format(decl["dst_clk"])
            )
            entry["dest_clock"] = None
        else:
            net, at_top = resolve_net(modules, stack, mod_name, decl["dst_clk"])
            entry["dest_clock"] = net
            entry["dest_clock_is_top_net"] = at_top

        width = param_or_literal(decl["width"], params)
        if width is None:
            problems.append(
                "width '{}' is neither a literal nor a parameter of the "
                "module".format(decl["width"])
            )
        entry["width"] = width

        stages = param_or_literal(decl["stages"], params)
        if stages is None:
            problems.append(
                "synchronizer depth '{}' is neither a literal nor a parameter of "
                "the module".format(decl["stages"])
            )
        entry["sync_stages"] = stages

        entry["parent_primitive"] = nearest_parent_primitive(hier)

        if problems:
            unknown.append(
                {"instance": hier, "module": orig, "reason": "; ".join(problems)}
            )
        crossings.append(entry)

    by_type: dict[str, int] = {}
    for c in crossings:
        by_type[c["type"]] = by_type.get(c["type"], 0) + 1

    return {
        "schema_version": SCHEMA_VERSION,
        "top": top,
        "files": files.as_posix(),
        "counts": {
            "crossings": len(crossings),
            "by_type": dict(sorted(by_type.items())),
            "unknown": len(unknown),
        },
        "crossings": crossings,
        "unknown": unknown,
    }


def print_table(report: dict) -> None:
    print(
        "[cdc-inventory] top={} files={}".format(report["top"], report["files"])
    )
    hdr = "{:<44} {:<18} {:<10} {:<10} {:>6} {:>7}".format(
        "INSTANCE", "TYPE", "SRC CLK", "DST CLK", "WIDTH", "STAGES"
    )
    print("  " + hdr)
    print("  " + "-" * len(hdr))
    for c in report["crossings"]:
        print(
            "  {:<44} {:<18} {:<10} {:<10} {:>6} {:>7}".format(
                c["instance"][-44:],
                c["type"],
                str(c.get("source_clock")),
                str(c.get("dest_clock")),
                str(c.get("width")),
                str(c.get("sync_stages")),
            )
        )
    print(
        "  {} crossings, {} unknown, by type: {}".format(
            report["counts"]["crossings"],
            report["counts"]["unknown"],
            ", ".join(
                "{}={}".format(k, v) for k, v in report["counts"]["by_type"].items()
            )
            or "(none)",
        )
    )
    for u in report["unknown"]:
        print("  UNKNOWN {}: {}".format(u["instance"], u["reason"]))


def main() -> int:
    p = argparse.ArgumentParser(
        description="Generate the SPEC 8 CDC inventory report.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--top", default=DEFAULT_TOP, help="top module to elaborate")
    p.add_argument(
        "--files", default=str(DEFAULT_FILES), help="Verilator -f file list"
    )
    p.add_argument("--out", default=str(DEFAULT_OUT), help="JSON output path")
    p.add_argument(
        "--rtl-dir",
        action="append",
        default=None,
        help="directory to scan for (* cdc_primitive *) declarations "
        "(repeatable; default: {})".format(", ".join(DEFAULT_RTL_DIRS)),
    )
    p.add_argument(
        "--verilator",
        default="verilator",
        help="verilator executable (default: verilator)",
    )
    p.add_argument("--print", dest="do_print", action="store_true",
                   help="print a human-readable table as well as the JSON")
    p.add_argument(
        "--strict",
        action="store_true",
        help="exit 1 when any crossing could not be classified",
    )
    args = p.parse_args()

    if shutil.which(args.verilator) is None:
        sys.exit(
            "ERROR: '{}' not found on PATH. The inventory elaborates the design "
            "with Verilator, which lives in WSL Ubuntu-24.04 (PLAN.md "
            "split-toolchain rule).".format(args.verilator)
        )

    rtl_dirs = [Path(d) for d in (args.rtl_dir or list(DEFAULT_RTL_DIRS))]
    catalog = scan_catalog(rtl_dirs)
    if not catalog:
        sys.exit(
            "ERROR: no (* cdc_primitive = ... *) declarations found under {}. "
            "Either the CDC primitives are missing or the attribute spelling "
            "changed.".format(", ".join(d.as_posix() for d in rtl_dirs))
        )

    files = Path(args.files)
    with tempfile.TemporaryDirectory() as tmp:
        xml_path = Path(tmp) / "cdc_inventory.xml"
        run_verilator_xml(args.verilator, args.top, files, xml_path)
        modules, roots = parse_netlist(xml_path)

    report = build_report(args.top, files, catalog, modules, roots)

    out_path = REPO_ROOT / args.out
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", encoding="utf-8", newline="\n") as fh:
        json.dump(report, fh, indent=2, sort_keys=False)
        fh.write("\n")

    if args.do_print:
        print_table(report)
    print(
        "[cdc-inventory] {} crossings, {} unknown -> {}".format(
            report["counts"]["crossings"], report["counts"]["unknown"], args.out
        )
    )

    if report["counts"]["crossings"] == 0:
        print(
            "ERROR: the inventory is empty; the design has no tagged crossings",
            file=sys.stderr,
        )
        return 1
    if args.strict and report["counts"]["unknown"] != 0:
        print(
            "ERROR: {} crossing(s) could not be classified; see the 'unknown' "
            "list above".format(report["counts"]["unknown"]),
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
