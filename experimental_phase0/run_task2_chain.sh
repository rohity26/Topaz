#!/bin/bash
# Waits for Task 1 (TCP) to finish, then sets up and runs Task 2 (UDP + downlink).
# Fully unattended: nohup'd, no controlling terminal, survives SSH disconnect.
BASE="/home/oran4/topaz/topaz-latest"
EXP="$BASE/experimental_phase0"
DATA="$EXP/data_fs_plane"
LOG="$DATA/task2_chain.log"
say(){ echo "[$(date '+%F %T')] $*" >> "$LOG"; }

say "chain started; waiting for Task 1 (TCP) to complete"

# ---- 1. wait for Task 1: 4 CSVs AND the completion banner ----
for i in $(seq 1 480); do          # up to 4 h
  n=$(ls "$DATA/test_csv_tcp_2iface"/*.csv 2>/dev/null | wc -l)
  if [ "$n" -ge 4 ] && grep -q "ALL ISOLATED EXPERIMENTS COMPLETED" "$DATA/scrapper_pipeline.log" 2>/dev/null \
     && grep -q "test_csv_tcp_2iface" "$DATA/scrapper_pipeline.log" 2>/dev/null; then
    say "Task 1 complete: $n files"; break
  fi
  sleep 30
done
n=$(ls "$DATA/test_csv_tcp_2iface"/*.csv 2>/dev/null | wc -l)
if [ "$n" -lt 4 ]; then say "ABORT: Task 1 only produced $n/4 files"; exit 1; fi
cp "$DATA/scrapper_pipeline.log" "$DATA/scrapper_pipeline_task1_tcp.log" 2>/dev/null
say "archived Task 1 log"

# ---- 2. stop Task 1 processes cleanly ----
for pat in scrapper_prometheus_backup test_traffic; do
  P=$(ps -eo pid,args | grep "$pat" | grep -v grep | grep python | awk '{print $1}')
  [ -n "$P" ] && { kill -9 $P 2>/dev/null; say "stopped $pat ($P)"; }
done
docker exec open5gs_5gc pkill -9 -f iperf 2>/dev/null
sleep 5

# ---- 3. swap in the bidirectional UDP traffic generator ----
cp "$EXP/test_traffic_udp_dl.py" "$EXP/test_traffic.py" || { say "ABORT: cannot install DL traffic gen"; exit 1; }
say "installed bidirectional UDP traffic generator (50/50 UL/DL)"

# ---- 4. launch Task 2: UDP, downlink loaded, stress on eth0 (midhaul DL) ----
export TARGET_ENTITIES="srscu0,srscu1,srscu2,srscu3"
export STRESS_TYPES="3"
export WARMUP_SEC=120 NORMAL_SEC=600 STRESS_SEC=300
export TRAFFIC_FIXED_GB=11.0
export TEST_OUT_DIR=test_csv_udp_dl_2iface
export IPERF_MODE=udp
export CU_STRESS_IFACE=eth0
export SCRAPPER_EXTRA_ARGS="--mode isolated --fault-reps 1"
say "launching Task 2: IPERF_MODE=udp CU_STRESS_IFACE=eth0 OUT=$TEST_OUT_DIR"
nohup bash "$EXP/new_start_setup_1.sh" > "$DATA/launcher_udp_dl_2iface.log" 2>&1 &
say "launcher started (pid $!)"

# ---- 5. wait for Task 2 and report ----
for i in $(seq 1 480); do
  n=$(ls "$DATA/test_csv_udp_dl_2iface"/*.csv 2>/dev/null | wc -l)
  if [ "$n" -ge 4 ] && grep -q "test_csv_udp_dl_2iface" "$DATA/scrapper_pipeline.log" 2>/dev/null \
     && grep -q "ALL ISOLATED EXPERIMENTS COMPLETED" "$DATA/scrapper_pipeline.log" 2>/dev/null; then
    say "Task 2 complete: $n files"; break
  fi
  sleep 30
done
say "chain finished. Task1=$(ls $DATA/test_csv_tcp_2iface/*.csv 2>/dev/null|wc -l)/4  Task2=$(ls $DATA/test_csv_udp_dl_2iface/*.csv 2>/dev/null|wc -l)/4"
