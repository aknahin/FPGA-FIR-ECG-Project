# FPGA-Based Digital FIR Filter for Biomedical ECG Signal Denoising

A 63-tap, 16-bit fixed-point low-pass FIR filter (20 Hz cutoff, 360 Hz sampling) that removes noise from a prerecorded
ECG signal. The filter is designed in Python and written in Verilog. It runs on a Digilent Nexys 3
(Spartan-6 XC6SLX16). The board holds 1024 noisy ECG samples in block RAM, filters them at 360 samples per second,
checks every output against the Python reference, and sends the filtered ECG to a PC over Ethernet.

```
noisy ECG (ROM) -> 360 Hz strobe -> 16-bit FIR, 63 taps -> filtered ECG -> compare with Python -> LEDs
                                                                      \-> UDP packets over Ethernet -> PC
```

The full write-up is in `Project-Report/access.pdf`. The project description is
`Project-Report/FPGA_FIR_ECG_Project_One_Page_Updated.pdf`.

## Results

| Item | Result |
|---|---|
| RTL vs Python reference (ECG data and 7 stress vectors) | 0 mismatches in 1024 samples each |
| FPGA output captured over Ethernet vs Python reference | 1024 of 1024 samples equal, in 3 captures |
| SNR against the clean ECG | -0.92 dB (noisy input) to 6.76 dB (filtered) |
| MSE | 5.42e6 to 9.26e5 |
| Noise power | reduced by 16.3 dB |
| Resources (XC6SLX16) | 1191 LUTs, 1824 flip-flops, 1 DSP48A1, 2 block RAMs |
| Timing at 100 MHz | worst negative slack +2.719 ns (minimum period 7.281 ns) |
| Latency | 66 clock cycles per sample (277,778 are available per 360 Hz sample) |

## Folder layout

| Path | Contents |
|---|---|
| `py/FIR_filter.ipynb` | Python: filter design, coefficient quantization, bit-exact fixed-point model, test vectors, metrics |
| `rtl/` | Verilog: `fir_mac.v` (filter), `sample_strobe.v`, `ecg_rom.v`, `fir_top.v` (top level), `eth_udp_tx.v` |
| `tb/` | Self-checking testbenches: `tb_fir_mac.v` (filter only), `tb_fir_top.v` (whole system, including Ethernet frames) |
| `data/` | `.mem` files for the ECG, coefficients, reference output and 7 extra test vectors; metrics; the output captured from the FPGA |
| `dataset/` | ECG data supplied with the project, `ecg_fir_data_full.csv` (1024 samples at 360 Hz) |
| `fpga/` | `fir.ucf` (pin constraints), `build_fir.sh` (ISE build), `program.sh` (load the bitstream) |
| `tools/` | `fir_capture.py` (receive the filtered ECG from the board), `plot_waveform.py`, `make_diagrams.py` |
| `artifacts/fir/` | Bitstream `top.bit`, timing report, synthesis log, place-and-route report |
| `fig/` | Plots used in the report |
| `Project-Report/` | IEEE Access style LaTeX report (`access.tex`) and the built `access.pdf` |

## Requirements

- Python 3 with the packages in `requirements.txt`: `pip install -r requirements.txt`
- Icarus Verilog (`iverilog`, `vvp`) for simulation. GTKWave is optional.
- Xilinx ISE 14.6 and a Digilent Nexys 3 board for the FPGA part.
- A LaTeX installation with `latexmk` to build the report.

## 1. Python: filter design and reference data

```sh
jupyter notebook py/FIR_filter.ipynb
```

Run all cells. The notebook:

1. designs the filter with `scipy.signal.firwin` (Hamming window, 63 taps, 20 Hz at 360 Hz),
2. rounds the coefficients to signed 16-bit Q15 and measures the effect on the frequency response,
3. runs a bit-exact integer model of the hardware (40-bit sum, one arithmetic shift by 15, saturation to 16 bits),
4. checks the accumulator bound,
5. writes the `.mem` files, the extra test vectors and the metrics into `data/`, and the plots into `fig/`.

Each `.mem` file has one 4-digit hex word per line. Negative numbers are two's complement.

## 2. Simulation (Icarus Verilog)

Run every command from the project root. The `.mem` paths (`data/...`) are relative to it.

Filter only. This feeds 1024 samples and compares each output with the Python reference:

```sh
iverilog -g2012 -o sim_fir tb/tb_fir_mac.v rtl/fir_mac.v
vvp sim_fir                                                           # prints PASS
vvp sim_fir +IN=data/impulse_in.mem +EXP=data/impulse_expected.mem    # any other test vector
vvp sim_fir +VCD                                                      # also writes tb_fir_mac.vcd
```

The test vectors are `impulse`, `positive_step`, `negative_step`, `extreme_values`, `random_values`, `clamp_positive`
and `clamp_negative`. Each has `data/<name>_in.mem` and `data/<name>_expected.mem`.

