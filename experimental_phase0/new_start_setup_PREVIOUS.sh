#!/bin/bash
# =============================================================================
# O-RAN srsRAN FALCON Setup Launcher (SCALED FOR 10 UEs, 4 CUs, 10 DUs)
# Starts all containers, traffic generator, and automated data collection.
# Collects NORMAL data for N hours, then ANOMALY data with all faults x2.
# =============================================================================

set -e
# Script lives inside experimental_phase0/, so parent is the project root
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$BASE_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARNING:${NC} $1"; }
err()  { echo -e "${RED}[$(date '+%H:%M:%S')] ERROR:${NC} $1"; }
info() { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $1"; }

# ─── Parse Arguments ──────────────────────────────────────────────────
CLEAN=false
SETUP_ONLY=false
NORMAL_HOURS=5
FAULT_REPS=2

while [[ $# -gt 0 ]]; do
    case $1 in
        --clean)        CLEAN=true; shift ;;
        --setup-only)   SETUP_ONLY=true; shift ;;
        --normal-hours) NORMAL_HOURS="$2"; shift 2 ;;
        --fault-reps)   FAULT_REPS="$2"; shift 2 ;;
        *) err "Unknown argument: $1"; exit 1 ;;
    esac
done

# ─── InfluxDB Token ──────────────────────────────────────────────────
export INFLUXDB_TOKEN="605bc59413b7d5457d181ccf20f9fda15693f81b068d70396cc183081b264f3b"

# ─── Cleanup trap (Ctrl+C kills child processes) ─────────────────────
cleanup_on_exit() {
    echo ""
    warn "Caught interrupt — cleaning up background processes..."
    pkill -f "test_traffic.py" 2>/dev/null || true
    pkill -f "scrapper_prometheus_backup.py" 2>/dev/null || true
    for c in srsue0 srsue1 srsue2 srsue3 srsue4 srsue5 srsue6 srsue7 srsue8 srsue9 open5gs_5gc; do
        docker exec "$c" pkill -9 iperf 2>/dev/null || true
    done
    log "Background processes killed. Containers still running."
    log "To tear down containers too: ./start_setup.sh --clean"
    exit 0
}
trap cleanup_on_exit SIGINT SIGTERM

wait_for_container() {
    local name=$1
    local timeout=${2:-30}
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        if docker ps --format '{{.Names}}' | grep -q "^${name}$"; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    err "$name did not start within ${timeout}s"
    return 1
}

wait_for_healthy() {
    local name=$1
    local timeout=${2:-120}
    local elapsed=0
    log "Waiting for $name to become healthy..."
    while [ $elapsed -lt $timeout ]; do
        local status
        status=$(docker inspect --format '{{.State.Health.Status}}' "$name" 2>/dev/null)
        if [ "$status" = "healthy" ]; then
            log "$name is healthy"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    err "$name did not become healthy within ${timeout}s"
    return 1
}

check_rrc_release() {
    local ue=$1
    docker logs --tail 100 "$ue" 2>/dev/null | grep -q "Received RRC Release"
    return $?
}

handle_rrc_release() {
    local ue=$1
    warn "$ue received RRC Release — restarting..."
    docker restart "$ue"
    sleep 15
    if docker ps --format '{{.Names}}' | grep -q "^${ue}$"; then
        log "$ue restarted successfully"
    else
        err "$ue failed to restart!"
        return 1
    fi
}

# ─── Optional clean start ────────────────────────────────────────────
if [ "$CLEAN" = true ]; then
    log "Tearing down all containers..."
    docker compose -f "${BASE_DIR}/docker-compose-ue++.yaml" down 2>/dev/null || true
    docker compose -f "${BASE_DIR}/docker-compose-du.yaml"   down 2>/dev/null || true
    docker compose -f "${BASE_DIR}/docker-compose-cu++.yaml" down 2>/dev/null || true
    docker compose -f "${BASE_DIR}/docker-compose.yaml" down 2>/dev/null || true
    docker stop prometheus cadvisor 2>/dev/null || true
    docker rm   prometheus cadvisor 2>/dev/null || true
    pkill -f "scrapper_prometheus_backup.py" 2>/dev/null || true
    pkill -f "test_traffic.py" 2>/dev/null || true
    for c in srsue0 srsue1 srsue2 srsue3 srsue4 srsue5 srsue6 srsue7 srsue8 srsue9 open5gs_5gc; do
        docker exec "$c" pkill -9 iperf 2>/dev/null || true
    done
    log "Cleanup done"
    sleep 2
