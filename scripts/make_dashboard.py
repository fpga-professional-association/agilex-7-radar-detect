#!/usr/bin/env python3
"""Render an HTML / Markdown dashboard from Quartus compile records (SPEC.md 17).

    python scripts/make_dashboard.py                     # every record
    python scripts/make_dashboard.py --format md         # Markdown output
    python scripts/make_dashboard.py --format html       # HTML output
    python scripts/make_dashboard.py --out dashboard.md  # write to file
    python scripts/make_dashboard.py path/*.json         # explicit inputs

Governing spec: SPEC.md 17 (Quartus Reporting record shape), SPEC.md 27
(``evidence/baseline/`` package).

Purpose
-------
One-page snapshot of every JSON record under ``results/timing/`` (or the
explicit list of files given as arguments), so a reader can see at a glance:

* the tool version and device for each compile;
* utilization (ALM / M20K / DSP percentages, plus counts);
* Fmax and worst-slack per clock;
* seed and commit for reproducibility.

The dashboard is DETERMINISTIC: same inputs, same output bytes. Records are
sorted by their ``timestamp`` field so the timeline reads chronologically.

Format
------
* ``--format md`` (default): GitHub-flavoured Markdown tables. Fits in a
  pull-request comment or a repo README section. No dependency beyond
  stdlib.
* ``--format html``: a small self-contained HTML page (inline CSS, no
  external assets). Fits under 20 KB even with a dozen records.

Runs on stdlib alone (validated on CPython 3.12 under WSL and 3.14 on
Windows -- same targets as parse_quartus.py).
"""

from __future__ import annotations

import argparse
import html
import json
import sys
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_INPUT_GLOB = "results/timing/compile_*.json"


