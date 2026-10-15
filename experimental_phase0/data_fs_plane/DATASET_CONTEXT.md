# `train_normal_dl_udp_50h.csv` — context for the GPU-side pipeline

**Read this before running `build_dataset.py` on this file.** This dataset comes from a
testbed that was reconfigured after the previous training set was collected. The CSV schema
is a strict superset of the old one, so the existing pipeline will run without error — but it
will silently build a **broken CU network feature** unless you apply the one change in §5.

---

## 1. Identity

| | |
|---|---|
| File | `train_normal_dl_udp_50h.csv` |
| Size | 836 MB |
| Rows | 143,836 |
| Columns | 874 |
| Collected | 2026-09-18 19:28:55 → 2026-09-20 21:28:54 UTC (exactly 50.000 h) |
| MD5 | `8f88c0f9e5427a29651a6240c93ecb1f` |
| Mode | normal only — **no stress injected anywhere in this file** |

Verify the transfer with `md5sum` before using it.

All 14 `*_stressType` columns are 0 for every row; `phase` is `NORMAL` throughout;
`rrc_release_detected` and `any_stress_active` are 0 throughout. This is a pure
training/baseline set. Test sets with stress are collected separately.

## 2. Testbed topology

4 CUs, 10 DUs, 10 UEs, open5gs 5GC, all Docker containers on one host.

| CU | DUs | PCI ids | `N_DU` |
|---|---|---|---|
| `srscu0` | `srsdu0`, `srsdu1` | 1, 2 | 2 |
| `srscu1` | `srsdu2` | 3 | 1 |
| `srscu2` | `srsdu3`, `srsdu4`, `srsdu5` | 4, 5, 6 | 3 |
| `srscu3` | `srsdu6`–`srsdu9` | 7, 8, 9, 10 | 4 |

This matches `TOPOLOGY_REGISTRY` in `build_dataset.py` — **no change needed there.**

CU/DU split is Option 2 (F1 interface). DU↔UE is Option 8 over ZMQ I/Q at 23.04 Msps, which
is why DU `net_tx`/`net_rx` sit at ~80 MB/s: that is the I/Q sample stream, not user traffic,
and it dwarfs the F1 payload. That was equally true of the old dataset.

## 3. What changed vs. the old dataset (`train_normal_th3.csv`)

### 3a. The CU now has TWO network interfaces (this is the important one)

Previously each CU had a single `eth0` carrying everything. Now:

```
                 eth2                          eth0
   5G core  <--------------->  CU  <--------------------->  DU  <--- ZMQ --->  UE
            (N3/N2, core net)      (F1, midhaul)
```

| interface | faces | carries |
|---|---|---|
| `eth0` | the DU | **F1 / midhaul** — this is where NET stress will be injected |
| `eth2` | the 5G core | N3 user plane from the UPF |

Downlink therefore enters the CU on `eth2` and leaves on `eth0`. The pair
`eth0_tx / eth2_rx` is a **byte-conservation check across the CU**: it is load-invariant,
because both counters scale together with traffic. Measured over all 143,836 rows:

| CU | `eth0_tx / eth2_rx` | sd | cv |
|---|---|---|---|
| `srscu0` | 1.00442 | 0.00438 | 0.44% |
| `srscu1` | 1.00433 | 0.00763 | 0.76% |
| `srscu2` | 1.00445 | 0.00395 | 0.39% |
| `srscu3` | 1.00446 | 0.00296 | 0.30% |

The constant 1.0044 offset is the PDCP/GTP header added on the way to the DU — real, expected,
and stable. `srscu1` is the widest because it has only one DU and therefore the lowest
absolute throughput; its spread widens further in the low-load slots. That is per-sample
noise, not drift: its 50 h mean is identical to the 12 h mean to five decimals.

### 3b. Traffic is now DOWNLINK-only UDP (previously uplink)

