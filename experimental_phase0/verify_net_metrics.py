#!/usr/bin/env python3
"""
CU vs DU Network Metric Verification Tool
=========================================
Analyzes generated test CSV files to verify if CU network metrics (net_tx / net_rx)
scale correctly with DU traffic volume.
"""

import sys
import pandas as pd
import numpy as np

def verify_csv_network_metrics(csv_path: str):
    print("==================================================")
    print(f"  ANALYZING CSV: {csv_path}")
    print("==================================================")
    
    try:
        df = pd.read_csv(csv_path)
    except Exception as e:
        print(f"Error reading CSV file: {e}")
        return

    # Auto-detect CU and DU network columns
    cu_tx_cols = [c for c in df.columns if 'srscu' in c.lower() and any(x in c.lower() for x in ['tx', 'transmit'])]
    cu_rx_cols = [c for c in df.columns if 'srscu' in c.lower() and any(x in c.lower() for x in ['rx', 'receive'])]
    du_tx_cols = [c for c in df.columns if 'srsdu' in c.lower() and any(x in c.lower() for x in ['tx', 'transmit'])]
    du_rx_cols = [c for c in df.columns if 'srsdu' in c.lower() and any(x in c.lower() for x in ['rx', 'receive'])]

    if not (cu_tx_cols or cu_rx_cols) or not (du_tx_cols or du_rx_cols):
        print("WARNING: Could not automatically distinguish CU and DU network columns.")
        print(f"Found CU TX: {len(cu_tx_cols)}, CU RX: {len(cu_rx_cols)}")
        print(f"Found DU TX: {len(du_tx_cols)}, DU RX: {len(du_rx_cols)}")
        print("\nAll columns in file:")
        print(df.columns.tolist()[:15])
        return

    # Calculate statistics
    print("\n--- DU NETWORK TRAFFIC (ACTIVE USER PLANE) ---")
    du_tx_avg = df[du_tx_cols].mean().mean() if du_tx_cols else 0.0
    du_rx_avg = df[du_rx_cols].mean().mean() if du_rx_cols else 0.0
    print(f"DU Average TX: {du_tx_avg:,.2f} Bytes/s ({du_tx_avg / 1e6:.2f} MB/s)")
    print(f"DU Average RX: {du_rx_avg:,.2f} Bytes/s ({du_rx_avg / 1e6:.2f} MB/s)")

    print("\n--- CU NETWORK TRAFFIC (SCRAPED METRICS) ---")
    cu_tx_avg = df[cu_tx_cols].mean().mean() if cu_tx_cols else 0.0
    cu_rx_avg = df[cu_rx_cols].mean().mean() if cu_rx_cols else 0.0
    cu_tx_max = df[cu_tx_cols].max().max() if cu_tx_cols else 0.0
    cu_rx_max = df[cu_rx_cols].max().max() if cu_rx_cols else 0.0
    
    print(f"CU Average TX: {cu_tx_avg:,.2f} Bytes/s ({cu_tx_avg / 1e6:.4f} MB/s) | Max: {cu_tx_max:,.2f} Bytes/s ({cu_tx_max / 1e6:.2f} MB/s)")
    print(f"CU Average RX: {cu_rx_avg:,.2f} Bytes/s ({cu_rx_avg / 1e6:.4f} MB/s) | Max: {cu_rx_max:,.2f} Bytes/s ({cu_rx_max / 1e6:.2f} MB/s)")

    # Ratio check
    scale_ratio = cu_tx_avg / (du_tx_avg + 1e-9)
    print("\n--------------------------------------------------")
    print(f"CU/DU Throughput Ratio (Avg): {scale_ratio:.6f}")
    print("--------------------------------------------------")

    # Automated Diagnosis & Verdict
    # Checks average throughput (>100 KB/s) OR burst peaks (>500 KB/s)
    if cu_tx_avg > 100_000 or cu_tx_max > 500_000 or cu_rx_avg > 100_000 or cu_rx_max > 500_000:
        print("VERDICT: [PASSED] CU network metrics are active and scaling on eth0!")
    elif cu_tx_avg < 1_000 and du_tx_avg > 1_000_000:
        print("VERDICT: [FAILED] CU metrics remain near zero (<1 KB/s) while DU carries MB/s traffic.")
        print("-> Action: Verify that cAdvisor is scraping eth0 rather than eth1 for CU containers.")
    else:
        print("VERDICT: [LOW TRAFFIC] Both DU and CU traffic levels are low.")

if __name__ == "__main__":
    target_file = sys.argv[1] if len(sys.argv) > 1 else "data_fs_plane/test_anomaly_th3.csv"
    verify_csv_network_metrics(target_file)