fi

# ─── Step 0: Ensure Docker networks exist ────────────────────────────
log "=== Step 0: Docker Networks ==="
docker network create oran-intel --subnet=175.53.0.0/16 2>/dev/null \
    && log "Created oran-intel" || log "oran-intel already exists"
docker network create telemetry-net --subnet=171.53.0.0/16 2>/dev/null \
    && log "Created telemetry-net" || log "telemetry-net already exists"

# ─── Step 2: Prometheus + cAdvisor ───────────────────────────────────
log "=== Step 2: Starting Prometheus + cAdvisor ==="
if ! docker ps --format '{{.Names}}' | grep -q '^cadvisor$'; then
    docker run -d \
        --name cadvisor \
        --network oran-intel \
        -p 8080:8080 \
        -v /:/rootfs:ro \
        -v /var/run:/var/run:rw \
        -v /sys:/sys:ro \
        -v /var/lib/docker/:/var/lib/docker:ro \
        gcr.io/cadvisor/cadvisor:latest
    log "cAdvisor started"
else
    log "cAdvisor already running"
fi

if ! docker ps --format '{{.Names}}' | grep -q '^prometheus$'; then
    docker run -d \
        --name prometheus \
        --network oran-intel \
        -p 9090:9090 \
        -v "${BASE_DIR}/setup/prometheus:/prometheus-data" \
        prom/prometheus:latest \
        --config.file=/prometheus-data/prometheus.yml
    log "Prometheus started"
else
    log "Prometheus already running"
fi
sleep 3

# ─── Step 3: Core Network (5GC) + CUs ────────────────────────────────
log "=== Step 3: Starting 5GC + CUs (docker-compose-cu++.yaml) ==="
docker compose -f "${BASE_DIR}/docker-compose-cu++.yaml" up -d

wait_for_healthy open5gs_5gc 120

# Scaled to manage all 4 CUs
for cu in srscu0 srscu1 srscu2 srscu3; do
    wait_for_container "$cu" 30
done
log "All CUs started"
sleep 5

# ─── Step 4: DUs ─────────────────────────────────────────────────────
log "=== Step 4: Starting DUs (docker-compose-du.yaml) ==="
docker compose -f "${BASE_DIR}/docker-compose-du.yaml" up -d

# Scaled to manage all 10 DUs
for du in srsdu0 srsdu1 srsdu2 srsdu3 srsdu4 srsdu5 srsdu6 srsdu7 srsdu8 srsdu9; do
    wait_for_container "$du" 30
done
log "All DUs started"

log "Waiting 15s for F1 connections to establish..."
sleep 15

# ─── Step 5: UEs ─────────────────────────────────────────────────────
log "=== Step 5: Starting UEs (docker-compose-ue++.yaml) ==="
docker compose -f "${BASE_DIR}/docker-compose-ue++.yaml" up -d

# Scaled to manage all 10 UEs
for ue in srsue0 srsue1 srsue2 srsue3 srsue4 srsue5 srsue6 srsue7 srsue8 srsue9; do
    wait_for_container "$ue" 30
done
log "All UEs started"

log "Waiting 30s for UE attachment and PDU sessions..."
sleep 30

# ─── Step 6: RRC Release Check & Verification ────────────────────────
log "=== Step 6: Verification + RRC Release Check ==="
echo ""
log "Container Status:"
docker ps --format 'table {{.Names}}\t{{.Status}}' \
    | grep -E 'srs|open5gs|cadvisor|prometheus|influxdb|grafana|metrics|redis' \
    | sort

