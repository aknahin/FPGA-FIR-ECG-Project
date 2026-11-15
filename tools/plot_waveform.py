#!/usr/bin/env python3
"""Draw simulation waveforms of the FIR filter from a VCD file (made by tb_fir_mac.v with +VCD).

    iverilog -g2012 -o sim_fir tb/tb_fir_mac.v rtl/fir_mac.v
    vvp sim_fir +VCD
    python3 tools/plot_waveform.py tb_fir_mac.vcd

Writes fig/sim_waveform.png (one complete sample) and fig/sim_waveform_end.png (last taps, flush and output).
No special VCD library is needed: the file format is simple text.
"""
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

ROOT = Path(__file__).resolve().parent.parent
STATE_NAMES = {0: "IDLE", 1: "MAC", 2: "OUT", 3: "FLUSH"}


def read_vcd(path):
    """Return {signal name: [(time_ns, value), ...]}. Values of buses are integers (unsigned)."""
    names = {}                       # id code -> full signal name
    changes = {}
    scope = []
    time_unit_ns = 1e-3              # default 1 ps
    t = 0
    lines = open(path).read().split("\n")
    i = 0
    while i < len(lines):
        parts = lines[i].split()
        i += 1
        if not parts:
            continue
        if parts[0] == "$timescale":
            text = " ".join(parts[1:])
            while "$end" not in text:
                text += " " + lines[i].strip()
                i += 1
            num = "".join(c for c in text.replace("$end", "") if c.isdigit())
            unit = text.replace("$end", "").replace(num, "").strip()
            time_unit_ns = int(num) * {"s": 1e9, "ms": 1e6, "us": 1e3, "ns": 1.0, "ps": 1e-3, "fs": 1e-6}[unit]
        elif parts[0] == "$scope":
            scope.append(parts[2])
        elif parts[0] == "$upscope":
            scope.pop()
        elif parts[0] == "$var":
            code, name = parts[3], parts[4]
            full = ".".join(scope + [name])
            names.setdefault(code, full)
            changes.setdefault(full, [])
        elif parts[0].startswith("#"):
            t = int(parts[0][1:]) * time_unit_ns
        elif parts[0][0] in "01xzXZ" and len(parts[0]) > 1 and parts[0][1:] in names:
            full = names[parts[0][1:]]
            changes[full].append((t, int(parts[0][0]) if parts[0][0] in "01" else 0))
        elif parts[0][0] == "b" and len(parts) == 2 and parts[1] in names:
            bits = parts[0][1:]
            value = int(bits, 2) if set(bits) <= {"0", "1"} else 0
            changes[names[parts[1]]].append((t, value))
    return changes


def value_at(series, t):
    last = 0
    for time, v in series:
        if time > t:
            break
        last = v
    return last


def to_signed(v, bits=16):
    return v - (1 << bits) if v >= (1 << (bits - 1)) else v


def draw(changes, t0, t1, title, path):
    """Stacked waveforms between t0 and t1 (ns)."""
    rows = [
        ("clk", "tb_fir_mac.clk", "bit"),
        ("in_valid", "tb_fir_mac.in_valid", "bit"),
        ("x (input)", "tb_fir_mac.x", "signed"),
        ("state", "tb_fir_mac.dut.state", "state"),
        ("tap_count", "tb_fir_mac.dut.tap_count", "unsigned"),
        ("busy", "tb_fir_mac.busy", "bit"),
        ("out_valid", "tb_fir_mac.out_valid", "bit"),
        ("y (output)", "tb_fir_mac.y", "signed"),
    ]
    fig, axes = plt.subplots(len(rows), 1, figsize=(10, 7.5), sharex=True)
    for ax, (label, name, kind) in zip(axes, rows):
        series = changes.get(name, [])
        times = [t0] + [t for t, _ in series if t0 < t < t1] + [t1]
        values = [value_at(series, t0)] + [v for t, v in series if t0 < t < t1]
        values.append(values[-1])
        if kind == "signed":
            values = [to_signed(v) for v in values]
        if kind == "state":
            values = [v for v in values]
        ax.step(times, values, where="post", lw=1.3, color="tab:blue" if kind != "bit" else "k")
        ax.set_ylabel(label, rotation=0, ha="right", va="center", fontsize=9)
        ax.grid(True, alpha=0.3)
        if kind == "bit":
            ax.set_ylim(-0.2, 1.3)
            ax.set_yticks([0, 1])
        elif kind == "state":
            ax.set_yticks(list(STATE_NAMES))
            ax.set_yticklabels([STATE_NAMES[k] for k in STATE_NAMES], fontsize=8)
        else:
            ax.tick_params(axis="y", labelsize=8)
    axes[-1].set_xlabel("Time (ns)")
    axes[0].set_title(title)
    axes[-1].set_xlim(t0, t1)
    fig.tight_layout()
    fig.savefig(path, dpi=200)
    plt.close(fig)
    print("saved", path.relative_to(ROOT))


def main():
    vcd = Path(sys.argv[1] if len(sys.argv) > 1 else "tb_fir_mac.vcd")
    changes = read_vcd(vcd)
    in_valid = changes["tb_fir_mac.in_valid"]
    out_valid = changes["tb_fir_mac.out_valid"]
    # take the 10th sample: well after reset, the history already holds data
    starts = [t for t, v in in_valid if v == 1]
    ends = [t for t, v in out_valid if v == 1]
    t_in, t_out = starts[9], [t for t in ends if t > starts[9]][0]
    print(f"sample 10: in_valid rises at {t_in:.0f} ns, out_valid rises at {t_out:.0f} ns "
          f"({(t_out - t_in) / 10:.0f} clocks)")
    draw(changes, t_in - 30, t_out + 60, "FIR filter simulation: one complete sample (input accepted to output valid)",
         ROOT / "fig" / "sim_waveform.png")
    draw(changes, t_out - 130, t_out + 40, "FIR filter simulation: last taps, pipeline flush and output",
         ROOT / "fig" / "sim_waveform_end.png")


if __name__ == "__main__":
    main()