- `iperf` **v2**, UDP: `iperf -c <ue_ip> -u -b <rate>M -p <port> -t 1500`
- Clients run in `open5gs_5gc`, servers in each UE bound to `tun_srsue`
- 10 UEs × 4 sub-flows = 40 concurrent flows
- Rate follows a 25-slot curve, 900 s per slot = 6.25 h per cycle, **8 complete cycles** in 50 h
- Slot rates (Gb per window): `11.0, 8.1, 5.6, 3.6, 2.7, 1.9, 3.0, 5.0, 7.1, 11.1, 11.2, 11.9,
  12.4, 12.3, 13.0, 13.1, 12.9, 12.7, 12.4, 12.2, 12.0, 13.0, 14.0, 15.0, 14.0`

UDP matters: it is open-loop. Under packet loss the sender does **not** back off, so loss
shows up purely as a conservation violation and not as a throughput collapse that would look
like an ordinary load change.

### 3c. New column: `traffic_transition`

Rate changes are now ramped over 60 s (one sub-flow at a time) instead of stepping, so the
aggregate curve never overshoots outside `[min(A,B), max(A,B)]`. Rows within 90 s of a slot
change are flagged `traffic_transition = 1` — **14,492 rows, 10.08% of the file.**

The old dataset has no such column and instead contains hard steps at slot boundaries.
Decide deliberately whether to drop these rows, keep them, or use the flag as a feature.
They are *valid* normal data, just non-stationary.

## 4. Feature-level comparison (old → new)

Means over each full file. "aligned" = no action needed.

| feature | old | new | note |
|---|---|---|---|
| CU `net_tx` (eth0) | 316.6 kB/s | 316.2 kB/s | aligned — now means "to the DU" |
| **CU `net_rx` (eth0)** | **321.1 kB/s** | **6.1 kB/s** | **BROKEN — see §5** |
| CU `cpu`, `mem_pct`, `mem_bytes` | — | — | aligned within 1.5% |
| CU `fs_reads`, `fs_writes` | 0 | 0 | zero in both, dropped by `CU_FEAT_SLICE` |
| DU `net_tx` / `net_rx` | ~85 MB/s | ~79 MB/s | aligned (ZMQ-dominated) |
| PCI `dl_brate` | 86 kbps | 2.67 Mbps | 29.5× — downlink now carries the load |
| PCI `ul_brate` | 3.40 Mbps | 0.35 Mbps | 0.10× — uplink is now near-idle |
| PCI `dl_bs` | 0.67 | 324 | 492× — downlink buffer status carries the signal |
| PCI `bsr` | 2,966 | 7.3 | **effectively dead** — uplink buffer status report |
| PCI `dl_nof_ok` / `ul_nof_ok` | 29.8 / 80.2 | 102.4 / 40.5 | roles swapped |
| PCI `cqi`, `ta_ns`, `pusch_snr_db`, `ul_mcs`, `dl_ri` | — | — | identical once per-scrape dropout rows are excluded |
| PCI `pucch_snr_db` | 26.1 dB | 20.3 dB | genuinely lower |
| the 8 always-zero error counters | 0 | 0 | zero in both |

`bsr` going dead is the direct consequence of generating downlink only. It is not a fault.
If the old model leaned on `bsr` as a load proxy, `dl_bs` is its replacement.

Per-scrape dropouts (a PCI field reading 0 for one row) are **4× rarer** than in the old
file: 2.1% of rows vs 8.4%.

## 5. REQUIRED CHANGE — `build_dataset.py` reads the wrong CU interface

`CADVISOR_PATTERNS` hardcodes `interface="eth0"` for both `net_tx` and `net_rx`. For a DU that
is correct (it has one data interface). **For a CU it is now wrong**: the core-side traffic
moved to `eth2`, so `net_rx` on `eth0` picks up only the F1 uplink control plane — 6.1 kB/s
instead of 315 kB/s, ~2% of its old value.

What that does to the derived features in `run_experiment.py` (lines 208–215):

