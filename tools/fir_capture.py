#!/usr/bin/env python3
"""Capture the filtered ECG that the FPGA sends over Ethernet and compare it with the Python reference.

The board sends one UDP packet (port 5005) per filtered sample. Payload, little-endian:
    byte 0 = 0xEC (marker), byte 1 = flags, bytes 2-3 = sample number,
    bytes 4-5 = FPGA output y, bytes 6-7 = Python reference, bytes 8-9 = noisy input (all signed 16 bit).

Usage (run from the project root, with the Mac Ethernet adapter set to 192.168.10.1):
    python3 tools/fir_capture.py            # capture, save data/fpga_output.csv, compare
    python3 tools/fir_capture.py --plot     # also save fig/fpga_capture.png and data/fpga_metrics.json
    python3 tools/fir_capture.py --selftest # check this script with fake packets, no board needed

Prints CAPTURE_PASS and exits 0 only if all 1024 samples arrived and every FPGA value equals the reference.
"""
import argparse
import json
import socket
import struct
import threading
import time
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
PORT = 5005
N = 1024
DELAY = 31          # group delay of the 63-tap linear-phase filter


def to_signed(word):
    return word - 65536 if word >= 32768 else word


def read_mem(path):
    """Read a .mem file (one 4-digit hex word per line) as signed integers."""
    return np.array([to_signed(int(line, 16)) for line in open(path) if line.strip()], dtype=np.int64)


def capture(timeout):
    """Collect packets until every sample number 0..1023 has been seen, or the timeout expires."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("", PORT))
    sock.settimeout(0.5)
    got = {}
    start = time.monotonic()
    while len(got) < N and time.monotonic() - start < timeout:
        try:
            data, peer = sock.recvfrom(2048)
        except socket.timeout:
            continue
        if len(data) < 10 or data[0] != 0xEC:
            continue
        idx, y, ref, x = struct.unpack_from("<Hhhh", data, 2)
        if idx < N and idx not in got:
            got[idx] = (x, y, ref)
    sock.close()
    return got


def selftest_sender(ref, x):
    """Pretend to be the board: send a packet for every sample, a few times over."""
    time.sleep(0.5)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    for _ in range(2):
        for i in range(N):
            payload = struct.pack("<BBHhhh", 0xEC, 1, i, int(ref[i]), int(ref[i]), int(x[i])) + bytes(10)
            sock.sendto(payload, ("127.0.0.1", PORT))
            if i % 64 == 0:
                time.sleep(0.001)


def metrics(noisy, fpga, clean):
    """MSE and SNR of the noisy input and of the filtered output, both against the clean ECG.
    The filter delays the signal by 31 samples, so output[n] is compared with clean[n-31]."""
    ref = clean[:N - DELAY]
    out = fpga[DELAY:].astype(float)
    inp = noisy[:N - DELAY].astype(float)
    mse = lambda a, b: float(np.mean((a - b) ** 2))
    snr = lambda r, e: float(10 * np.log10(np.sum(r ** 2) / np.sum((r - e) ** 2)))
    return {
        "mse_noisy": mse(inp, ref), "mse_filtered_fpga": mse(out, ref),
        "snr_noisy_db": snr(ref, inp), "snr_filtered_fpga_db": snr(ref, out),
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--timeout", type=float, default=20.0, help="seconds to wait for all 1024 samples")
    ap.add_argument("--plot", action="store_true", help="save fig/fpga_capture.png and data/fpga_metrics.json")
    ap.add_argument("--selftest", action="store_true", help="test this script with fake packets")
    args = ap.parse_args()

    ref_mem = read_mem(DATA / "expected.mem")
    in_mem = read_mem(DATA / "ecg.mem")

    if args.selftest:
        threading.Thread(target=selftest_sender, args=(ref_mem, in_mem), daemon=True).start()
        print("selftest: fake board sending packets to 127.0.0.1")
    else:
        print(f"listening on UDP port {PORT} for up to {args.timeout:.0f} s ...")

    got = capture(args.timeout)
    print(f"received {len(got)} of {N} different samples")
    if len(got) < N:
        missing = [i for i in range(N) if i not in got]
        print(f"missing sample numbers (first 10): {missing[:10]}")
        print("CAPTURE_FAIL")
        return 1

    noisy = np.array([got[i][0] for i in range(N)])
    fpga = np.array([got[i][1] for i in range(N)])
    ref_packet = np.array([got[i][2] for i in range(N)])

    out_csv = DATA / ("fpga_output_selftest.csv" if args.selftest else "fpga_output.csv")
    np.savetxt(out_csv, np.column_stack([np.arange(N), noisy, fpga, ref_mem]), fmt="%d", delimiter=",",
               header="sample,noisy_input,fpga_output,python_reference", comments="")
    print(f"saved {out_csv.relative_to(ROOT)}")

    diff_ref = int(np.sum(fpga != ref_mem))
    diff_in = int(np.sum(noisy != in_mem))
    diff_pkt = int(np.sum(ref_packet != ref_mem))
    print(f"FPGA output vs Python reference: {diff_ref} differences")
    print(f"noisy input in packets vs ecg.mem: {diff_in} differences, reference in packets vs expected.mem: {diff_pkt}")

    if args.plot:
        dataset = ROOT / "dataset" / "ecg_fir_data_full.csv"
        table = np.genfromtxt(dataset, delimiter=",", names=True, dtype=None, encoding=None)
        clean = np.asarray(table["clean_ecg"], dtype=float)
        result = metrics(noisy, fpga, clean)
        result["differences_vs_reference"] = diff_ref
        name = "fpga_metrics_selftest.json" if args.selftest else "fpga_metrics.json"
        (DATA / name).write_text(json.dumps(result, indent=2))
        for key, value in result.items():
            print(f"  {key}: {value:.4g}" if isinstance(value, float) else f"  {key}: {value}")
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        t = np.arange(N) / 360.0
        plt.figure(figsize=(10, 4))
        plt.plot(t, noisy, color="0.7", label="Noisy input")
        plt.plot(t[:N - DELAY], clean[:N - DELAY], "g--", lw=1, label="Clean ECG")
        plt.plot(t[:N - DELAY], fpga[DELAY:], "r", lw=1.2, label="FPGA output (shifted back 31 samples)")
        plt.xlabel("Time (s)")
        plt.ylabel("ECG amplitude (ADC units)")
        plt.title("Filtered ECG captured from the FPGA over Ethernet")
        plt.legend()
        plt.grid(True)
        plt.tight_layout()
        fig_path = ROOT / "fig" / ("fpga_capture_selftest.png" if args.selftest else "fpga_capture.png")
        fig_path.parent.mkdir(exist_ok=True)
        plt.savefig(fig_path, dpi=200)
        print(f"saved {fig_path.relative_to(ROOT)}")

    if diff_ref == 0 and diff_in == 0 and diff_pkt == 0:
        print("CAPTURE_PASS")
        return 0
    print("CAPTURE_FAIL")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
