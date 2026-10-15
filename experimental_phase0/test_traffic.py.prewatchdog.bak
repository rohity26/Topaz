"""Downlink-only UDP traffic with a bounded, staggered rate change.

Direction
---------
core -> UE only. iperf servers run inside each UE (bound to its tun_srsue
address); the clients all run inside the core container. This loads the CU's
eth0 egress -- the F1 downlink toward the DU -- which is where NET stress is
injected. A tiny uplink ping keeps the RRC connection alive without putting
meaningful traffic on the uplink counters.

Why the rate change is staggered
--------------------------------
Switching every flow at once means old and new run together for the overlap,
so the offered load briefly becomes A + B: going 11 -> 3 Gb/window it spikes to
14, i.e. ABOVE the higher of the two rates. Killing first instead leaves a hole
at zero, i.e. BELOW the lower rate. Both were observed in earlier collections.

Instead each UE is split into SUBFLOWS smaller flows and they are switched one
at a time. With k of N flows moved, the offered load is

    total(k) = (N-k)*A/SUBFLOWS + k*B/SUBFLOWS

a weighted average of A and B, which always lies between them. The only
excursion left is the brief per-flow overlap, one flow out of N.

Old and new flows use ALTERNATING port sets (even/odd epoch) so that a flow can
be killed by its port without ambiguity -- two iperf clients to the same UE
would otherwise have identical command lines.
"""

import json
import os
import signal
import subprocess
import sys
import time

open5gs_id = "open5gs_5gc"

SUBFLOWS          = 4       # flows per UE -> 10 UEs x 4 = 40 total
TRANSITION_WINDOW = 60.0    # seconds to walk from the old rate to the new one
# no overlap: the old stream is killed before its replacement starts
CLIENT_DURATION   = 1500    # outlives a 900 s slot; cut at the boundary anyway
POLL_SEC          = 3

PORTS_EVEN = [5001, 5002, 5003, 5004]
PORTS_ODD  = [5101, 5102, 5103, 5104]

SLOT_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         "data_fs_plane", "traffic_slot.json")