| CU | `net_diff` (eth0-only) | `net_ratio` (eth0-only) | `net_ratio` with eth2 |
|---|---|---|---|
| `srscu0` | 155,049 ± 63,720 | 53.49 ± 23.38 | **1.00442 ± 0.00438** |
| `srscu1` | 154,726 ± 63,783 | 48.91 ± 22.02 | **1.00433 ± 0.00763** |
| `srscu2` | 155,166 ± 63,688 | 55.61 ± 24.24 | **1.00445 ± 0.00395** |
| `srscu3` | 155,151 ± 63,702 | 55.21 ± 23.84 | **1.00446 ± 0.00296** |

With `eth0` alone, `net_ratio` has cv ≈ 44% and tracks the traffic curve exactly — it is a
load signal, not a conservation signal. That is the load confound that produced **F1 = 0.00
for CU NET detection** on the previous setup, and the two-interface split exists specifically
to remove it. With `eth2` the cv is 0.3–0.8%, tighter than the old single-interface
ratio's 2.6%.

### The fix

The comment in `run_experiment.py:209` — *"net_ratio = net_tx / net_rx : <1 under packet
loss"* — is already exactly right. Only the column `net_rx` resolves to is wrong. Fix it in
`build_dataset.py` and **everything downstream works unchanged**: same array shapes, same
`CU_FEAT_SLICE`, same `CU_IRATE_IDX`, same derived positions 5 and 6.

Two obstacles, both handled below:
1. The eth2 columns exist only in the **raw** `sum  (irate(...))` form. They do **not**
   contain `by (instance)`, which `_find_cadvisor_col()` requires as its discriminator.
2. Only CUs need the override. DUs must keep using `eth0`.

```python
# --- add next to _find_cadvisor_col() ---------------------------------------
def _find_cu_eth2_rx(cu_id: str, all_cols: list[str]) -> str:
    """CU downlink ingress from the core.

    The CU now has two data interfaces: eth0 faces the DU (F1) and eth2 faces the
    5G core. Downlink enters on eth2 and leaves on eth0, so the conservation pair
    is eth0_tx / eth2_rx. The eth2 queries were emitted in the raw
    `sum  (irate(...))` form, which has no "by (instance)", so that discriminator
    cannot be applied here. interface="eth2" is itself unique enough.
    """
    matches = [
        c for c in all_cols
        if f'name="{cu_id}"' in c
        and 'instance="cadvisor:8080"' in c
        and "container_network_receive_bytes_total" in c
        and 'interface="eth2"' in c
    ]
    if len(matches) != 1:
        raise ValueError(f"{cu_id}: expected 1 eth2 rx col, got {len(matches)}: {matches}")
    return matches[0]


# --- replace get_cu_columns() ------------------------------------------------
def get_cu_columns(cu_id: str, all_cols: list[str]) -> list[str]:
    """Return 7 cadvisor columns for the CU in fixed order.

    net_tx stays on eth0 (bytes out to the DU); net_rx moves to eth2 (bytes in
    from the core). Feature order and array shape are unchanged.
    """
    cols = []
    for name, req, extra, forb in CADVISOR_PATTERNS:
        if name == "net_rx":
            cols.append(_find_cu_eth2_rx(cu_id, all_cols))
        else:
            cols.append(_find_cadvisor_col(cu_id, all_cols, req, extra, forb))
    return cols
```

`get_du_columns()` needs **no change** — DUs genuinely have one data interface.

### Sanity check after applying it

`cu[:, 5] / cu[:, 6]` (post-`N_DU`-division `net_tx / net_rx`) must land at **1.0043–1.0045**
with sd < 0.01 for all four CUs on this normal-only file. If you see ~50, the override did
not take effect.

## 6. Where NET stress will be injected (for the test sets)

`tc qdisc add dev eth0 root netem loss X%` inside the CU container — **egress only**, on the
**F1 side**. netem sits at the root qdisc, which is *above* the netdev byte counter in the
egress path, so a dropped packet never increments `eth0_tx`. Verified directly in an isolated
netns: 1000 packets in → `tx=473`, `rx=473`, `dropped=527`, `tx_dropped=0`.

Consequence: under downlink CU NET stress, `eth2_rx` still counts every byte arriving from the
core, but `eth0_tx` counts only what survived. **`net_ratio` falls below its 1.0044 baseline
in proportion to the loss rate.** With `eth0` alone that signal does not exist, which is §5's
whole point.

