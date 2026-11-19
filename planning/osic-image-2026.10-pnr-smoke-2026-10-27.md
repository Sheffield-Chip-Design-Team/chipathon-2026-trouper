# iic-osic-tools 2026.10 image — P&R smoke test — 2026-10-27

**Status: OPEN — the 2026.10 image does NOT run the canonical flow in usable
time.** Post-GRT `repair_design` (LibreLane step `OpenROAD.RepairDesignPostGRT`)
takes 36 s on `:chipathon26` (job 5842) and stalls for 70+ min on `:2026.10`
(job 6700). Keep tapeout P&R on `:chipathon26` until this is resolved.
Isolation job 6711 **disproved** the wire-length hypothesis: same stall, same
iteration, same stack with the limit removed.

## Why

The SGE daemon image (`/etc/hlab-sge/config.yaml` → `docker.image`) was switched
from `hpretl/iic-osic-tools:chipathon26` to `:2026.10`. Job 6700 re-runs the
canonical config `src/config/trouper_top.json` unchanged to check the flow
still works; reference is job 5842 (SS WNS −15.21 ns, TNS −1159, slew/cap 2/0,
DRC/LVS/XOR/antenna 0, util 72.7 %, whole flow 25 min).

CLAUDE.md, AGENTS.md and the `run-pnr` skill still pin `:chipathon26` — not
updated, deliberately, until the image is proven.

## What changed between the images

| | `:chipathon26` (5842) | `:2026.10` (6700) |
|---|---|---|
| `IIC_OSIC_TOOLS_VERSION` | — | 2026.10 |
| LibreLane | — | `26Q4-407-geb14e40b7` |
| Yosys | — | 0.70 |
| Magic / Netgen | — | 8.3.685 / 1.5.324 |
| gf180mcuD (ciel) | `7b70722e33c0…` | `1689ac3f2dc7…` |

PDK file diff (files the flow actually reads, extracted with `docker create` +
`docker cp`):

- `gf180mcu_fd_sc_mcu7t5v0__ss_125C_3v00.lib` — **byte-identical** (md5 `9a61a2f3…`).
- `gf180mcu_fd_sc_mcu7t5v0__nom.tlef` — 4 lines: `ANTENNAGATEPLUSDIFF 2 → 15`
  on four routing layers. Antenna rule only; cannot affect `repair_design`.
  Antenna counts from this image are **not comparable** to 5842's 0.

`/foss/pdks/versions.txt` in 2026.10 is stale (lists Magic 8.3.589; binary is
8.3.685) — don't use it as a version record.

LibreLane 26Q4 runs more steps: post-GRT repair is step 41 on 5842's numbering
vs step 82 here only because the run dir held two passes (below); per-pass the
step order matches.

## Observation — job 6700

- Steps through global routing completed with step runtimes comparable to
  5842 (synth ~30 s, floorplan ~2.5 min, GPL repair ~5 min, CTS ~1 min).
- `repair_design -verbose -max_wire_length 450.0 -slew_margin 65.0 -cap_margin 65.0`
  reached iteration ~18000 of 40439 nets in ~30 s (67 buffers, 45 nets
  repaired), then **no output for 70+ min**; OpenROAD 100 % on one thread,
  RSS flat ~2 GB. Job CANCELLED 2026-10-27T01:04:30Z (elapsed 1:45) with the
  log still frozen at iteration 18000 — no further progress in ~90 min.
- The run dir contains **two passes** (steps 01–41 from 22:20 GMT, 42–82 from
  23:19 GMT); both stalled in this same step. The scheduler's `start_time` is
  23:19, so the first pass was killed and the job restarted — cause unknown.
- Other new warnings (not yet checked against 5842): `RSZ-0020` 2 floating nets
  (VDD/VSS), `CTS-0041` `PSRAM_SCK_OUT` 0 sinks / `net22` 1 sink.

## Root cause (stack traces)

Two samples a few seconds apart, via
`docker exec --privileged -u 0 <container> gdb -p <pid> -batch -ex "bt 40"`
(host-side gdb has no symbols — the binary is in the container mount
namespace; plain `docker exec` lacks ptrace):

