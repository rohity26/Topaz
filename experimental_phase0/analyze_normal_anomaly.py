#!/usr/bin/env python3
import glob
import os
from pathlib import Path
import pandas as pd
import numpy as np

# Path configuration
DATA_DIR = Path("data_fs_plane")

STRESS_TYPES = {
    "CPU": "CPU STRESS (Stress Type 1)",
    "MEM": "MEMORY STRESS (Stress Type 2)",
    "NET": "NETWORK STRESS (Stress Type 3)",
}

# The 5 CU feature names matching your reference format
CU_METRICS = ["cpu", "mem_pct", "mem_bytes", "net_tx", "net_rx"]

def get_matching_col(df_columns, cu_name, metric_key):
    """
    Finds the exact query column name matching the specific CU target and metric key.
    """
    keywords = {
        "cpu": ["cpu"],
        "mem_pct": ["mem_pct", "memory_percent", "memory_usage_pct"],
        "mem_bytes": ["mem_bytes", "memory_bytes", "memory_usage_bytes"],
        "net_tx": ["net_tx", "transmit_bytes", "tx_bytes"],
        "net_rx": ["net_rx", "receive_bytes", "rx_bytes"],
    }
    
    # Filter columns targeting the specific CU entity
    cu_cols = [c for c in df_columns if cu_name in c]
    
    for kw in keywords.get(metric_key, []):
        for col in cu_cols:
            if kw in col.lower():
                return col
                
    # Fallback search without strict CU name match
    for kw in keywords.get(metric_key, []):
        for col in df_columns:
            if kw in col.lower() and not any(x in col for x in ['_stressType', '_stepStress', 'phase']):
                return col
    return None

def analyze_cu_stress_type(st_key, st_title):
    print("\n" + "=" * 105)
    print(f"                               {st_title}")
    print("=" * 105)

    cu_targets = ["srscu0", "srscu1", "srscu2", "srscu3"]

    for cu in cu_targets:
        pattern = str(DATA_DIR / f"test_{cu}_{st_key}_rep*.csv")
        csv_files = sorted(glob.glob(pattern))

        if not csv_files:
            continue

        # Aggregate data if multiple reps exist for the target
        dfs = [pd.read_csv(f) for f in csv_files]
        df = pd.concat(dfs, ignore_index=True)

        if 'phase' not in df.columns:
            continue

        norm_mask = df['phase'] == 'NORMAL'
        strm_mask = df['phase'] == 'ANOMALY'

        norm_count = norm_mask.sum()
        strm_count = strm_mask.sum()

        print(
            f"\nTOPOLOGY: {cu:<18} | Normal Rows: {norm_count:<6} | Stress Rows: {strm_count:<5}"
        )
        print("-" * 105)
        print(
            f"{'Feature':<12} | {'Normal Mean':<18} | {'Stress Mean':<18} | {'Normal Std':<18} | {'Signal Shift (Δμ/σ)'}"
        )
        print("-" * 105)

        for feat_name in CU_METRICS:
            col_name = get_matching_col(df.columns, cu, feat_name)

            if not col_name:
                print(f"{feat_name:<12} | {'N/A':<18} | {'N/A':<18} | {'N/A':<18} | N/A")
                continue

            n_series = df.loc[norm_mask, col_name].dropna()
            s_series = df.loc[strm_mask, col_name].dropna()

            n_mean = n_series.mean() if not n_series.empty else 0.0
            s_mean = s_series.mean() if not s_series.empty else n_mean
            n_std = n_series.std() if not n_series.empty else 0.0

            std_for_calc = n_std if n_std > 1e-6 else 1.0
            shift = abs(s_mean - n_mean) / std_for_calc

            if "bytes" in feat_name:
                print(
                    f"{feat_name:<12} | {n_mean:<18.2f} | {s_mean:<18.2f} | {n_std:<18.2f} | {shift:.2f}"
                )
            else:
                print(
                    f"{feat_name:<12} | {n_mean:<18.4f} | {s_mean:<18.4f} | {n_std:<18.4f} | {shift:.2f}"
                )

def main():
    for st_key, st_title in STRESS_TYPES.items():
        analyze_cu_stress_type(st_key, st_title)
    print("\n" + "=" * 105 + "\n")

if __name__ == "__main__":
    main()


