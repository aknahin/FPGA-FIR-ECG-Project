#!/bin/bash
# Mac side: load the FIR design bitstream into the Nexys 3 over JTAG through the VM (volatile, not flash).
#   fpga/program.sh [artifacts/fir/top.bit]
# Prints PROGRAM_OK only if iMPACT reports "Programmed successfully".
set -e
cd "$(dirname "$0")/.."
BIT="${1:-artifacts/fir/top.bit}"
SSH="ssh -i $HOME/.ssh/utm_fpga_ecdsa -o IdentitiesOnly=yes -o BatchMode=yes -o LogLevel=ERROR aknahin@192.168.64.2"
SCP="scp -O -q -i $HOME/.ssh/utm_fpga_ecdsa -o IdentitiesOnly=yes -o LogLevel=ERROR"
mkdir -p logs
$SSH 'mkdir -p ~/fpga-program'
$SCP "$BIT" aknahin@192.168.64.2:fpga-program/top.bit
$SSH 'cat > ~/fpga-program/program.cmd <<CMD
setMode -bs
setCable -port auto
identify
assignFile -p 1 -file top.bit
program -p 1
quit
CMD'
$SSH 'bash -c "set --; source /opt/Xilinx/14.6/ISE_DS/settings64.sh >/dev/null; cd ~/fpga-program; impact -batch program.cmd"' 2>&1 | tee logs/program.log | tail -8
if grep -q "Programmed successfully" logs/program.log; then echo PROGRAM_OK; else echo PROGRAM_FAILED; exit 1; fi