def _load(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as fh:
        return json.load(fh)


def _fmt(value: Any, unit: str = "", nd: int = 2) -> str:
    if value is None:
        return "--"
    if isinstance(value, bool):
        return "yes" if value else "no"
    if isinstance(value, float):
        return f"{value:.{nd}f}{unit}"
    if isinstance(value, int):
        return f"{value:,}{unit}"
    return f"{value}{unit}"


def _summary_row(rec: dict) -> dict[str, Any]:
    """Extract a flat summary row from one compile record."""
    util = rec.get("utilization") or {}
    clocks = rec.get("clocks") or {}

    # Pick the WORST WNS across clocks, and the LOWEST Fmax across clocks --
    # those are the numbers a reader wants at a glance. If no timing data,
    # leave them None.
    wns_values = [c.get("wns_ns") for c in clocks.values()
                  if isinstance(c, dict) and isinstance(c.get("wns_ns"),
                                                        (int, float))]
    fmax_values = [c.get("fmax_mhz") for c in clocks.values()
                   if isinstance(c, dict) and isinstance(c.get("fmax_mhz"),
                                                         (int, float))]

    return {
        "commit": rec.get("commit") or "?",
        "seed": rec.get("seed"),
        "configuration": rec.get("configuration") or "?",
        "quartus_version": rec.get("quartus_version") or "?",
        "device": rec.get("device") or "?",
        "timestamp": rec.get("timestamp") or "",
        "stage": rec.get("stage") or rec.get("stage_requested") or "",
        "stages_completed": rec.get("stages_completed") or [],
        "compile_seconds": rec.get("compile_seconds"),
        "peak_memory_mb": rec.get("peak_memory_mb"),
        "alm_percent": util.get("alm_percent"),
        "alm_used": util.get("alm_used"),
        "m20k_percent": util.get("m20k_percent"),
        "m20k": util.get("m20k"),
        "dsp_percent": util.get("dsp_percent"),
        "dsp": util.get("dsp"),
        "worst_wns_ns": min(wns_values) if wns_values else None,
        "lowest_fmax_mhz": min(fmax_values) if fmax_values else None,
        "unconstrained_paths": rec.get("unconstrained_paths"),
        "errors": rec.get("errors"),
        "clocks": clocks,
        "record": rec,
    }


def _render_markdown(rows: list[dict]) -> str:
    lines: list[str] = []
    lines.append("# Quartus compile dashboard")
    lines.append("")
    lines.append("SPEC.md 17 per-compile records under `results/timing/`. "
                 "Regenerate with `python scripts/make_dashboard.py "
                 "--format md`.")
    lines.append("")
    lines.append("## Summary")
    lines.append("")
    lines.append(
        "| # | timestamp | commit | seed | config | ALM % | M20K % | DSP % | "
        "worst WNS (ns) | lowest Fmax (MHz) | compile (s) |")
    lines.append(
        "|---|-----------|--------|------|--------|-------|--------|-------|"
        "---------------|-------------------|-------------|")
    for i, r in enumerate(rows):
        commit_short = str(r["commit"])[:12]
        lines.append(
            f"| {i + 1} | {r['timestamp']} | `{commit_short}` | "
            f"{r['seed']} | {r['configuration']} | "
            f"{_fmt(r['alm_percent'], nd=1)} | "
            f"{_fmt(r['m20k_percent'], nd=1)} | "
            f"{_fmt(r['dsp_percent'], nd=1)} | "
            f"{_fmt(r['worst_wns_ns'], nd=3)} | "
            f"{_fmt(r['lowest_fmax_mhz'], nd=1)} | "
            f"{_fmt(r['compile_seconds'], nd=1)} |"
        )
    lines.append("")

    lines.append("## Per-record detail")
    lines.append("")
    for i, r in enumerate(rows):
        lines.append(f"### Record {i + 1} -- {r['configuration']} "
                     f"(seed {r['seed']}, commit {str(r['commit'])[:12]})")
        lines.append("")
        lines.append(f"- Quartus: {r['quartus_version']}")
        lines.append(f"- Device: {r['device']}")
        lines.append(f"- Timestamp: {r['timestamp']}")
        lines.append(f"- Stage: {r['stage']}  "
                     f"(completed: {', '.join(r['stages_completed']) or 'n/a'})")
        lines.append(f"- Compile wall clock: {_fmt(r['compile_seconds'], ' s', 1)}")
        lines.append(f"- Peak memory: {_fmt(r['peak_memory_mb'], ' MB')}")
        lines.append(f"- Errors: {_fmt(r['errors'])}")
        lines.append(f"- Unconstrained paths: {_fmt(r['unconstrained_paths'])}")
        lines.append("")
        lines.append("**Utilization**")
        lines.append("")
        lines.append("| resource | used | %device |")
        lines.append("|----------|------|---------|")
        util = r["record"].get("utilization") or {}
        for label, used_key, pct_key in (
            ("ALMs", "alm_used", "alm_percent"),
            ("ALM registers", "alm_registers", "alm_reg_percent"),
            ("M20K", "m20k", "m20k_percent"),
            ("DSP", "dsp", "dsp_percent"),
            ("MLAB", "mlab", None),
            ("RAM bits", "ram_bits", None),
            ("Virtual pins", "virtual_pins", None),
        ):
            u = util.get(used_key)
            p = util.get(pct_key) if pct_key else None
            if u is None and p is None:
                continue
            lines.append(
                f"| {label} | {_fmt(u)} | {_fmt(p, ' %', 1) if p is not None else '--'} |"
            )
        lines.append("")

        clocks = r["clocks"] or {}
        if clocks:
            lines.append("**Timing per clock**")
            lines.append("")
            lines.append(
                "| clock | constraint (MHz) | Fmax (MHz) | WNS (ns) | "
                "TNS (ns) | failing setup | source -> destination |")
            lines.append(
                "|-------|------------------|------------|----------|"
                "----------|---------------|-----------------------|")
            for name, c in clocks.items():
                src = c.get("source_hierarchy") or "?"
                dst = c.get("destination_hierarchy") or "?"
                lines.append(
                    f"| `{name}` | "
                    f"{_fmt(c.get('constraint_mhz'), nd=1)} | "
                    f"{_fmt(c.get('fmax_mhz'), nd=1)} | "
                    f"{_fmt(c.get('wns_ns'), nd=3)} | "
                    f"{_fmt(c.get('tns_ns'), nd=3)} | "
                    f"{_fmt(c.get('failing_paths_setup'))} | "
                    f"`{src}` -> `{dst}` |"
                )
            lines.append("")
        else:
            lines.append("*Timing not available in this record (map-only or STA-not-run).*")
            lines.append("")

        integ = r["record"].get("constraints_integrity") or {}
        if integ:
            lines.append("**Constraints integrity (SPEC.md 24)**")
            lines.append("")
            lines.append(
                f"- false_paths: {_fmt(integ.get('false_paths'))}  "
                f"multicycle_paths: {_fmt(integ.get('multicycle_paths'))}  "
                f"clock_groups: {_fmt(integ.get('clock_groups'))}"
            )
            lines.append(
                f"- disabled_arcs: {_fmt(integ.get('disabled_arcs'))}  "
                f"unconstrained_paths: {_fmt(integ.get('unconstrained_paths'))}"
            )
            lines.append("")

        notes = r["record"].get("notes") or []
        if notes:
            lines.append("**Notes**")
            lines.append("")
            for n in notes:
                lines.append(f"- {n}")
            lines.append("")

    return "\n".join(lines) + "\n"


def _render_html(rows: list[dict]) -> str:
    """Small self-contained HTML page (no external assets)."""
    css = """
    body { font-family: -apple-system, "Segoe UI", Roboto, Helvetica, sans-serif;
           color: #1c1e21; background: #f6f7f9; margin: 0; padding: 24px; }
    h1, h2, h3 { color: #1a1a1a; }
    table { border-collapse: collapse; margin-bottom: 24px; background: #fff;
            box-shadow: 0 1px 3px rgba(0,0,0,.08); }
    th, td { border: 1px solid #d0d0d5; padding: 6px 10px; text-align: right;
             font-size: 13px; }
    th { background: #eef1f4; text-align: left; }
    td.k, th.k { text-align: left; font-family: SFMono-Regular, Menlo, Consolas,
                                       monospace; }
    .warn { color: #b1431c; font-weight: bold; }
    .ok   { color: #1e8449; font-weight: bold; }
    """
    out: list[str] = []
    out.append("<!DOCTYPE html>")
    out.append("<html><head><meta charset='utf-8'>")
    out.append("<title>Quartus compile dashboard</title>")
    out.append(f"<style>{css}</style>")
    out.append("</head><body>")
    out.append("<h1>Quartus compile dashboard</h1>")
    out.append(
        "<p>SPEC.md 17 per-compile records. Regenerate with "
        "<code>python scripts/make_dashboard.py --format html</code>.</p>"
    )

    out.append("<h2>Summary</h2>")
    out.append("<table>")
    out.append(
        "<tr><th>#</th><th>timestamp</th><th>commit</th><th>seed</th>"
        "<th>config</th><th>ALM %</th><th>M20K %</th><th>DSP %</th>"
        "<th>worst WNS (ns)</th><th>lowest Fmax (MHz)</th>"
        "<th>compile (s)</th></tr>"
    )
    for i, r in enumerate(rows):
        commit_short = str(r["commit"])[:12]
        wns = r["worst_wns_ns"]
        wns_cls = "warn" if isinstance(wns, (int, float)) and wns < 0 else "ok"
        out.append(
            f"<tr><td>{i + 1}</td>"
            f"<td>{html.escape(str(r['timestamp']))}</td>"
            f"<td class='k'>{html.escape(commit_short)}</td>"
            f"<td>{html.escape(str(r['seed']))}</td>"
            f"<td class='k'>{html.escape(str(r['configuration']))}</td>"
            f"<td>{_fmt(r['alm_percent'], nd=1)}</td>"
            f"<td>{_fmt(r['m20k_percent'], nd=1)}</td>"
            f"<td>{_fmt(r['dsp_percent'], nd=1)}</td>"
            f"<td class='{wns_cls}'>{_fmt(r['worst_wns_ns'], nd=3)}</td>"
            f"<td>{_fmt(r['lowest_fmax_mhz'], nd=1)}</td>"
            f"<td>{_fmt(r['compile_seconds'], nd=1)}</td></tr>"
        )
    out.append("</table>")

    out.append("<h2>Per-record detail</h2>")
    for i, r in enumerate(rows):
        out.append(
            f"<h3>Record {i + 1} &mdash; "
            f"{html.escape(str(r['configuration']))} "
            f"(seed {html.escape(str(r['seed']))}, "
            f"commit {html.escape(str(r['commit'])[:12])})</h3>"
        )
        out.append("<ul>")
        out.append(f"<li>Quartus: {html.escape(str(r['quartus_version']))}</li>")
        out.append(f"<li>Device: {html.escape(str(r['device']))}</li>")
        out.append(f"<li>Timestamp: {html.escape(str(r['timestamp']))}</li>")
        out.append(
            f"<li>Stage: {html.escape(str(r['stage']))} (completed: "
            f"{html.escape(', '.join(r['stages_completed']) or 'n/a')})</li>"
        )
        out.append(
            f"<li>Compile wall clock: {_fmt(r['compile_seconds'], ' s', 1)}</li>"
        )
        out.append(
            f"<li>Peak memory: {_fmt(r['peak_memory_mb'], ' MB')}</li>"
        )
        out.append(f"<li>Errors: {_fmt(r['errors'])}</li>")
        out.append(
            f"<li>Unconstrained paths: {_fmt(r['unconstrained_paths'])}</li>"
        )
        out.append("</ul>")

        out.append("<h4>Utilization</h4>")
        out.append("<table>")
        out.append("<tr><th>resource</th><th>used</th><th>%device</th></tr>")
        util = r["record"].get("utilization") or {}
        for label, used_key, pct_key in (
            ("ALMs", "alm_used", "alm_percent"),
            ("ALM registers", "alm_registers", "alm_reg_percent"),
            ("M20K", "m20k", "m20k_percent"),
            ("DSP", "dsp", "dsp_percent"),
            ("MLAB", "mlab", None),
            ("RAM bits", "ram_bits", None),
            ("Virtual pins", "virtual_pins", None),
        ):
            u = util.get(used_key)
            p = util.get(pct_key) if pct_key else None
            if u is None and p is None:
                continue
            out.append(
                f"<tr><td class='k'>{html.escape(label)}</td>"
                f"<td>{_fmt(u)}</td>"
                f"<td>{_fmt(p, ' %', 1) if p is not None else '--'}</td></tr>"
            )
        out.append("</table>")

        clocks = r["clocks"] or {}
        if clocks:
            out.append("<h4>Timing per clock</h4>")
            out.append("<table>")
            out.append(
                "<tr><th>clock</th><th>constraint (MHz)</th>"
                "<th>Fmax (MHz)</th><th>WNS (ns)</th><th>TNS (ns)</th>"
                "<th>failing setup</th><th>source -> destination</th></tr>"
            )
            for name, c in clocks.items():
                wns = c.get("wns_ns")
                wns_cls = "warn" if (isinstance(wns, (int, float)) and wns < 0) else "ok"
                src = html.escape(str(c.get("source_hierarchy") or "?"))
                dst = html.escape(str(c.get("destination_hierarchy") or "?"))
                out.append(
                    f"<tr><td class='k'>{html.escape(name)}</td>"
                    f"<td>{_fmt(c.get('constraint_mhz'), nd=1)}</td>"
                    f"<td>{_fmt(c.get('fmax_mhz'), nd=1)}</td>"
                    f"<td class='{wns_cls}'>{_fmt(wns, nd=3)}</td>"
                    f"<td>{_fmt(c.get('tns_ns'), nd=3)}</td>"
                    f"<td>{_fmt(c.get('failing_paths_setup'))}</td>"
                    f"<td class='k'>{src} &rarr; {dst}</td></tr>"
                )
            out.append("</table>")
        else:
            out.append("<p><em>Timing not available (map-only / STA-not-run).</em></p>")

        notes = r["record"].get("notes") or []
        if notes:
            out.append("<h4>Notes</h4><ul>")
            for n in notes:
                out.append(f"<li>{html.escape(str(n))}</li>")
            out.append("</ul>")

    out.append("</body></html>")
    return "\n".join(out) + "\n"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description=(
            "Render a compact dashboard of every Quartus compile record "
            "under results/timing/ (SPEC.md 17)."
        )
    )
    ap.add_argument("inputs", nargs="*",
                    help=(
                        "compile record JSON files. If omitted, every "
                        f"{DEFAULT_INPUT_GLOB} is used."
                    ))
    ap.add_argument("--format", choices=("md", "html"), default="md",
                    help="output format (default: md)")
    ap.add_argument("--out", "-o", type=str, default=None,
                    help="write output to this file (default: stdout)")
    args = ap.parse_args(argv)

    if args.inputs:
        paths = [Path(p) for p in args.inputs]
    else:
        paths = sorted((REPO_ROOT).glob(DEFAULT_INPUT_GLOB))

    if not paths:
        print("ERROR: no compile records found. Point at explicit files "
              f"or place them under {DEFAULT_INPUT_GLOB}.",
              file=sys.stderr)
        return 2

    rows: list[dict] = []
    for p in paths:
        try:
            rec = _load(p)
        except json.JSONDecodeError as exc:
            print(f"ERROR: {p}: {exc}", file=sys.stderr)
            continue
        if not isinstance(rec, dict):
            print(f"ERROR: {p}: not a JSON object", file=sys.stderr)
            continue
        rows.append(_summary_row(rec))

    if not rows:
        print("ERROR: no valid records loaded", file=sys.stderr)
        return 2

    # Deterministic order: by timestamp then commit.
    rows.sort(key=lambda r: (r["timestamp"], r["commit"], r["seed"] or 0))

    if args.format == "md":
        text = _render_markdown(rows)
    else:
        text = _render_html(rows)

    if args.out:
        Path(args.out).write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
