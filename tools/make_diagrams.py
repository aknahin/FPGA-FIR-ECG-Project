#!/usr/bin/env python3
"""Draw the block diagrams used in the report: system, FIR pipeline and state machine.

    python3 tools/make_diagrams.py

Writes fig/diagram_system.png, fig/diagram_pipeline.png and fig/diagram_fsm.png.
"""
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, Circle

FIG = Path(__file__).resolve().parent.parent / "fig"
COLORS = {"logic": "#dbe8f7", "mem": "#fbe3c4", "core": "#d5efd5", "reg": "#fff3b0", "io": "#eeeeee"}


def box(ax, x, y, w, h, text, kind="logic", fontsize=8):
    """A rounded box centred at (x, y)."""
    ax.add_patch(FancyBboxPatch((x - w / 2, y - h / 2), w, h, boxstyle="round,pad=0.02,rounding_size=0.06",
                                fc=COLORS[kind], ec="black", lw=1))
    ax.text(x, y, text, ha="center", va="center", fontsize=fontsize)
    return (x, y, w, h)


def arrow(ax, p, q, label=None, label_pos=0.5, dy=0.12, fontsize=7, dx=0.0, ha="center"):
    ax.annotate("", xy=q, xytext=p, arrowprops=dict(arrowstyle="-|>", lw=1, color="black"))
    if label:
        mx = p[0] + (q[0] - p[0]) * label_pos + dx
        my = p[1] + (q[1] - p[1]) * label_pos + dy
        ax.text(mx, my, label, ha=ha, va="bottom", fontsize=fontsize)


def right(b):
    return (b[0] + b[2] / 2, b[1])


def left(b):
    return (b[0] - b[2] / 2, b[1])


def top(b):
    return (b[0], b[1] + b[3] / 2)


def bottom(b):
    return (b[0], b[1] - b[3] / 2)


def new_figure(w, h, xlim, ylim):
    fig, ax = plt.subplots(figsize=(w, h))
    ax.set_xlim(*xlim)
    ax.set_ylim(*ylim)
    ax.axis("off")
    return fig, ax


def system():
    fig, ax = new_figure(7.2, 2.8, (0, 12), (0, 4.6))
    strobe = box(ax, 1.2, 3.7, 1.8, 0.9, "Sample strobe\n360 Hz")
    ctrl = box(ax, 1.2, 1.9, 1.8, 1.1, "Control\n(fir_top)")
    rom = box(ax, 4.3, 3.7, 2.0, 0.9, "ECG ROM\n1024 x 16", "mem")
    ref = box(ax, 4.3, 0.5, 2.0, 0.9, "Reference ROM\n1024 x 16", "mem")
    fir = box(ax, 7.2, 3.7, 2.0, 1.1, "FIR core\nfir_mac, 63 taps", "core")
    cmp_ = box(ax, 7.2, 1.9, 2.0, 1.1, "Compare\n+ LEDs")
    eth = box(ax, 10.2, 1.9, 2.0, 1.1, "UDP / Ethernet\ntransmitter")
    pc = box(ax, 10.2, 0.5, 2.0, 0.8, "PC capture\n(Python)", "io")
    arrow(ax, bottom(strobe), top(ctrl), "strobe", 0.5, 0.0)
    arrow(ax, (ctrl[0] + 0.9, ctrl[1] + 0.3), (rom[0] - 1.0, rom[1] - 0.2), "address", 0.5, 0.05)
    arrow(ax, right(rom), left(fir), "x", 0.5, 0.05)
    arrow(ax, (ctrl[0] + 0.9, ctrl[1] - 0.3), (ref[0] - 1.0, ref[1] + 0.2), "address", 0.5, -0.35)
    arrow(ax, bottom(fir), top(cmp_), "y", 0.5, -0.1, dx=0.12, ha="left")
    arrow(ax, (ref[0] + 1.0, ref[1] + 0.2), (cmp_[0] - 1.0, cmp_[1] - 0.3), "reference", 0.5, -0.45, dx=0.35)
    arrow(ax, right(cmp_), left(eth), "result", 0.5, 0.05)
    arrow(ax, bottom(eth), top(pc), "MII", 0.5, -0.12, dx=0.12, ha="left")
    ax.text(0.05, 4.45, "100 MHz clock domain (all blocks except the PHY side of the transmitter)", fontsize=7, style="italic")
    fig.savefig(FIG / "diagram_system.png", dpi=220, bbox_inches="tight")
    plt.close(fig)


