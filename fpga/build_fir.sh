#!/bin/bash
# Mac side: copy the FIR design and its .mem files to the UTM VM, build with Xilinx ISE 14.6, fetch the bitstream.
#   fpga/build_fir.sh
# The .mem files go to build/data/ because XST resolves $readmemh paths ("data/ecg.mem") from its working directory.
set -e
cd "$(dirname "$0")/.."
SSH="ssh -i $HOME/.ssh/utm_fpga_ecdsa -o IdentitiesOnly=yes -o BatchMode=yes -o LogLevel=ERROR aknahin@192.168.64.2"
SCP="scp -O -q -i $HOME/.ssh/utm_fpga_ecdsa -o IdentitiesOnly=yes -o LogLevel=ERROR"
mkdir -p artifacts/fir logs
$SSH 'rm -rf ~/fir-build && mkdir -p ~/fir-build/rtl ~/fir-build/constraints ~/fir-build/build/data'
$SCP rtl/fir_mac.v rtl/sample_strobe.v rtl/ecg_rom.v rtl/eth_udp_tx.v rtl/fir_top.v aknahin@192.168.64.2:fir-build/rtl/
$SCP fpga/fir.ucf aknahin@192.168.64.2:fir-build/constraints/
$SCP data/coeff.mem data/ecg.mem data/expected.mem aknahin@192.168.64.2:fir-build/build/data/
$SSH 'cat > ~/fir-build/build.sh' <<'REMOTE'
set -e
set --                                     # settings64.sh reads the caller's arguments
source /opt/Xilinx/14.6/ISE_DS/settings64.sh >/dev/null
cd ~/fir-build/build
printf 'verilog work ../rtl/fir_mac.v\nverilog work ../rtl/sample_strobe.v\nverilog work ../rtl/ecg_rom.v\nverilog work ../rtl/eth_udp_tx.v\nverilog work ../rtl/fir_top.v\n' > top.prj
cat > top.xst <<'XST'
run
-ifn top.prj
-ifmt mixed
-ofn top.ngc
-ofmt NGC
-p xc6slx16-3-csg324
-top fir_top
-opt_mode Speed
-opt_level 1
XST
xst -ifn top.xst -ofn synthesis.log
ngdbuild -p xc6slx16-3-csg324 -uc ../constraints/fir.ucf top.ngc top.ngd
map -w -p xc6slx16-3-csg324 -o top_map.ncd top.ngd top.pcf
par -w top_map.ncd top.ncd top.pcf
trce -v 10 -o timing.twr top.ncd top.pcf
bitgen -w -g StartUpClk:JtagClk -g UnusedPin:Pullnone top.ncd top.bit top.pcf
REMOTE
$SSH 'bash ~/fir-build/build.sh' 2>&1 | tee logs/fir-build.log | tail -5
for f in top.bit timing.twr synthesis.log top.par top.mrp; do
  $SCP aknahin@192.168.64.2:fir-build/build/$f artifacts/fir/$f 2>/dev/null || true
done
[ -f artifacts/fir/top.bit ] && echo "BUILD_OK artifacts/fir/top.bit" || { echo BUILD_FAILED; exit 1; }
