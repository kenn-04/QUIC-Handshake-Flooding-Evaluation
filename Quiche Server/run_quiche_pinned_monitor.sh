#!/usr/bin/env bash
set -euo pipefail

CORE=0
PORT=6121
INTERVAL=1

QUICHE_DIR="$HOME/quiche"
QUICHE_BIN="$QUICHE_DIR/bazel-bin/quiche/quic_server"
CERT_FILE="$QUICHE_DIR/cert.pem"
KEY_FILE="$QUICHE_DIR/key.pkcs8"

LOG_DIR="$HOME/logs"
METRICS_DIR="$HOME/metrics"
TS="$(date +"%Y%m%d_%H%M%S")"
LOG_FILE="${LOG_DIR}/quiche_server_${TS}.log"
OUT_CSV="${METRICS_DIR}/quiche_server_metrics_${TS}.csv"

HZ="$(getconf CLK_TCK)"

read_sys_cpu() {
  awk '
    $1=="cpu"{
      user=$2; nice=$3; sys=$4; idle=$5; iowait=$6; irq=$7; softirq=$8; steal=$9;
      total=user+nice+sys+idle+iowait+irq+softirq+steal;
      idle_total=idle+iowait;
      print total, idle_total;
      exit
    }' /proc/stat
}

read_proc_ticks() {
  awk '{print $14+$15}' "/proc/$1/stat"
}

read_mem_kb() {
  local pid="$1"
  local rss vms
  rss="$(awk '/^VmRSS:/ {print $2}' "/proc/$pid/status" 2>/dev/null || true)"
  vms="$(awk '/^VmSize:/ {print $2}' "/proc/$pid/status" 2>/dev/null || true)"
  [[ -n "${rss:-}" ]] || rss="0"
  [[ -n "${vms:-}" ]] || vms="0"
  echo "$rss $vms"
}

detect_iface() {
  ip route show default 2>/dev/null | awk '{print $5; exit}'
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

calc_rate() {
  local d="$1"
  local it="$2"
  awk -v d="$d" -v it="$it" 'BEGIN{
    if (it>0) printf "%.2f", d/it;
    else printf "0.00"
  }'
}

calc_bits_rate() {
  local d="$1"
  local it="$2"
  awk -v d="$d" -v it="$it" 'BEGIN{
    if (it>0) printf "%.2f", (8*d)/it;
    else printf "0.00"
  }'
}

mkdir -p "$LOG_DIR" "$METRICS_DIR"

command -v ip >/dev/null 2>&1 || { echo "Missing ip (iproute2)"; exit 1; }
[[ -x "$QUICHE_BIN" ]] || { echo "Not executable: $QUICHE_BIN"; exit 1; }
[[ -f "$CERT_FILE" ]] || { echo "Missing cert: $CERT_FILE"; exit 1; }
[[ -f "$KEY_FILE" ]] || { echo "Missing key: $KEY_FILE"; exit 1; }

NET_IFACE="$(detect_iface)"
[[ -n "${NET_IFACE:-}" ]] || { echo "Could not auto-detect NET_IFACE from default route. Set it manually."; exit 1; }
[[ -d "/sys/class/net/${NET_IFACE}" ]] || { echo "NET_IFACE ${NET_IFACE} not found in /sys/class/net"; exit 1; }

echo "Starting quiche server pinned to core ${CORE}:"
echo "  CMD: $QUICHE_BIN --port=${PORT} --certificate_file=${CERT_FILE} --key_file=${KEY_FILE} --generate_dynamic_responses=true"
echo "  LOG: ${LOG_FILE}"
echo "  CSV: ${OUT_CSV}"
echo "  NET_IFACE: ${NET_IFACE}"
echo

