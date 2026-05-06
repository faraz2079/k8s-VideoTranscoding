#!/bin/bash
set -u
RUN_DIR=${1:-$(ls -td ~/work/ffmpeg-stress-test/runs/run-* 2>/dev/null | head -1)}
[ -z "$RUN_DIR" ] || [ ! -d "$RUN_DIR" ] && { echo "Usage: $0 [run-folder]"; exit 1; }
CSV="$RUN_DIR/summary.csv"
[ ! -f "$CSV" ] && { echo "summary.csv not found"; exit 1; }
VM_RAM_MIB=$(free -m | awk '/^Mem:/ {print $2}')
VM_CPU=$(nproc)

awk -F, -v vmram="$VM_RAM_MIB" -v vmcpu="$VM_CPU" '
NR == 1 { next }
NR == 2 { base_node_mem = $4+0 }
{
  rows++
  node_cpu_sum += $3+0; node_mem_sum += $4+0
  wkr_cpu_sum  += $7+0; wkr_mem_sum  += $8+0
  if ($3+0 > node_cpu_peak) node_cpu_peak = $3+0
  if ($4+0 > node_mem_peak) node_mem_peak = $4+0
  if ($7+0 > wkr_cpu_peak)  wkr_cpu_peak  = $7+0
  if ($8+0 > wkr_mem_peak)  wkr_mem_peak  = $8+0
  last_elapsed = $2+0
  last_qlen    = $5+0
}
END {
  if (rows == 0) { print "No data."; exit }
  printf "\n========== RUN SUMMARY ==========\n"
  printf "Run:         %s\n", "'"$RUN_DIR"'"
  printf "Duration:    %ds (%.1f min)   Samples: %d\n", last_elapsed, last_elapsed/60, rows
  printf "VM:          %d MiB RAM, %d vCPU\n\n", vmram, vmcpu

  printf "NODE-LEVEL (whole VM)\n"
  printf "  Baseline RAM: %6d MiB (%.1f%%)\n", base_node_mem, base_node_mem*100/vmram
  printf "  Peak RAM:     %6d MiB (%.1f%%)\n", node_mem_peak, node_mem_peak*100/vmram
  printf "  Avg RAM:      %6d MiB (%.1f%%)\n", node_mem_sum/rows, (node_mem_sum/rows)*100/vmram
  printf "  Peak CPU:     %6d m (%.1f cores)\n", node_cpu_peak, node_cpu_peak/1000
  printf "  Avg CPU:      %6d m (%.1f cores)\n\n", node_cpu_sum/rows, (node_cpu_sum/rows)/1000

  printf "FFMPEG WORKERS (combined)\n"
  printf "  Peak CPU:     %6d m (%.1f cores out of %d)\n", wkr_cpu_peak, wkr_cpu_peak/1000, vmcpu
  printf "  Avg CPU:      %6d m\n", wkr_cpu_sum/rows
  printf "  Peak RAM:     %6d MiB\n", wkr_mem_peak
  printf "  Avg RAM:      %6d MiB\n\n", wkr_mem_sum/rows

  printf "FINAL QUEUE:   %d jobs remaining\n", last_qlen
  printf "==================================\n"
}
' "$CSV"
