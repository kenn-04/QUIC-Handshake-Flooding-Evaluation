#!/usr/bin/env bash
set -euo pipefail

#############################
# CONFIG
#############################
CORE=0

ROUNDS=120
RUNS_PER_PPS=10
SLEEP_BETWEEN_RUNS=120

PPS_START=100
PPS_END=600
PPS_STEP=100

TIMEOUT_SEC=1   # measurement window per round (seconds)
PICO_BIN="/home/keni/picoquic/picoquicdemo"
DEST_IP="172.16.171.134"
DEST_PORT="4443"
FIXED_ARGS=(-Z 0 -n localhost)

# Optional raw socket env
ENV_PREFIX=()
#USE_RAW_SOCKET=1 RAW_SRC_IP=192.168.124.131

METRICS_DIR="$HOME/metrics_client"
LOG_DIR="$HOME/logs_client"
QUIET=1  # 1 => write picoquicdemo stdout/stderr to log file, 0 => print to terminal

# Network bandwidth measurement (per-round, based on interface counters)
NET_IFACE=""   # leave empty to auto-detect from DEST_IP; or set like "eth0"

#############################
# CHECKS
#############################
mkdir -p "$METRICS_DIR" "$LOG_DIR"
command -v python3 >/dev/null 2>&1 || { echo "Missing python3"; exit 1; }
command -v taskset >/dev/null 2>&1 || { echo "Missing taskset (util-linux)"; exit 1; }
command -v ip >/dev/null 2>&1 || { echo "Missing ip (iproute2)"; exit 1; }
command -v getconf >/dev/null 2>&1 || { echo "Missing getconf"; exit 1; }
[[ -x "$PICO_BIN" ]] || { echo "Not executable: $PICO_BIN"; exit 1; }

#############################
# HELPERS
#############################
read_cpu0() {
  # returns: "<total> <idle_total>" for cpu0 from /proc/stat
  awk '
    $1=="cpu0"{
      user=$2; nice=$3; sys=$4; idle=$5; iowait=$6; irq=$7; softirq=$8; steal=$9;
      total=user+nice+sys+idle+iowait+irq+softirq+steal;
      idle_total=idle+iowait;
      print total, idle_total;
      exit
    }' /proc/stat
}

core0_busy_pct_window() {
  local t0="$1" i0="$2" t1="$3" i1="$4"
  local dt=$((t1 - t0))
  local di=$((i1 - i0))
  if (( dt <= 0 )); then
    echo "0.00"
  else
    awk -v dt="$dt" -v di="$di" 'BEGIN{printf "%.2f", 100*(1 - di/dt)}'
  fi
}

calc_rate() {
  # args: <delta_bytes> <wall_seconds>
  local d="$1"
  local w="$2"
  awk -v d="$d" -v w="$w" 'BEGIN{
    if (w>0) printf "%.2f", d/w;
    else printf "0.00"
  }'
}

calc_bits_rate() {
  # args: <delta_bytes> <wall_seconds>
  local d="$1"
  local w="$2"
  awk -v d="$d" -v w="$w" 'BEGIN{
    if (w>0) printf "%.2f", (8*d)/w;
    else printf "0.00"
  }'
}

detect_iface() {
  ip route get "$DEST_IP" 2>/dev/null | awk '{
    for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}
  }'
}

read_net_bytes() {
  # args: <iface>
  # prints: "<rx_bytes> <tx_bytes>"
  local iface="$1"
  local rxp="/sys/class/net/${iface}/statistics/rx_bytes"
  local txp="/sys/class/net/${iface}/statistics/tx_bytes"
  if [[ -r "$rxp" && -r "$txp" ]]; then
    echo "$(<"$rxp") $(<"$txp")"
  else
    echo "0 0"
  fi
}

clk_tck() { getconf CLK_TCK; }

read_proc_ticks() {
  # args: <pid> -> "<utime_ticks> <stime_ticks>"
  awk '{print $14, $15}' "/proc/${1}/stat" 2>/dev/null || echo "0 0"
}

read_proc_rss_kb() {
  # args: <pid> -> VmRSS kB
  awk '/^VmRSS:/{print $2; exit}' "/proc/${1}/status" 2>/dev/null || echo "0"
}

