#!/usr/bin/env bash
# 1-CU / 10-DU topology bring-up.
#
# Separate from start_setup.sh, which is still written for the old 3-CU/6-DU/6-UE
# layout and therefore reports a misleading "6/6 UEs" on a 10-UE stack. Nothing in
# the original tree is touched: this script drives the *_1cu7du compose files.
set -u
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJ="$(basename "$BASE_DIR")"          # compose project = directory name
CUS=(srscu0)
DUS=(srsdu0 srsdu1 srsdu2 srsdu3 srsdu4 srsdu5 srsdu6)
UES=(srsue0 srsue1 srsue2 srsue3 srsue4 srsue5 srsue6)
log(){ echo -e "\e[32m[$(date +%H:%M:%S)]\e[0m $*"; }
err(){ echo -e "\e[31m[$(date +%H:%M:%S)]\e[0m $*"; }

if [[ "${1:-}" == "--clean" ]]; then
  log "Tearing down every container (both topologies)"
  docker rm -f $(docker ps -aq) >/dev/null 2>&1
  sleep 3
fi

log "Step 1/4: networks"
for n in oran-intel telemetry-net core-net; do
  docker network inspect "$n" >/dev/null 2>&1 || docker network create "$n" >/dev/null 2>&1
done

log "Step 2/6: Prometheus + cAdvisor"
if ! docker ps --format '{{.Names}}' | grep -q '^cadvisor$'; then
  docker run -d --name cadvisor --network oran-intel -p 8080:8080 \
    -v /:/rootfs:ro -v /var/run:/var/run:rw -v /sys:/sys:ro -v /var/lib/docker/:/var/lib/docker:ro \
    gcr.io/cadvisor/cadvisor:latest >/dev/null || exit 1
fi
if ! docker ps --format '{{.Names}}' | grep -q '^prometheus$'; then
  docker run -d --name prometheus --network oran-intel -p 9090:9090 \
    -v "$BASE_DIR/setup/prometheus:/prometheus-data" \
    prom/prometheus:latest --config.file=/prometheus-data/prometheus.yml >/dev/null || exit 1
fi
sleep 5

log "Step 3/6: 5GC + the single CU"
docker compose -p "$PROJ" -f "$BASE_DIR/docker-compose-cu-1cu7du.yaml" up -d || exit 1
sleep 20

log "Step 4/6: 7 DUs (all F1 -> 175.53.1.11)"
docker compose -p "$PROJ" -f "$BASE_DIR/docker-compose-du-1cu7du.yaml" up -d || exit 1
sleep 25

log "Step 5/6: 7 UEs + telemetry"
docker compose -p "$PROJ" -f "$BASE_DIR/docker-compose-ue-1cu7du.yaml" up -d || exit 1
sleep 30

log "Step 6/6: injecting tc / pkill / stress-ng into all 8 stress targets"
TC=$(readlink -f "$(which tc)"); PK=$(readlink -f "$(which pkill)")
for c in "${CUS[@]}" "${DUS[@]}"; do
  for d in /usr/sbin/tc /usr/bin/tc /bin/tc; do docker cp "$TC" "$c:$d" >/dev/null 2>&1; done
  for d in /usr/bin/pkill /bin/pkill;             do docker cp "$PK" "$c:$d" >/dev/null 2>&1; done
  docker exec -u 0 "$c" chmod +x /usr/sbin/tc /usr/bin/tc /bin/tc /usr/bin/pkill /bin/pkill >/dev/null 2>&1
  if ! docker exec "$c" which stress-ng >/dev/null 2>&1; then
    docker exec -u 0 "$c" mkdir -p /tmp/pkgs >/dev/null 2>&1
    docker cp "$BASE_DIR/experimental_phase0/offline_packages/." "$c:/tmp/pkgs/" >/dev/null 2>&1
    docker exec -u 0 "$c" dpkg -iR /tmp/pkgs/ >/dev/null 2>&1
    docker exec -u 0 "$c" rm -rf /tmp/pkgs >/dev/null 2>&1
  fi
done

echo; log "================= VERIFICATION ================="
fail=0
echo "  containers running : $(docker ps -q | wc -l)"

echo "  --- F1: all 7 DUs attached to srscu0 ---"
att=$(docker logs srscu0 2>&1 | grep -c "F1 Setup" )
for d in "${DUS[@]}"; do
  if docker logs "$d" 2>&1 | grep -q "F1-C: Connection to CU-CP.*completed"; then
    printf "    %-8s F1 OK\n" "$d"
  else printf "    %-8s \e[31mF1 NOT ESTABLISHED\e[0m\n" "$d"; fail=1; fi
done

echo "  --- UEs attached (tun_srsue up) ---"
n=0; for u in "${UES[@]}"; do
  docker exec "$u" ip -4 addr show tun_srsue >/dev/null 2>&1 && n=$((n+1)) || printf "    %-8s \e[31mno PDU session\e[0m\n" "$u"
done
echo "    $n/7 attached"; [ "$n" -eq 7 ] || fail=1

echo "  --- c-rnti (all must be 0x4601) ---"
r=$(for u in "${UES[@]}"; do docker logs "$u" 2>&1 | grep -o 'c-rnti=0x[0-9a-f]*' | tail -1; done | sort -u | tr '\n' ' ')
echo "    $r"; [ "$r" = "c-rnti=0x4601 " ] || { err "    RNTI not uniform"; fail=1; }

echo "  --- CU interfaces ---"
printf "    srscu0 eth0=%s eth2=%s\n" \
  "$(docker exec srscu0 ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | head -1)" \
  "$(docker exec srscu0 ip -4 -o addr show eth2 2>/dev/null | awk '{print $4}')"

echo "  --- tc / stress-ng in all 11 targets ---"
m=""; for c in "${CUS[@]}" "${DUS[@]}"; do
  docker exec "$c" tc -V >/dev/null 2>&1 || m="$m $c(tc)"
  docker exec "$c" which stress-ng >/dev/null 2>&1 || m="$m $c(sng)"
done
echo "    missing:${m:- none}"; [ -z "$m" ] || fail=1

echo
if [ "$fail" -eq 0 ]; then log "ALL CHECKS PASSED - stack ready"; else err "CHECKS FAILED - do not start collection"; fi
exit $fail