Whole system. This runs the ROMs, strobe, filter, comparison and Ethernet transmitter. The testbench decodes every
Ethernet frame and checks the headers, the CRC and every value. It also checks that a second run is identical:

```sh
iverilog -g2012 -o sim_top tb/tb_fir_top.v rtl/fir_top.v rtl/fir_mac.v rtl/sample_strobe.v rtl/ecg_rom.v rtl/eth_udp_tx.v
vvp sim_top                                                           # prints ALL TESTS PASSED
```

Waveform figures from the VCD file:

```sh
python3 tools/plot_waveform.py tb_fir_mac.vcd
```

## 3. Implementation (Xilinx ISE 14.6)

The scripts in `fpga/` copy the design to a Linux virtual machine over SSH, build it there with ISE, and fetch the
bitstream. They were written for the author's setup (UTM virtual machine, host `192.168.64.2`, key
`~/.ssh/utm_fpga_ecdsa`). Change the `SSH` and `SCP` lines at the top of each script for a different setup.

```sh
bash fpga/build_fir.sh        # about 8 minutes; writes artifacts/fir/top.bit, timing.twr, top.par, synthesis.log
```

Without the scripts, run the ISE tools in a folder that contains `data/coeff.mem`, `data/ecg.mem` and
`data/expected.mem` (the tools read `$readmemh` files relative to the folder where they run):

```sh
xst -ifn top.xst -ofn synthesis.log          # top.xst: -top fir_top -p xc6slx16-3-csg324, sources from rtl/
ngdbuild -p xc6slx16-3-csg324 -uc fpga/fir.ucf top.ngc top.ngd
map -w -p xc6slx16-3-csg324 -o top_map.ncd top.ngd top.pcf
par -w top_map.ncd top.ncd top.pcf
trce -v 10 -o timing.twr top.ncd top.pcf
bitgen -w -g StartUpClk:JtagClk -g UnusedPin:Pullnone top.ncd top.bit top.pcf
```

Check `timing.twr` for "0 timing errors" before programming.

## 4. Run on the board

Plug the USB cable into the **USB PROG** port and an Ethernet cable from the board to the PC. Load the bitstream:

```sh
bash fpga/program.sh          # prints PROGRAM_OK; the configuration is lost at power-off
```

The design starts by itself. Controls and LEDs:

| Control | Function |
|---|---|
| BTNU | reset and restart the run |
| SW0 up | fast self-test (samples are fed much faster than 360 Hz, so Ethernet frames are dropped) |
| SW1 up | stop after one run (by default the run repeats every 3.5 s) |

| LED | Meaning |
|---|---|
| LD0 | run in progress (about 2.8 s) |
| LD1 | run finished |
| LD2 | PASS: all 1024 outputs equal the Python reference |
| LD3 | FAIL: at least one output differs |
| LD4 to LD7 | number of mismatches, up to 15 |

A good run shows LD0 on, then LD1 and LD2 on, and repeats. Put SW1 up and press BTNU to hold the PASS state.

## 5. Capture the filtered ECG on the PC

Give the Ethernet adapter the fixed address `192.168.10.1` with subnet mask `255.255.255.0`. Then run:

```sh
python3 tools/fir_capture.py --plot
```

The board sends one UDP packet (port 5005) for each sample. The script saves `data/fpga_output.csv`, compares every
value with the Python reference, computes MSE and SNR against the clean ECG, saves `fig/fpga_capture.png` and
`data/fpga_metrics.json`, and prints `CAPTURE_PASS` when all 1024 samples arrived and match.
`python3 tools/fir_capture.py --selftest` checks the script itself without a board.

## 6. Report

```sh
cd Project-Report
latexmk -pdf -interaction=nonstopmode -halt-on-error access.tex
```

For BasicTeX, install the extra packages once: `tlmgr --usermode install spotcolor courier algorithms helvetic`.

## Design summary

| Item | Value |
|---|---|
| Filter | Low-pass FIR, Hamming window, 63 taps (order 62), cutoff 20 Hz, Fs = 360 Hz, delay 31 samples |
| Data format | Input and output signed 16-bit, coefficients signed 16-bit Q15, 40-bit accumulator |
| Architecture | Direct form, one multiplier reused over 63 clocks, three-stage pipeline, 66 clocks per sample |
| Rounding | One arithmetic right shift by 15 of the full sum, then saturation to 16 bits |
| Clock | 100 MHz |

## Note on verification

Passing the RTL simulation was not enough on this project. The first board build differed from the reference because
the synthesis tool merged the multiplier and the accumulator into one DSP block and changed how the accumulator is
cleared. The simulation of the RTL did not show it. It was found by capturing the output of the board and located with
a simulation of the synthesized netlist. The fix is in `rtl/fir_mac.v` and the details are in the report.