echo ""
log "Checking UE PDU sessions (tun_srsue interfaces)..."
ATTACHED=0
# Scaled loop verification for all 10 UEs
for ue in srsue0 srsue1 srsue2 srsue3 srsue4 srsue5 srsue6 srsue7 srsue8 srsue9; do
    ip=$(docker exec "$ue" ip -o addr show tun_srsue 2>/dev/null | awk '{print $4}' || true)
    if [ -n "$ip" ]; then
        log "  $ue: $ip"
        ATTACHED=$((ATTACHED + 1))
    else
        warn "  $ue: NO PDU session"
    fi
done

echo ""
log "Checking for RRC Release in UE logs..."
RRC_OK=true
# Scaled safety loop tracking for all 10 UEs
for ue in srsue0 srsue1 srsue2 srsue3 srsue4 srsue5 srsue6 srsue7 srsue8 srsue9; do
    if check_rrc_release "$ue"; then
        warn "  $ue: RRC Release DETECTED — restarting..."
        handle_rrc_release "$ue"
        RRC_OK=false
    else
        log "  $ue: No RRC Release [OK]"
    fi
done

if [ "$RRC_OK" = false ]; then
    warn "Some UEs were restarted. Waiting 45s for re-attachment..."
    sleep 45
    ATTACHED=0
    for ue in srsue0 srsue1 srsue2 srsue3 srsue4 srsue5 srsue6 srsue7 srsue8 srsue9; do
        ip=$(docker exec "$ue" ip -o addr show tun_srsue 2>/dev/null | awk '{print $4}' || true)
        [ -n "$ip" ] && ATTACHED=$((ATTACHED + 1))
    done
    log "After RRC recovery: $ATTACHED/10 UEs attached"
fi

echo ""
log "Checking interface assignments (eth0 should be 175.x)..."
IFACE_OK=true
# Scaled interface validator to cover newly expanded infrastructure nodes
for c in srscu0 srscu1 srscu2 srscu3 srsdu0 srsdu1 srsdu2 srsdu3 srsdu4 srsdu5 srsdu6 srsdu7 srsdu8 srsdu9; do
    eth0_ip=$(docker exec "$c" ip -o addr show eth0 2>/dev/null \
        | grep -oP '175\.\d+\.\d+\.\d+' | head -1 || true)
    if [ -n "$eth0_ip" ]; then
        log "  $c eth0 = $eth0_ip [OK]"
    else
        warn "  $c eth0 does NOT have 175.x — entrypoint swap may have failed"
        IFACE_OK=false
    fi
done

# ─── Step 6.5: Dynamic Runtime Binary Injection & Stress Dependencies ──
log "=== Step 6.5: Injecting Flattened Standalone tc, pkill, and stress-ng ==="
HOST_TC=$(which tc || echo "/usr/sbin/tc")
HOST_PKILL=$(which pkill || echo "/usr/bin/pkill")
REAL_TC=$(readlink -f "$HOST_TC")
REAL_PKILL=$(readlink -f "$HOST_PKILL")
PKG_DIR="${BASE_DIR}/experimental_phase0/offline_packages"

# Scaled injection targets to accurately encompass all 4 CUs and 10 DUs
for container in srscu0 srscu1 srscu2 srscu3 srsdu0 srsdu1 srsdu2 srsdu3 srsdu4 srsdu5 srsdu6 srsdu7 srsdu8 srsdu9; do
    if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        info "Processing runtime components for $container..."
        docker exec -u 0 "$container" rm -f /usr/sbin/tc /usr/bin/tc /bin/tc /usr/bin/pkill /bin/pkill 2>/dev/null || true

        docker cp "$REAL_TC" "${container}:/usr/sbin/tc"
        docker cp "$REAL_TC" "${container}:/usr/bin/tc"
        docker cp "$REAL_TC" "${container}:/bin/tc"
        docker cp "$REAL_PKILL" "${container}:/usr/bin/pkill"
        docker cp "$REAL_PKILL" "${container}:/bin/pkill"
        docker exec -u 0 "$container" chmod +x /usr/sbin/tc /usr/bin/tc /bin/tc /usr/bin/pkill /bin/pkill

        if ! docker exec "$container" which stress-ng >/dev/null 2>&1; then
            if [ -d "$PKG_DIR" ]; then
                info "  -> stress-ng missing. Unpacking offline assets into $container..."
                docker exec -u 0 "$container" mkdir -p /tmp/pkgs
                docker cp "${PKG_DIR}/." "${container}:/tmp/pkgs/"
                docker exec -u 0 "$container" dpkg -iR /tmp/pkgs/ >/dev/null 2>&1
                docker exec -u 0 "$container" rm -rf /tmp/pkgs

                if docker exec "$container" which stress-ng >/dev/null 2>&1; then
                    log "  -> stress-ng successfully provisioned inside $container!"
                else
                    err "  -> stress-ng provisioning failed for $container."
                fi
            else
                warn "  -> Cannot find local repository directory at $PKG_DIR. Skipping package extraction."
            fi
        else
            log "  -> stress-ng is already verified active inside $container [OK]"
        fi
    fi