Note the asymmetry: the tool only affects the direction it is attached to. An egress qdisc on
`eth0` cannot drop bytes the CU *receives*. Since this dataset is downlink-only, stress on the
CU's `eth0` is directly in the path of the user traffic.

## 7. Secondary issue — sampling is not uniform

| | old `train_normal_th3.csv` | this file |
|---|---|---|
| median Δt | 1.001 s | **1.248 s** |
| mean ± sd | 1.001 ± 0.001 s | 1.251 ± 0.119 s |
| min / max | 0.996 / 1.059 s | 1.000 / 2.052 s |
| rows within 1.00 ± 0.05 s | 100.0% | 1.4% |

The scrapper targets 1.0 s (`FETCH_INTERVAL = 1.0`) but sleeps only the leftover time
(`max(0, FETCH_INTERVAL - elapsed)`). A pass over the query file now costs ~1.25 s, so the
sleep is zero on ~99% of iterations and the loop free-runs.

TopoAR's one-step-ahead objective (`cu_hat[:, :-1]` vs `cu_b[:, 1:]`) assumes a constant step.
Here a step ranges 1.00–2.05 s, ±9% around the median.

**This is second-order, not fatal**, and it does *not* affect the rate-type features
(`net_tx`, `net_rx`, `dl_brate`, `cpu`): those are Prometheus `irate(...[5m])` values, already
expressed per-second, so they do not scale with the row gap. If you want it gone, resample
onto a uniform ~1.25 s grid before building the arrays. Do it *after* `build_dataset.py`'s
filtering so `block_id` / segment boundaries stay meaningful.

**Do not** re-collect over this. It was a deliberate decision to fix downstream rather than
restart a 50 h run.

A related subtlety: the cAdvisor-sourced columns (all 7 per entity) only change every ~2.3 s —
cAdvisor refreshes container stats slower than the CSV samples them, so ~44% of rows repeat
the previous value for those columns. The InfluxDB-sourced PCI columns are fresh on 98% of
rows. The CSV oversamples the cadvisor half; it does not lose anything.

## 8. Column-naming fragility (check before every run)

PCI column names embed the RNTI: `PCI-3_RNTI-4601_bsr`. If a UE re-attaches mid-collection it
gets a new RNTI and that DU's 30 columns silently become a *new, empty* set of columns while
the old ones stop updating. Three earlier collection attempts were discarded for exactly this.

**This file is clean:** all 10 PCIs are on `RNTI-4601` for all 143,836 rows, and all 300 PCI
columns (10 DU × 30 fields) carry data. Confirm with:

```python
import csv, re
h = next(csv.reader(open("train_normal_dl_udp_50h.csv", newline="")))
print(sorted({m.group(1) for c in h for m in [re.match(r"PCI-\d+_RNTI-(\d+)_", c)] if m}))
# must print exactly ['4601']
```

Any test CSV paired with this training file must be checked the same way, and must use the
**same RNTI**, or the train and test column sets will not align.

## 9. Quality summary of this file

- 0 all-zero rows, 0 NaN cells in any numeric column
- 1 column is non-numeric by design (`phase`, always the string `NORMAL`)
- All 98 cadvisor features (14 entities × 7) resolve to exactly one column each
- All 300 PCI columns present and carrying data
- 8 eth2 columns present (4 CU × rx/tx)
- Aggregate `dl_brate` spans 2.58e4 → 5.31e7 — the full traffic curve is swept, 8 times
- 0 traffic-generator watchdog restarts during the 50 h window

## 10. Do not, without asking first

- **Do not retrain any model** — the owner has explicitly withheld permission for retraining.
  Evaluate with existing checkpoints unless told otherwise.
- **Do not merge this with `train_normal_dl_udp_1p5h.csv`.** That is a separate 1.5 h
  validation set collected under the same configuration and must stay separate.
- **Do not "fix" the dataset by re-collecting.** Both known issues (§5, §7) are downstream
  code changes.