kill_and_reap_bounded() {
  # args: <pid> <grace_sec_float> <kill_wait_sec_float>
  # - Sends TERM
  # - waits up to grace
  # - sends KILL if still alive
  # - waits up to kill_wait
  local pid="$1"
  local grace="$2"
  local kwait="$3"

  # TERM
  kill -TERM "$pid" 2>/dev/null || true

  # wait up to grace (poll)
  local elapsed=0
  local step="0.01"
  while kill -0 "$pid" 2>/dev/null; do
    awk -v e="$elapsed" -v g="$grace" 'BEGIN{exit !(e<g)}' || break
    sleep "$step"
    elapsed="$(awk -v e="$elapsed" -v s="$step" 'BEGIN{printf "%.2f", e+s}')"
  done

  # KILL if still alive
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
  fi

  # bounded wait to reap
  elapsed=0
  while true; do
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    awk -v e="$elapsed" -v g="$kwait" 'BEGIN{exit !(e<g)}' || break
    sleep "$step"
    elapsed="$(awk -v e="$elapsed" -v s="$step" 'BEGIN{printf "%.2f", e+s}')"
  done

  # reap (won't block if already dead)
  wait "$pid" 2>/dev/null || true
}

# Decide which interface to measure
if [[ -z "${NET_IFACE}" ]]; then
  NET_IFACE="$(detect_iface)"
fi
[[ -n "${NET_IFACE}" ]] || { echo "Could not auto-detect NET_IFACE for DEST_IP=${DEST_IP}. Set NET_IFACE manually."; exit 1; }
[[ -d "/sys/class/net/${NET_IFACE}" ]] || { echo "NET_IFACE ${NET_IFACE} not found in /sys/class/net"; exit 1; }
echo "Using NET_IFACE=${NET_IFACE} for bandwidth measurement"

#############################
# ONE ROUND (EXACTLY 1s WINDOW)
#############################
run_one_round() {
  local pps="$1"
  local run_idx="$2"
  local round_idx="$3"
  local run_log="$4"

  local ts
  ts="$(date +"%Y-%m-%d %H:%M:%S")"

  # CPU0 baseline
  local t0 i0
  read -r t0 i0 < <(read_cpu0)

  # Net baseline
  local rx0 tx0
  read -r rx0 tx0 < <(read_net_bytes "$NET_IFACE")

  # Ensure picoquicdemo can find its relative files
  cd /home/keni/picoquic

  # Launch process
  if [[ "$QUIET" -eq 1 ]]; then
    taskset -c "$CORE" env "${ENV_PREFIX[@]}" \
      "$PICO_BIN" -g "$pps" -Y "$pps" "${FIXED_ARGS[@]}" "$DEST_IP" "$DEST_PORT" \
      >>"$run_log" 2>&1 &
  else
    taskset -c "$CORE" env "${ENV_PREFIX[@]}" \
      "$PICO_BIN" -g "$pps" -Y "$pps" "${FIXED_ARGS[@]}" "$DEST_IP" "$DEST_PORT" &
  fi
  local pid=$!

  # Baseline proc ticks (if process died instantly, these will be 0)
  local u0 s0
  read -r u0 s0 < <(read_proc_ticks "$pid")

  # ---- EXACT measurement window ----
  sleep "$TIMEOUT_SEC"
  # ----------------------------------

  # Sample RSS near end of window (single sample; no extra sleep)
  local maxrss_kb
  if [[ -d "/proc/$pid" ]]; then
    maxrss_kb="$(read_proc_rss_kb "$pid")"
  else
    maxrss_kb="0"
  fi

  # End net counters immediately after window
  local rx1 tx1
  read -r rx1 tx1 < <(read_net_bytes "$NET_IFACE")

  # End proc ticks (if dead, will be 0 0)
  local u1 s1
  read -r u1 s1 < <(read_proc_ticks "$pid")

  # Kill/reap bounded (does not add a second of sleep; just tiny polling)
  local timed_out rc
  rc=0
  timed_out=0
  if kill -0 "$pid" 2>/dev/null; then
    timed_out=1
    # Keep these small to avoid inflating runtime:
    #  - grace: allow quick TERM exit
    #  - kill_wait: bounded reap
    kill_and_reap_bounded "$pid" "0.02" "0.05"
    # We intentionally terminated it; record a conventional timeout-like code.
    rc=124
  else
    # It exited on its own before the window ended
    wait "$pid" 2>/dev/null || rc=$?
    timed_out=0
  fi

  # CPU0 after
  local t1 i1
  read -r t1 i1 < <(read_cpu0)
  local core0_busy
  core0_busy="$(core0_busy_pct_window "$t0" "$i0" "$t1" "$i1")"

  # Compute proc CPU over the window using ticks
  local du ds
  du=$((u1 - u0)); (( du < 0 )) && du=0
  ds=$((s1 - s0)); (( ds < 0 )) && ds=0

  local tck
  tck="$(clk_tck)"

  # wall is exactly TIMEOUT_SEC by design (store as float)
  local wall user sys proc_cpu
  wall="$(awk -v w="$TIMEOUT_SEC" 'BEGIN{printf "%.2f", w}')"
  user="$(awk -v du="$du" -v tck="$tck" 'BEGIN{printf "%.4f", du/tck}')"
  sys="$(awk -v ds="$ds" -v tck="$tck" 'BEGIN{printf "%.4f", ds/tck}')"
  proc_cpu="$(awk -v du="$du" -v ds="$ds" -v tck="$tck" -v w="$TIMEOUT_SEC" 'BEGIN{
    cpu_s=(du+ds)/tck;
    if (w>0) printf "%.2f", 100*cpu_s/w;
    else printf "0.00"
  }')"

  # Net deltas & rates over the window
  local rx_bytes tx_bytes rx_Bps tx_Bps rx_bps tx_bps
  rx_bytes=$((rx1 - rx0)); (( rx_bytes < 0 )) && rx_bytes=0
  tx_bytes=$((tx1 - tx0)); (( tx_bytes < 0 )) && tx_bytes=0

  rx_Bps="$(calc_rate "$rx_bytes" "$wall")"
  tx_Bps="$(calc_rate "$tx_bytes" "$wall")"
  rx_bps="$(calc_bits_rate "$rx_bytes" "$wall")"
  tx_bps="$(calc_bits_rate "$tx_bytes" "$wall")"

  echo "${ts},${pps},${run_idx},${round_idx},${wall},${user},${sys},${proc_cpu},${maxrss_kb},${core0_busy},${rc},${timed_out},${rx_bytes},${tx_bytes},${rx_Bps},${tx_Bps},${rx_bps},${tx_bps}"
}

