#!/usr/bin/env python3
"""Summarise Yosys `stat -json` output (scripts/synth.ys) as Markdown tables.

usage: synth_report.py <generic.json> <xc7_soc.json> <xc7_mac.json>
"""
import json
import re
import sys


def load(path):
    with open(path) as f:
        return json.load(f)


def clean(name):
    name = name.lstrip("\\")
    m = re.match(r"\$paramod\\([^\\]+)", name)       # $paramod\picorv32_axi\ENABLE...
    if m:
        return m.group(1)
    m = re.match(r"\$paramod\$[0-9a-f]+\\(.+)", name)  # hashed parameter sets
    return m.group(1) if m else name


def is_seq(cell):
    return any(k in cell for k in ("DFF", "DLATCH", "SR_")) or re.match(r"^FD[A-Z]{2}$", cell) is not None


def cells_of(entry):
    return entry.get("num_cells_by_type", {})


def generic_table(js):
    rows = []
    for name, mod in js["modules"].items():
        by = cells_of(mod)
        if not by:
            continue
        leaf = {k: v for k, v in by.items() if k.startswith("$_")}
        seq = sum(v for k, v in leaf.items() if is_seq(k))
        comb = sum(leaf.values()) - seq
        sub = {clean(k): v for k, v in by.items() if not k.startswith("$_")}
        rows.append((clean(name), sum(leaf.values()), seq, comb, sub))
    print("### Generic gates (Yosys `synth`, hierarchy kept; cells local to each module)\n")
    print("| module | cells | sequential | combinational | instantiates |")
    print("|---|---:|---:|---:|---|")
    for n, t, s, c, sub in sorted(rows, key=lambda r: -r[1]):
        inst = ", ".join(f"{k} x{v}" for k, v in sub.items()) or "-"
        print(f"| {n} | {t} | {s} | {c} | {inst} |")
    d = js.get("design")
    if d:
        by = cells_of(d)
        leaf = {k: v for k, v in by.items() if k.startswith("$_")}
        seq = sum(v for k, v in leaf.items() if is_seq(k))
        print(f"| **soc_top total** (excl. ROM/RAM arrays) | **{sum(leaf.values())}** | **{seq}** "
              f"| **{sum(leaf.values()) - seq}** | |")
    print()


def xc7_summary(js):
    d = js.get("design") or next(iter(js["modules"].values()))
    by = cells_of(d)
    grp = {
        "LUT": sum(v for k, v in by.items() if re.match(r"^LUT\d$", k)),
        "FF": sum(v for k, v in by.items() if re.match(r"^FD[A-Z]{2}$", k)),
        "CARRY4": by.get("CARRY4", 0),
        "DSP48E1": by.get("DSP48E1", 0),
        "LUTRAM": sum(v for k, v in by.items() if k.startswith("RAM")),
        "SRL": sum(v for k, v in by.items() if k.startswith("SRL")),
        "MUXF7/8": by.get("MUXF7", 0) + by.get("MUXF8", 0),
    }
    return grp


xs = {"soc_top (CPU + bus + MAC + UART)": load(sys.argv[2]), "mac_axil (MAC peripheral only)": load(sys.argv[3])}
generic_table(load(sys.argv[1]))
print("### AMD 7-series (Zynq-7000 fabric) estimate (Yosys `synth_xilinx -family xc7`, no place & route)\n")
cols = list(xc7_summary(next(iter(xs.values()))).keys())
print("| design | " + " | ".join(cols) + " |")
print("|---|" + "---:|" * len(cols))
for name, js in xs.items():
    g = xc7_summary(js)
    print(f"| {name} | " + " | ".join(str(g[c]) for c in cols) + " |")
print()
