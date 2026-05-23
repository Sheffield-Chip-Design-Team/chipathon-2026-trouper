# SGE Resource Profiling

## What is homelab-sge?

homelab-sge is a lightweight job scheduler for a home lab cluster. Jobs are submitted
via `hqsub` and run inside Docker containers on cluster nodes. The scheduler tracks
CPU, RAM, and GPU reservations per node and queues jobs when resources are unavailable.

The cluster has two nodes:
- **nas-server** — 6 CPUs, ~44G RAM (NAS host, also runs the `hqd` daemon)
- **gaming-pc** — 22 CPUs, ~30G RAM, 13th Gen Intel Core i7, DDR5 6000 MHz (primary compute node for EDA workloads)

All nodes share an NFS mount at `/srv/eda/`. Job scripts and design files must live
under `/srv/eda/designs/<user>/`, which maps to `/foss/designs/` inside the container.
Job logs are written to `/srv/eda/logs/<user>/job-<ID>.o/.e`.

The daemon runs on `nas.home:4783` and is managed with `hqd start/stop` and the
REST API at `http://nas.home:4783/api/`.

## Methodology

Single block (`weight_gen`) run in isolation on `gaming-pc` to find minimum viable
CPU and RAM allocations. Hold violation checker suppressed (`HOLD_VIOLATION_CORNERS: ""`)
to avoid non-deterministic timing noise from routing variation.

Block stats: 13,430 cells, 320k µm² core area, 580×598 µm die.

## Results

| Run | CPUs | RAM | DRT_THREADS | Runtime | Result |
|-----|------|-----|-------------|---------|--------|
| Baseline | 8 | 16G | 16 | 1m05s | PASS |
| Test A | 4 | 8G | 4 | 1m35s | PASS |
| Test B | 2 | 8G | 2 | 2m12s | PASS |
| Test C | 4 | 4G | 4 | 1m48s | PASS |

## Conclusions

- **DRT threading**: Only detailed routing (DRT) is multithreaded. All other stages
  (synthesis, placement, CTS, STA, streamout) are single-threaded.
- **CPU scaling**: 16→4 threads costs ~30s; 4→2 threads costs ~37s. Diminishing returns
  below 4 threads for a block this size.
- **RAM**: 4G is sufficient for `weight_gen`. 8G→4G adds only ~13s.
- **Minimum viable**: **4 CPUs / 4G RAM** for small blocks (~13k cells).

## Recommended Allocations

| Block size | Cells (approx) | CPUs | RAM | DRT_THREADS |
|------------|---------------|------|-----|-------------|
| Small | < 5k | 2 | 4G | 2 |
| Medium | 5k–20k | 4 | 4G | 4 |
| Large | 20k–100k | 8 | 8G | 8 |
| XL (mimo_rx_top) | > 100k | 16 | 16G | 16 |

> These are initial estimates based on `weight_gen` profiling only. Validate for
> larger blocks (especially `picorv32_wrap` and `mimo_rx_top`) before applying broadly.

## Runtime vs Cell Count

Observed runtimes at 4 CPUs / 4G / DRT_THREADS=4 across 16 blocks:

| Block | FFs | Logic cells | Total | Runtime |
|-------|-----|-------------|-------|---------|
| ol_irq_ctrl | 20 | 35 | 55 | 0m40s |
| ol_ahb_lite_bus | 12 | 62 | 74 | 0m42s |
| ol_nr_corr | 32 | 86 | 118 | 0m40s |
| ol_spi_master | 75 | 257 | 332 | 0m48s |
| ol_spi_slave | 135 | 275 | 410 | 0m51s |
| ol_frontend_buf_ctrl | 256 | 401 | 657 | 0m59s |
| ol_sd_remod | 140 | 977 | 1117 | 0m56s |
| ol_packet_ctrl_fsm | 129 | 1222 | 1351 | 1m09s |
| ol_dc_removal | 331 | 2385 | 2716 | 1m33s |
| ol_mag2 | 252 | 2511 | 2763 | 1m39s |
| ol_noise_floor_est | 422 | 2770 | 3192 | 2m19s |
| ol_nr_inner | 741 | 3614 | 4355 | 2m23s |
| ol_nr_outer | 677 | 4021 | 4698 | 2m06s |
| ol_energy_meas | 525 | 4804 | 5329 | 2m20s |
| ol_training_acc | 906 | 5238 | 6144 | 2m38s |
| ol_mrc_combiner | 470 | 6262 | 6732 | 2m54s |

### Key observations

- **~40s fixed overhead** regardless of block size (container startup, synthesis init, floorplan).
  Blocks under ~200 cells are dominated by this — 2 CPUs would be equally fast.
- **Roughly linear scaling** above ~1k cells: ~20–25s per 1k additional cells.
- **FFs matter more than logic**: FF count correlates more strongly with runtime than
  combinational cell count, likely due to CTS and hold/setup repair time.
- **Estimated runtimes**: picorv32 (~11k cells) expected ~4–5 min; sd_decimator/calib
  (~8–9k cells) expected ~3–4 min.