#############################
# ONE EXPERIMENT (one PPS, one run => one CSV)
#############################
run_one_experiment() {
  local pps="$1"
  local run_idx="$2"
  local stamp
  stamp="$(date +"%Y%m%d_%H%M%S")"

  local out_csv="${METRICS_DIR}/client_pps${pps}_run${run_idx}_${stamp}.csv"
  local run_log="${LOG_DIR}/client_pps${pps}_run${run_idx}_${stamp}.log"

  echo ">>> PPS=${pps} | RUN ${run_idx}/${RUNS_PER_PPS}"
  echo "    CSV: ${out_csv}"
  echo "    LOG: ${run_log}"

  echo "timestamp,pps,run,round,wall_s,user_s,sys_s,proc_cpu_pct,maxrss_kb,core0_busy_pct,exit_code,timed_out,rx_bytes,tx_bytes,rx_Bps,tx_Bps,rx_bps,tx_bps" > "$out_csv"

  for ((round=1; round<=ROUNDS; round++)); do
    echo "  Round $round / $ROUNDS"
    run_one_round "$pps" "$run_idx" "$round" "$run_log" >> "$out_csv"
  done

  echo "<<< Done PPS=${pps} RUN=${run_idx}"
  echo
}

#############################
# MAIN SWEEP
#############################
for ((pps=PPS_START; pps<=PPS_END; pps+=PPS_STEP)); do
  for ((run=1; run<=RUNS_PER_PPS; run++)); do
    run_one_experiment "$pps" "$run"

    if ! ( ((pps==PPS_END)) && ((run==RUNS_PER_PPS)) ); then
      echo "Sleeping ${SLEEP_BETWEEN_RUNS}s..."
      sleep "$SLEEP_BETWEEN_RUNS"
    fi
  done
done

echo "All done."
echo "CSVs: ${METRICS_DIR}"
echo "Logs: ${LOG_DIR}"