def sh(cmd, check=False):
    return subprocess.run(cmd, shell=True, check=check,
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def ue_ids():
    try:
        out = subprocess.check_output(
            "docker ps --filter 'name=srsue' --format '{{.Names}}'",
            shell=True, text=True)
        return sorted(x for x in out.split() if x)
    except Exception:
        return []


def ue_ip(ue):
    try:
        out = subprocess.check_output(
            f"docker exec {ue} ip -o -4 addr show tun_srsue",
            shell=True, text=True, stderr=subprocess.DEVNULL)
        return out.split()[3].split("/")[0]
    except Exception:
        return None


def ports_for(epoch):
    # With kill-then-start there is never an old and a new stream on the same
    # port at once, so one port set suffices.
    return PORTS_EVEN


def start_servers(ue_map):
    """One UDP server per UE per port, on BOTH port sets, so a switchover never
    has to wait for a server to come up."""
    for ue, ip in ue_map.items():
        for p in PORTS_EVEN:
            sh(f"docker exec -d {ue} iperf -s -u -B {ip} -p {p}")


def start_keepalive(ue_map):
    """~64 bytes every 2 s per UE. Enough to stop an RRC release on a link with
    no uplink user traffic; far too small to register on the uplink counters."""
    for ue in ue_map:
        sh(f"docker exec {ue} pkill -f 'ping -i 2' ")
        sh(f"docker exec -d {ue} ping -i 2 10.45.1.1")


def flow_running(ip, port):
    r = subprocess.run(
        f"docker exec {open5gs_id} pgrep -f 'iperf -c {ip} .*-p {port}'",
        shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return r.returncode == 0


def start_flow(ip, port, mbps):
    sh(f"docker exec -d {open5gs_id} iperf -c {ip} -u -b {mbps:.4f}M "
       f"-p {port} -t {CLIENT_DURATION}")


def kill_flow(ip, port):
    sh(f"docker exec {open5gs_id} pkill -9 -f 'iperf -c {ip} .*-p {port}'")


def flow_order(ue_map, ports):
    """Round-robin: sub-flow index OUTER, UE inner.

    Switching UE-by-UE would move srscu1 (1 UE) through its whole transition in
    a few seconds while srscu3 (4 UEs) took four times as long -- the CUs would
    look completely different at the boundary. Taking one sub-flow from every UE
    per pass moves all four CUs in lockstep.
    """
    out = []
    for s in range(SUBFLOWS):
        for ue, ip in ue_map.items():
            out.append((ip, ports[s]))
    return out


def arm_all(ue_map, epoch, mbps_per_ue):
    """Cold start: bring every flow up at once (nothing to transition from)."""
    ports = ports_for(epoch)
    per = mbps_per_ue / SUBFLOWS
    for ip, port in flow_order(ue_map, ports):
        start_flow(ip, port, per)
    return len(ue_map) * SUBFLOWS


def transition(ue_map, old_epoch, new_epoch, new_mbps_per_ue):
    """Walk from the old rate to the new one, one stream at a time.

    Order per stream is KILL THEN START -- the old stream is stopped before its
    replacement begins, so the two never run together and the offered load can
    never rise above the higher of the two rates. The cost is a brief dip of one
    stream's worth (1/N of the total) while that stream is down; with N=40 that
    is 2.5%, and nothing like the drop to zero that killing every stream at once
    used to produce.
    """
    ports = ports_for(0)                       # single port set; no ambiguity with a gap
    per_new = new_mbps_per_ue / SUBFLOWS
    flows = flow_order(ue_map, ports)
    n = len(flows)
    step = TRANSITION_WINDOW / n
    t0 = time.time()
    for i, (ip, port) in enumerate(flows):
        kill_flow(ip, port)                    # old stream down first
        start_flow(ip, port, per_new)          # replacement up immediately after
        target = t0 + (i + 1) * step
        rest = target - time.time()
        if rest > 0:
            time.sleep(rest)
    print(f"[TrafficGen]   transition done in {time.time()-t0:.1f}s "
          f"over {n} streams at {per_new:.4f} Mbps each", flush=True)


def read_slot():
    try:
        with open(SLOT_FILE) as f:
            d = json.load(f)
        return int(d["epoch"]), float(d["mbps_per_ue"]), d.get("label", "")
    except Exception:
        return None


def cleanup(*_):
    print("\n[TrafficGen] cleaning up...", flush=True)
    sh(f"docker exec {open5gs_id} pkill -9 -f 'iperf -c'")
    for ue in ue_ids():
        sh(f"docker exec {ue} pkill -9 -f 'iperf -s'")
        sh(f"docker exec {ue} pkill -f 'ping -i 2'")
    sys.exit(0)


def main():
    signal.signal(signal.SIGINT, cleanup)
    signal.signal(signal.SIGTERM, cleanup)

    ues = ue_ids()
    ue_map = {}
    for ue in ues:
        ip = ue_ip(ue)
        if ip:
            ue_map[ue] = ip
    print(f"[TrafficGen] DOWNLINK-only UDP, {len(ue_map)} UEs x {SUBFLOWS} sub-flows "
          f"= {len(ue_map)*SUBFLOWS} flows; transition window {TRANSITION_WINDOW:.0f}s",
          flush=True)
    if not ue_map:
        print("[TrafficGen] no attached UEs found -- exiting", flush=True)
        return

    start_servers(ue_map)
    start_keepalive(ue_map)
    time.sleep(2)

    cur_epoch = None
    while True:
        slot = read_slot()
        if slot is None:
            time.sleep(POLL_SEC)
            continue
        epoch, mbps, label = slot

        if cur_epoch is None:
            n = arm_all(ue_map, epoch, mbps)
            print(f"[TrafficGen] slot {epoch} ({label}): cold start, {n} flows, "
                  f"{mbps:.4f} Mbps/UE total", flush=True)
            cur_epoch = epoch
        else:
            # heal a keepalive that died (e.g. after a container restart)
            for ue in ue_map:
                r = subprocess.run(f"docker exec {ue} pgrep -f 'ping -i 2'", shell=True,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                if r.returncode != 0:
                    sh(f"docker exec -d {ue} ping -i 2 10.45.1.1")
                    print(f"[TrafficGen]   keepalive restarted on {ue}", flush=True)

        if epoch != cur_epoch and cur_epoch is not None:
            print(f"[TrafficGen] slot {epoch} ({label}): staggered change to "
                  f"{mbps:.4f} Mbps/UE over {TRANSITION_WINDOW:.0f}s", flush=True)
            transition(ue_map, cur_epoch, epoch, mbps)
            cur_epoch = epoch

        time.sleep(POLL_SEC)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        cleanup()
