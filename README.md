<p align="left">
  <img src="https://img.shields.io/badge/MATLAB-R2020b%2B-blue" alt="MATLAB">
  <img src="https://img.shields.io/badge/license-MIT-success" alt="License: MIT">
</p>

# RLNC Kaspa IBD Demo

A MATLAB simulation of **Random Linear Network Coding (RLNC)** over a **Kaspa‑like blockDAG** with a sliding‑window **IBD** (Initial Block Download) model.  
It compares three strategies per window:
- **blk‑full**: naive full block transfer,
- **unique**: ideal de‑duped pull,
- **RLNC**: rateless RLNC with loss and optional feedback rounds.

CSV outputs summarize per‑window and total byte/time costs and savings.

> **Author:** you + ChatGPT (2025‑10‑05)

---

## Quickstart

1. Clone or download this repo.
2. Open MATLAB in the repo root.
3. Run the demo:
   ```matlab
   run_demo
   ```

This will invoke `rlnc_kaspa_ibd_demo()` and write timestamped CSVs under `results/` like:
```
rlnc_ibd_results_YYYYMMDD_HHMMSS.csv
TOTALS_rlnc_ibd_results_YYYYMMDD_HHMMSS.csv
```

## Usage (direct)

You can also call the main entry point manually:
```matlab
rlnc_kaspa_ibd_demo();
```

Edit the **Experiment Parameters** section at the top of `rlnc_kaspa_ibd_demo.m` to change:
- DAG depth, width, parent fan‑in
- field (`GF2` vs `GF256`)
- chunk size
- loss probability, peers
- feedback rounds, batch size
- sliding window size/stride
- link bandwidth / RTT model

## Files

- `rlnc_kaspa_ibd_demo.m` — main simulation (your provided script; lightly wrapped for repo).
- `run_demo.m` — convenience wrapper that creates `results/` and runs the sim.
- `examples/` — placeholder for sample CSVs or plots you want to commit.
- `results/` — output directory (git‑ignored).
- `LICENSE` — MIT.
- `.gitignore` — ignores MATLAB autosaves, binaries, and generated results.

## Notes

- This is a pure simulation (no Kaspa node integration).
- The GF(256) ops use an AES‑poly (0x11D) log/exp table.
- Time model: peer‑parallel throughput plus optional per‑round RTT penalty.
