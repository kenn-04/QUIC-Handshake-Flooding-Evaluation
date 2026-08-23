#!/usr/bin/env bash
set -euo pipefail

#############################
# CONFIG
#############################
CORE=0

ROUNDS=120
RUNS_PER_PPS=10
SLEEP_BETWEEN_RUNS=120

PPS_START=10
PPS_END=130
PPS_STEP=10

TIMEOUT_SEC=1
#SSLKEYLOGFILE_PATH="$HOME/sslkeys.log"
#SSLKEYLOGFILE="$SSLKEYLOGFILE_PATH" \
#SSLKEYLOGFILE="$SSLKEYLOGFILE_PATH" \

QUICHE_DIR="$HOME/quiche"
QUICHE_BIN="$QUICHE_DIR/bazel-bin/quiche/quic_client"

SERVER_IP="172.16.171.137"
SERVER_PORT="6121"
RESPONSE_SIZE="1024"
URL="https://${SERVER_IP}/${RESPONSE_SIZE}"

# Fixed client EC P-256 key material
#BORINGSSL_EC_PRIV_HEX_23_VALUE="519b423d715f8b5d549f28d1c9a9b6a8c7f2f1f3d7b6b6c94b8f3f61d7d6c2e1"
#BORINGSSL_EC_PUB_HEX_23_VALUE="045d98d16c04be8db8796e0be9bc8c8130a6b790c06d77c501399251576a45a0d9389b7f35167a7dccd75ec33d0b60ff0debb50fe47c60f57cbfc0b78c2946558e"
# Fixed client EC P-384 key material
BORINGSSL_EC_PRIV_HEX_24_VALUE="076c62dd1dab97341d0a57b1ba4c6c4029f3e30025ade977c7a01ab3d285712e980959147ad6a9215b13414f987a61dd"
BORINGSSL_EC_PUB_HEX_24_VALUE="04f665a814d08cc8657dbf41cfaa463ce44aa411175470c6e10fc7b64afd37ab06d14063a39c6d0569c4f893064187c18cf1c132920bb6e2434414cdaac11d6513de5127227e5904a96ec515723d7509d2fe1e13969dab7547ad309796060f9a95"

METRICS_DIR="$HOME/metrics_client"
LOG_DIR="$HOME/logs_client"
QUIET=1

NET_IFACE=""   # leave empty to auto-detect from SERVER_IP; or set manually like "ens33"

#############################
# CHECKS
#############################
mkdir -p "$METRICS_DIR" "$LOG_DIR"

command -v taskset >/dev/null 2>&1 || { echo "Missing taskset (util-linux)"; exit 1; }
command -v ip >/dev/null 2>&1 || { echo "Missing ip (iproute2)"; exit 1; }
command -v getconf >/dev/null 2>&1 || { echo "Missing getconf"; exit 1; }
command -v timeout >/dev/null 2>&1 || { echo "Missing timeout (coreutils)"; exit 1; }
[[ -x /usr/bin/time ]] || { echo "Missing /usr/bin/time"; exit 1; }
[[ -x "$QUICHE_BIN" ]] || { echo "Not executable: $QUICHE_BIN"; exit 1; }

#############################
# HELPERS
#############################
read_cpu0() {
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
  local d="$1"
  local w="$2"
  awk -v d="$d" -v w="$w" 'BEGIN{
    if (w>0) printf "%.2f", d/w;
    else printf "0.00"
  }'
}

calc_bits_rate() {
  local d="$1"
  local w="$2"
  awk -v d="$d" -v w="$w" 'BEGIN{
    if (w>0) printf "%.2f", (8*d)/w;
    else printf "0.00"
  }'
}

detect_iface() {
  ip route get "$SERVER_IP" 2>/dev/null | awk '{
    for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}
  }'
}

read_net_bytes() {
  local iface="$1"
  local rxp="/sys/class/net/${iface}/statistics/rx_bytes"
  local txp="/sys/class/net/${iface}/statistics/tx_bytes"
  if [[ -r "$rxp" && -r "$txp" ]]; then
    echo "$(<"$rxp") $(<"$txp")"
  else
    echo "0 0"
  fi
}

if [[ -z "${NET_IFACE}" ]]; then
  NET_IFACE="$(detect_iface)"
fi
[[ -n "${NET_IFACE}" ]] || { echo "Could not auto-detect NET_IFACE for SERVER_IP=${SERVER_IP}. Set NET_IFACE manually."; exit 1; }
[[ -d "/sys/class/net/${NET_IFACE}" ]] || { echo "NET_IFACE ${NET_IFACE} not found in /sys/class/net"; exit 1; }

echo "Using NET_IFACE=${NET_IFACE} for bandwidth measurement"

#############################
# ONE ROUND (EXACTLY 1s WINDOW)
#############################
#BORINGSSL_EC_PRIV_HEX_23="$BORINGSSL_EC_PRIV_HEX_23_VALUE" \
          #BORINGSSL_EC_PUB_HEX_23="$BORINGSSL_EC_PUB_HEX_23_VALUE" \