```
rsz::Resizer::repairDesign → RepairDesign::repairDriver → repairNet
  → repairNetWire / repairNetVia (recursing along one long net)
  → RepairDesign::makeRepeater
      sample 1: → Resizer::resizeToTargetSlew
                → est::EstimateParasitics::ensureWireParasitic
                → grt::GlobalRouter::updateDirtyRoutes → initNetlist
                → addResourcesForPinAccess
      sample 2: → Resizer::insertBufferBeforeLoads → odb::dbInsertBuffer
                → dbITerm::connect → sta::Sta::connectPinAfter
                → sta::Sdc::connectPinAfter (exception-path map)
```

Not a deadlock — **per-repeater cost explosion**. In this OpenROAD each
repeater inserted by the wire-length split triggers an incremental global
re-route (`updateDirtyRoutes` → pin-access rebuild) to get parasitics, plus an
SDC exception-map update on every new connection (our SDC carries many
MCP / `-through` exceptions). The old OpenROAD did the same repair in 36 s.

Hypothesis (DISPROVED by job 6711, below): our non-default
`{GRT_,}DESIGN_REPAIR_MAX_WIRE_LENGTH 450` (job 5842) is the trigger.

## Isolation — job 6711: wire-length limit is NOT the trigger

`rtl-test/scripts/run_pnr_a40_image_wlnone_20261027.sh`: canonical config with
both wire-length keys deleted (log confirms `repair_design -max_wire_length
0.0`), `--to OpenROAD.RepairDesignPostGRT`, `timeout 45m`.

- Every step up to post-GRT repair ran normally. Post-GPL repair without the
  limit: +9.7 % area / 1707 buffers (6700 with 450 µm: +11.2 % / 2452).
- Post-GRT repair (step 41) started 01:30:59 UTC, printed iteration 18000
  (21589 remaining) at 01:31:14, then **froze** — same iteration as 6700.
  The 45-min guard killed the job at 01:59:23 UTC (exit 124, state FAILED)
  with the log still at iteration 18000 — 28 min with no progress.
- Two gdb samples (`reports/osic-2026.10/job6711_repair_design_gdb.txt`), same
  path as 6700: `repairNetWire → makeRepeater →`
  (1) `resizeToTargetSlew → ensureWireParasitic → GlobalRouter::updateDirtyRoutes
  → findRouting → FastRouteCore::run → routeMonotonicAll`;
  (2) `insertBufferBeforeLoads → dbITerm::connect → Sdc::connectPinAfter →
  ExceptionThru::connectPinAfter → PinSet::intersects`.

So the net being split is slew/cap-driven, not wire-length-driven; repeaters
are inserted either way and each one costs an incremental FastRoute re-route
plus a scan of every SDC `-through` exception set.

Remaining suspects (untested):
1. SDC `-through` exceptions (`pnr_32m_scoped_v25_b6.sdc` carries many MCP
   `-through` paths) — `ExceptionThru::connectPinAfter` per pin connect.
2. New OpenROAD incremental-GRT-per-repeater in post-GRT repair — upstream
   behaviour change, not ours.

Next isolation: same stop point with an SDC stripped of `-through` exceptions.
If that passes → (1); if not → (2), report upstream with both traces.

## Side findings

- `hqstat` (all forms) fails: `HTTP 400: 'UNCERTAIN' is not a valid JobState` —
  the server has a job state the client doesn't know. Use
  `curl -H "Authorization: Bearer $(cat ~/.config/hlab-sge/token)" $HLAB_SGE_URL/api/jobs/<ID>`.
- `hqdel` prompts `[y/N]`; non-interactive use needs explicit confirmation.

## Artifacts

- Job 6700 log: `/srv/eda/runs/timothyn-dev/lora-mimo/6700/pnr_a40_image_smoke/pnr.log`
- Script: `rtl-test/scripts/run_pnr_a40_image_smoke_20261026.sh` (NFS)
- Full gdb traces: `reports/osic-2026.10/job6700_repair_design_gdb.txt`,
  `reports/osic-2026.10/job6711_repair_design_gdb.txt`.
