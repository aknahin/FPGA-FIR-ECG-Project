# FPGA FIR ECG Project

FPGA-based FIR filtering for ECG signals.

Author: AK Nahin <aknahin.engg@gmail.com>

## Project report

The LaTeX report and its assets are in `Project-Report/`.

Build the report with:

```sh
cd Project-Report
latexmk -pdf -interaction=nonstopmode -halt-on-error access.tex
```

For BasicTeX, install the additional packages used by the report:

```sh
tlmgr --usermode install spotcolor courier algorithms helvetic
```