taskset -c "$CORE" \
  env -u BORINGSSL_X25519_PRIV_HEX \
      -u BORINGSSL_X25519_PUB_HEX \
      -u BORINGSSL_X25519_PRIV_HEX_29 \
      -u BORINGSSL_X25519_PUB_HEX_29 \
      -u BORINGSSL_EC_PRIV_HEX \
      -u BORINGSSL_EC_PUB_HEX \
      -u BORINGSSL_EC_PRIV_HEX_23 \
      -u BORINGSSL_EC_PUB_HEX_23 \
  bash -lc "cd \"$QUICHE_DIR\" && exec \"$QUICHE_BIN\" \
    --port=\"$PORT\" \
    --certificate_file=\"$CERT_FILE\" \
    --key_file=\"$KEY_FILE\" \
    --generate_dynamic_responses=true" \
  >"$LOG_FILE" 2>&1 &
SERVER_PID=$!

sleep 0.2
if ! kill -0 "$SERVER_PID" 2>/dev/null; then
  echo "Server failed to start. Check log: $LOG_FILE" >&2
  exit 1
fi

echo "Server PID: $SERVER_PID"
echo "Monitoring every ${INTERVAL}s... Ctrl+C stops monitoring (server keeps running)."
echo

trap "echo; echo 'Stopping monitor only. Server still running (PID=$SERVER_PID). To stop server: kill $SERVER_PID'; exit 0" INT TERM

echo "timestamp,epoch_s,pid,proc_cpu_pct,sys_cpu_pct,vmrss_kb,vmsize_kb,rx_bytes,tx_bytes,rx_Bps,tx_Bps,rx_bps,tx_bps" > "$OUT_CSV"

set -- $(read_sys_cpu); prev_total="$1"; prev_idle="$2"
prev_pticks="$(read_proc_ticks "$SERVER_PID")"

set -- $(read_net_bytes "$NET_IFACE"); prev_rx="$1"; prev_tx="$2"

while kill -0 "$SERVER_PID" 2>/dev/null; do
  sleep "$INTERVAL"

  now_ts="$(date +"%Y-%m-%d %H:%M:%S")"
  now_epoch="$(date +%s)"

  set -- $(read_sys_cpu); cur_total="$1"; cur_idle="$2"
  d_total=$((cur_total - prev_total))
  d_idle=$((cur_idle - prev_idle))

  sys_cpu_pct="0.00"
  if (( d_total > 0 )); then
    sys_cpu_pct=$(awk -v dt="$d_total" -v di="$d_idle" 'BEGIN{ printf "%.2f", 100*(1 - di/dt) }')
  fi
  prev_total="$cur_total"
  prev_idle="$cur_idle"

  cur_pticks="$(read_proc_ticks "$SERVER_PID")"
  d_pticks=$((cur_pticks - prev_pticks))
  prev_pticks="$cur_pticks"
  proc_cpu_pct=$(awk -v dpt="$d_pticks" -v hz="$HZ" -v it="$INTERVAL" 'BEGIN{ printf "%.2f", 100*(dpt/(hz*it)) }')

  set -- $(read_mem_kb "$SERVER_PID"); rss_kb="$1"; vms_kb="$2"

  set -- $(read_net_bytes "$NET_IFACE"); cur_rx="$1"; cur_tx="$2"
  rx_bytes=$((cur_rx - prev_rx)); (( rx_bytes < 0 )) && rx_bytes=0
  tx_bytes=$((cur_tx - prev_tx)); (( tx_bytes < 0 )) && tx_bytes=0
  prev_rx="$cur_rx"
  prev_tx="$cur_tx"

  rx_Bps="$(calc_rate "$rx_bytes" "$INTERVAL")"
  tx_Bps="$(calc_rate "$tx_bytes" "$INTERVAL")"
  rx_bps="$(calc_bits_rate "$rx_bytes" "$INTERVAL")"
  tx_bps="$(calc_bits_rate "$tx_bytes" "$INTERVAL")"

  echo "${now_ts},${now_epoch},${SERVER_PID},${proc_cpu_pct},${sys_cpu_pct},${rss_kb},${vms_kb},${rx_bytes},${tx_bytes},${rx_Bps},${tx_Bps},${rx_bps},${tx_bps}" >> "$OUT_CSV"
done

echo "Server process ended (PID $SERVER_PID). Monitoring stopped."
echo "CSV saved at: $OUT_CSV"