def pipeline():
    fig, ax = new_figure(7.2, 2.3, (0, 13), (0, 3.6))
    hist = box(ax, 1.3, 2.7, 2.0, 0.9, "History\n63 x 16 bit", "mem")
    coef = box(ax, 1.3, 0.8, 2.0, 0.9, "Coefficients\n63 x 16 bit", "mem")
    hr = box(ax, 3.6, 2.7, 1.0, 0.8, "h_r", "reg")
    cr = box(ax, 3.6, 0.8, 1.0, 0.8, "c_r", "reg")
    mul = box(ax, 5.5, 1.75, 1.5, 1.0, "x\n16 x 16", "core")
    pr = box(ax, 7.4, 1.75, 1.0, 0.8, "p_r\n(0 if idle)", "reg", 7)
    acc = box(ax, 9.3, 1.75, 1.5, 1.0, "+ acc\n40 bit", "core")
    sat = box(ax, 11.4, 1.75, 1.7, 1.0, ">> 15\nsaturate")
    arrow(ax, right(hist), left(hr), "tap k", 0.5, 0.05)
    arrow(ax, right(coef), left(cr), "tap k", 0.5, 0.05)
    arrow(ax, right(hr), (mul[0] - 0.75, mul[1] + 0.25))
    arrow(ax, right(cr), (mul[0] - 0.75, mul[1] - 0.25))
    arrow(ax, right(mul), left(pr))
    arrow(ax, right(pr), left(acc))
    arrow(ax, right(acc), left(sat))
    arrow(ax, right(sat), (12.9, 1.75), "y", 0.5, 0.05)
    ax.text(3.6, 3.35, "stage 1", ha="center", fontsize=7, style="italic")
    ax.text(7.4, 2.4, "stage 2", ha="center", fontsize=7, style="italic")
    ax.text(9.3, 2.5, "stage 3", ha="center", fontsize=7, style="italic")
    fig.savefig(FIG / "diagram_pipeline.png", dpi=220, bbox_inches="tight")
    plt.close(fig)


def fsm():
    fig, ax = new_figure(7.2, 2.4, (0, 12), (0, 4.0))
    ax.set_aspect("equal")
    names = ["IDLE", "MAC", "FLUSH", "OUT"]
    xs = [1.4, 4.4, 7.4, 10.4]
    y0 = 2.0
    for x, n in zip(xs, names):
        ax.add_patch(Circle((x, y0), 0.7, fc=COLORS["logic"], ec="black", lw=1))
        ax.text(x, y0, n, ha="center", va="center", fontsize=9)
    labels = ["sample accepted", "tap 62 issued", "pipeline empty"]
    for i in range(3):
        arrow(ax, (xs[i] + 0.7, y0), (xs[i + 1] - 0.7, y0), labels[i], 0.5, 0.08)
    ax.text(xs[0] + 1.5, y0 - 0.3, "shift history,\nclear acc", ha="center", va="top", fontsize=6.5, style="italic")
    # self loop on MAC: one tap per clock
    ax.plot([xs[1] - 0.3, xs[1] - 0.3, xs[1] + 0.3], [y0 + 0.66, y0 + 1.25, y0 + 1.25], color="black", lw=1)
    ax.annotate("", xy=(xs[1] + 0.3, y0 + 0.68), xytext=(xs[1] + 0.3, y0 + 1.25),
                arrowprops=dict(arrowstyle="-|>", lw=1, color="black"))
    ax.text(xs[1], y0 + 1.32, "tap_count + 1 (63 clocks)", ha="center", va="bottom", fontsize=7)
    # return path OUT -> IDLE
    ax.plot([xs[3], xs[3], xs[0]], [y0 - 0.7, 0.6, 0.6], color="black", lw=1)
    ax.annotate("", xy=(xs[0], y0 - 0.72), xytext=(xs[0], 0.6), arrowprops=dict(arrowstyle="-|>", lw=1, color="black"))
    ax.text((xs[0] + xs[3]) / 2, 0.68, "OUT: shift, saturate, pulse out_valid for one clock", ha="center", va="bottom", fontsize=7)
    fig.savefig(FIG / "diagram_fsm.png", dpi=220, bbox_inches="tight")
    plt.close(fig)


if __name__ == "__main__":
    FIG.mkdir(exist_ok=True)
    system()
    pipeline()
    fsm()
    print("saved diagram_system.png, diagram_pipeline.png, diagram_fsm.png in", FIG)