#BORINGSSL_EC_PRIV_HEX_23="$BORINGSSL_EC_PRIV_HEX_23_VALUE" \
          #BORINGSSL_EC_PUB_HEX_23="$BORINGSSL_EC_PUB_HEX_23_VALUE" \
          
          
run_one_round() {
  local pps="$1"
  local run_idx="$2"
  local round_idx="$3"
  local run_log="$4"

  local ts
  ts="$(date +"%Y-%m-%d %H:%M:%S")"

  # ---- exact 1-second window start ----
  local t0 i0
  read -r t0 i0 < <(read_cpu0)

  local rx0 tx0
  read -r rx0 tx0 < <(read_net_bytes "$NET_IFACE")

  local start_ns
  start_ns="$(date +%s%N)"

  cd "$QUICHE_DIR"

  local time_file
  time_file="$(mktemp)"

  local rc timed_out
  rc=0
  timed_out=0


  set +e
  if [[ "$QUIET" -eq 1 ]]; then
    /usr/bin/time -f "%U %S %M" -o "$time_file" \
      timeout --foreground -s TERM "${TIMEOUT_SEC}s" \
      taskset -c "$CORE" \
      env -u BORINGSSL_X25519_PRIV_HEX \
          -u BORINGSSL_X25519_PUB_HEX \
          -u BORINGSSL_X25519_PRIV_HEX_29 \
          -u BORINGSSL_X25519_PUB_HEX_29 \
          BORINGSSL_EC_PRIV_HEX_24="$BORINGSSL_EC_PRIV_HEX_24_VALUE" \
          BORINGSSL_EC_PUB_HEX_24="$BORINGSSL_EC_PUB_HEX_24_VALUE" \
      "$QUICHE_BIN" \
        --host="$SERVER_IP" \
        --port="$SERVER_PORT" \
        --num_requests="$pps" \
        "$URL" \
        --disable_certificate_verification \
      >>"$run_log" 2>&1
    rc=$?
  else
    /usr/bin/time -f "%U %S %M" -o "$time_file" \
      timeout --foreground -s TERM "${TIMEOUT_SEC}s" \
      taskset -c "$CORE" \
      env -u BORINGSSL_X25519_PRIV_HEX \
          -u BORINGSSL_X25519_PUB_HEX \
          -u BORINGSSL_X25519_PRIV_HEX_29 \
          -u BORINGSSL_X25519_PUB_HEX_29 \
          BORINGSSL_EC_PRIV_HEX_24="$BORINGSSL_EC_PRIV_HEX_24_VALUE" \
          BORINGSSL_EC_PUB_HEX_24="$BORINGSSL_EC_PUB_HEX_24_VALUE" \
      "$QUICHE_BIN" \
        --host="$SERVER_IP" \
        --port="$SERVER_PORT" \
        --num_requests="$pps" \
        "$URL" \
        --disable_certificate_verification
    rc=$?
  fi
  set -e

  # timeout returns 124 if process was still alive at TIMEOUT_SEC
  if (( rc == 124 )); then
    timed_out=1
  else
    timed_out=0
  fi

  # If client exited earlier than TIMEOUT_SEC, pad the remainder
  # so rx/tx and core CPU are still measured over an exact 1.00 s window.
  local end_ns elapsed_ns remain_ns remain_s
  end_ns="$(date +%s%N)"
  elapsed_ns=$((end_ns - start_ns))
  remain_ns=$(( TIMEOUT_SEC * 1000000000 - elapsed_ns ))

  if (( remain_ns > 0 )); then
    remain_s="$(awk -v ns="$remain_ns" 'BEGIN{printf "%.6f", ns/1000000000}')"
    sleep "$remain_s"
  fi

  local rx1 tx1
  read -r rx1 tx1 < <(read_net_bytes "$NET_IFACE")

  local t1 i1
  read -r t1 i1 < <(read_cpu0)
  # ---- exact 1-second window end ----

  local core0_busy
  core0_busy="$(core0_busy_pct_window "$t0" "$i0" "$t1" "$i1")"

  # Whole-process accounting from GNU time:
  # %U = user seconds, %S = sys seconds, %M = max RSS in KB
  local user sys maxrss_kb
  if [[ -s "$time_file" ]]; then
    read -r user sys maxrss_kb < "$time_file"
  else
    user="0.0000"
    sys="0.0000"
    maxrss_kb="0"
  fi
  rm -f "$time_file"

  local wall proc_cpu
  wall="$(awk -v w="$TIMEOUT_SEC" 'BEGIN{printf "%.2f", w}')"
  proc_cpu="$(awk -v u="$user" -v s="$sys" -v w="$TIMEOUT_SEC" 'BEGIN{
    cpu_s=u+s;
    if (w>0) printf "%.2f", 100*cpu_s/w;
    else printf "0.00"
  }')"

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
# ONE EXPERIMENT
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