done
log "All runtime binaries and core dependencies successfully mapped across cellular containers!"

echo ""
echo "=============================================="
log "Setup complete!"
log "  Containers: $(docker ps --format '{{.Names}}' | wc -l) running"
log "  UEs attached: $ATTACHED/10"
if [ "$IFACE_OK" = true ]; then
    log "  Interfaces: All correct"
else
    warn "  Interfaces: Some containers have swapped eth0/eth1"
fi

if [ "$SETUP_ONLY" = true ]; then
    echo ""
    log "Setup-only mode. Exiting without starting data collection."
    echo "=============================================="
    exit 0
fi

# ─── Step 7: Ensure output directory is writable ─────────────────────
DATA_DIR="${BASE_DIR}/experimental_phase0/data_fs_plane"
mkdir -p "$DATA_DIR"
chmod -R 755 "$DATA_DIR" 2>/dev/null || true

# ─── Step 8: Start Traffic Generator ─────────────────────────────────
log "=== Step 8: Starting Traffic Generator ==="
TRAFFIC_LOG="${DATA_DIR}/traffic_gen.log"

pkill -f "test_traffic.py" 2>/dev/null || true
log "Killing leftover iperf sessions inside containers..."
# Scaled iperf background listener purger across all 10 UEs
for c in srsue0 srsue1 srsue2 srsue3 srsue4 srsue5 srsue6 srsue7 srsue8 srsue9 open5gs_5gc; do
    docker exec "$c" pkill -9 iperf 2>/dev/null || true
done
sleep 1

nohup python3 "${BASE_DIR}/experimental_phase0/test_traffic.py" > "$TRAFFIC_LOG" 2>&1 &
TRAFFIC_PID=$!
log "Traffic generator started (PID: $TRAFFIC_PID)"

# ─── Step 9: Wait for Metrics to Stabilize ───────────────────────────
log "=== Step 9: Waiting 2 minutes for metrics to stabilize ==="
sleep 120

# ─── Step 10: Start Automated Data Collection ─────────────────────────
log "=== Step 10: Starting Automated Data Collection Pipeline ==="
SCRAPPER_LOG="${DATA_DIR}/scrapper_pipeline.log"

pkill -f "scrapper_prometheus_backup.py" 2>/dev/null || true
sleep 1

nohup python3 "${BASE_DIR}/experimental_phase0/scrapper_prometheus_backup.py" \
    --normal-hours "$NORMAL_HOURS" \
    --fault-reps   "$FAULT_REPS" \
    > "$SCRAPPER_LOG" 2>&1 &
SCRAPPER_PID=$!

sleep 5
if ! kill -0 "$SCRAPPER_PID" 2>/dev/null; then
    err "Scrapper died immediately. Check log:"
    tail -20 "$SCRAPPER_LOG"
    kill "$TRAFFIC_PID" 2>/dev/null || true
    exit 1
fi

echo ""
echo "=============================================="
info "AUTOMATED PIPELINE RUNNING"
echo "=============================================="
log "  Traffic Generator PID : $TRAFFIC_PID"
log "  Scrapper Pipeline PID : $SCRAPPER_PID"
log "  UEs Attached Target   : $ATTACHED/10"
echo "=============================================="
