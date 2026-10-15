import subprocess
import time
import signal
import sys
import json
import os

# Global configuration
docker_ids = []
open5gs_id = "open5gs_5gc"
active_procs = []

# ================= HELPER FUNCTIONS =================

result = subprocess.run("pwd", capture_output=True, text=True)
pwd = result.stdout.strip()
print(f'Current working directory is {pwd}')

def get_docker_ids():
    """Finds all srsue container IDs."""
    try:
        cmd = "docker ps --filter 'name=srsue' --format '{{.ID}}'"
        result = subprocess.check_output(cmd, shell=True, text=True)
        return result.strip().split('\n') if result.strip() else []
    except:
        return []

def force_kill_all_iperf(clients_only=True):
    """Kill the iperf CLIENTS in both directions: the uplink ones inside every
    UE, and the downlink ones inside the core. Missing the core's half would
    leave the old downlink running alongside the new, doubling DL load."""
    for cid in get_docker_ids():
        subprocess.run(f"docker exec {cid} pkill -9 -f 'iperf -c'", shell=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(f"docker exec {open5gs_id} pkill -9 -f 'iperf -c'", shell=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if not clients_only:
        subprocess.run(f"docker exec {open5gs_id} pkill -9 -f 'iperf -s'", shell=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def ue_tun_ip(ue_id):
    """The UE's PDU-session address on tun_srsue, e.g. 10.45.1.2."""
    try:
        out = subprocess.check_output(
            f"docker exec {ue_id} ip -o -4 addr show tun_srsue",
            shell=True, text=True, stderr=subprocess.DEVNULL)
        return out.split()[3].split("/")[0]
    except Exception:
        return None


def start_iperf_server():
    """Start the UDP servers for BOTH directions.

    Uplink  : one server in the core, bound to 10.45.1.1, receives from every UE.
    Downlink: one server inside each UE, bound to that UE's own tun address, so
              the core can send to it. Without these the downlink clients have
              nothing to talk to and the CU->DU path stays empty.
    """
    print(f"Starting uplink iperf server on {open5gs_id}...")
    subprocess.run(f"docker exec -d {open5gs_id} iperf -s -u -B 10.45.1.1", shell=True)
    for cid in get_docker_ids():
        ip = ue_tun_ip(cid)
        if ip:
            subprocess.run(f"docker exec -d {cid} iperf -s -u -B {ip}", shell=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def start_uplink_iperf(ue_id, mbps_rate, duration=900):
    """UE -> core. Open-loop UDP at exactly -b, regardless of loss."""
    cmd = ["docker", "exec", ue_id, "iperf", "-c", "10.45.1.1", "-u",
           "-b", f"{mbps_rate}M", "-t", str(int(duration))]
    try:
        active_procs.append(subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
    except Exception as e:
        print(f"Error starting uplink iperf on {ue_id}: {e}")


def start_downlink_iperf(ue_ip, mbps_rate, duration=900):
    """core -> UE. Runs INSIDE the core container and targets the UE's tun
    address, so the bytes traverse core -> CU -> DU -> UE and finally load the
    CU's eth0 egress (the F1 downlink), which is otherwise idle at ~21 B/s."""
    cmd = ["docker", "exec", open5gs_id, "iperf", "-c", ue_ip, "-u",
           "-b", f"{mbps_rate}M", "-t", str(int(duration))]
    try:
        active_procs.append(subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
    except Exception as e:
        print(f"Error starting downlink iperf to {ue_ip}: {e}")


def cleanup_and_exit(signum=None, frame=None):
    print("\n[TrafficGen] Cleaning up and exiting...")
    force_kill_all_iperf()
    sys.exit(0)

signal.signal(signal.SIGINT, cleanup_and_exit)

# ================= MAIN LOGIC =================
#
# Slot-driven daemon. The scrapper owns the traffic rate: at the start of every
# experiment it writes traffic_slot.json with a new epoch and the rate for that
# experiment. This process holds that rate for the WHOLE experiment and changes
# it only when the epoch changes -- i.e. between experiments, never inside a
# collection window. That is what removes the mid-window traffic steps that
# contaminated the earlier collections.
#
# It also re-establishes the iperf server whenever it goes missing. The scrapper
# recreates open5gs_5gc (it lives in docker-compose-cu++.yaml) before every
# experiment, which kills the server; under TCP a missing server means every
# client fails to connect and no user traffic flows at all.

SLOT_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         "data_fs_plane", "traffic_slot.json")
POLL_SEC = 3            # watchdog / slot-file poll interval
CLIENT_DURATION = 1500  # covers a 900s traffic slot, or 300s warmup + 600s + 300s


def server_running():
    """True only if a UDP iperf server is listening.

    A leftover TCP-mode server (iperf -s, no -u) satisfies a plain 'iperf -s'
    check but silently accepts nothing from a UDP client, so no user traffic
    flows. If only a TCP server is present it is removed so a UDP one can take
    its place.
    """
    try:
        out = subprocess.check_output(f"docker exec {open5gs_id} ps -eo args",
                                      shell=True, text=True, stderr=subprocess.DEVNULL)
    except Exception:
        return False
    srv = [l for l in out.splitlines() if "iperf" in l and " -s" in l]
    udp = [l for l in srv if " -u" in l]
    tcp = [l for l in srv if " -u" not in l]
    if tcp and not udp:
        print("[TrafficGen] found a stale TCP-mode iperf server in the core -- removing it", flush=True)
        subprocess.run(f"docker exec {open5gs_id} pkill -9 -f 'iperf -s'",
                       shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(1)
        return False
    return bool(udp)


def ensure_server():
    """Start the iperf server if it is not there. Returns True if it had to start one."""
    if not server_running():
        print("[TrafficGen] iperf server missing in core -- (re)starting", flush=True)
        start_iperf_server()
        time.sleep(1)
        return True
    return False


def read_slot():
    try:
        with open(SLOT_FILE) as f:
            d = json.load(f)
        return d["epoch"], float(d["mbps_per_ue"]), d.get("label", "")
    except Exception:
        return None


def running_clients():
    out = {}
    for cid in get_docker_ids():
        r = subprocess.run(f"docker exec {cid} pgrep -f 'iperf -c'",
                           shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        out[cid] = (r.returncode == 0)
    return out


OVERLAP_SEC = 3   # new clients run alongside the old ones before the old are cut


def client_pids(cid):
    """PIDs of the iperf clients currently running inside one UE container."""
    try:
        out = subprocess.check_output(f"docker exec {cid} pgrep -f 'iperf -c'",
                                      shell=True, stderr=subprocess.DEVNULL, text=True)
        return [x for x in out.split() if x.isdigit()]
    except Exception:
        return []


def kill_pids(cid, pids):
    if pids:
        subprocess.run(f"docker exec {cid} kill -9 {' '.join(pids)}",
                       shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def arm_all(rate, ids=None):
    """Arm both directions. The slot's Mbps/UE is split 50/50 UL/DL so the TOTAL
    offered load per UE still matches every previous collection and the 25-slot
    traffic curve keeps its original meaning."""
    ids = ids if ids is not None else get_docker_ids()
    half = rate / 2.0
    for cid in ids:
        start_uplink_iperf(cid, half, duration=CLIENT_DURATION)
        ip = ue_tun_ip(cid)
        if ip:
            start_downlink_iperf(ip, half, duration=CLIENT_DURATION)
    return len(ids)


def core_client_pids():
    """PIDs of the downlink iperf clients running inside the core container."""
    try:
        out = subprocess.check_output(f"docker exec {open5gs_id} pgrep -f 'iperf -c'",
                                      shell=True, stderr=subprocess.DEVNULL, text=True)
        return [x for x in out.split() if x.isdigit()]
    except Exception:
        return []


def main():
    print("[TrafficGen] UDP BIDIRECTIONAL mode (50/50 UL/DL), slot-driven. Waiting for the scrapper to set a slot...", flush=True)
    ensure_server()
    cur_epoch = None
    cur_rate = None

    while True:
        slot = read_slot()

        if slot is None:
            ensure_server()          # keep the server warm, send nothing yet
            time.sleep(POLL_SEC)
            continue

        epoch, rate, label = slot

        if epoch != cur_epoch:
            ensure_server()
            ids = get_docker_ids()

            # GAP-FREE HANDOFF. Killing the old clients first and starting the new
            # ones afterwards leaves every UE at literally zero offered load for
            # the duration of the restart -- that is what produced the zero
            # net_tx rows in the previous training set, once per 15-minute slot
            # boundary. Instead: record the old PIDs, start the new rate
            # alongside them, let both run briefly, then cut only the old ones.
            # The cost is a few seconds of old+new combined throughput at each
            # boundary, which is far less damaging than a hole.
            old = {cid: client_pids(cid) for cid in ids} if cur_epoch is not None else {}
            old_dl = core_client_pids() if cur_epoch is not None else []

            print(f"[TrafficGen] slot {epoch} ({label}): {rate:.2f} Mbps/UE "
                  f"-- starting new clients alongside the old", flush=True)
            n = arm_all(rate, ids)

            if old:
                time.sleep(OVERLAP_SEC)
                cut = 0
                for cid in ids:
                    if old.get(cid):
                        kill_pids(cid, old[cid])
                        cut += len(old[cid])
                if old_dl:
                    kill_pids(open5gs_id, old_dl)
                    cut += len(old_dl)
                print(f"[TrafficGen]   overlap done; cut {cut} old client(s). "
                      f"{n} clients now at {rate:.2f} Mbps each ({rate * n:.2f} Mbps total)", flush=True)
            else:
                print(f"[TrafficGen]   {n} UEs x 2 directions at {rate/2:.2f} Mbps each way "
                      f"({rate * n:.2f} Mbps total)", flush=True)

            cur_epoch, cur_rate = epoch, rate
            time.sleep(POLL_SEC)
            continue

        # Same experiment: hold the rate. Heal only what died.
        if ensure_server():
            print("[TrafficGen]   server was replaced; re-arming clients at the SAME rate", flush=True)
            force_kill_all_iperf()
            arm_all(cur_rate)
        else:
            for cid, alive in running_clients().items():
                if not alive:
                    print(f"[TrafficGen]   UE {cid} client died -- restarting at {cur_rate:.2f} Mbps", flush=True)
                    start_uplink_iperf(cid, cur_rate / 2.0, duration=CLIENT_DURATION)
                    ip = ue_tun_ip(cid)
                    if ip:
                        start_downlink_iperf(ip, cur_rate / 2.0, duration=CLIENT_DURATION)

        time.sleep(POLL_SEC)


if __name__ == "__main__":
    while True:
        try:
            main()
        except KeyboardInterrupt:
            cleanup_and_exit()
        except Exception as e:
            print(f"[TrafficGen] error: {e}", flush=True)
            time.sleep(5)


