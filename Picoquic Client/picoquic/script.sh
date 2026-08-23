#!/bin/bash

SERVER_IP="192.168.199.129"
SERVER_PORT="4443"
CLIENTS_PER_SECOND=100
DURATION=300         # time window
LOGFILE="results/cpu_100x300s.csv"

mkdir -p results
echo "timestamp,total_cpu_percent" > "$LOGFILE"

# CPU usage monitor
(
  start_time=$(date +%s)
  while true; do
    # one 1s sample of all picoquicdemo procs, sum their %CPU
    cpu_total=$(
      LC_ALL=C pidstat -C picoquicdemo -u -h -I 1 1 2>/dev/null \
      | awk '$NF=="picoquicdemo"{sum+=$7} END{if (sum=="") print 0; else print sum}'
    )

    timestamp=$(date +%s.%3N)
    echo "$timestamp,$cpu_total" >> "$LOGFILE"

    now=$(date +%s)
    elapsed=$((now - start_time))
    if [ "$elapsed" -ge "$DURATION" ]; then
      break
    fi
    # no extra sleep; pidstat already waited 1s
  done
) &


# launch clients every second
echo "Starting load test: $CLIENTS_PER_SECOND clients/second for $DURATION seconds..."
start_time=$(date +%s)

for ((sec=1; sec<=DURATION; sec++)); do
    echo "Second $sec: launching $CLIENTS_PER_SECOND clients..."
    for ((i=1; i<=CLIENTS_PER_SECOND; i++)); do
        ./picoquicdemo -n localhost "$SERVER_IP" "$SERVER_PORT" &
    done
    sleep 1
done

# Wait for all clients to finish
wait
kill $monitor_pid 2>/dev/null
echo "Test complete. CPU log saved to $LOGFILE"

