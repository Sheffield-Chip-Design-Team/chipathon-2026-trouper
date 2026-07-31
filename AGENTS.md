/resources contains relevant datasheets
/sim contains the system simulation
/planning contains MD files for planning

planning/Trouper Chip Specification.md should be precise

Read CLAUDE.md

## Running LibreLane (P&R)

See the `pnr-run` skill (`.claude/skills/pnr-run/SKILL.md`) for Docker invocation, FD vs AS standard cells, and reading WNS/DRC results.

## homelab-sge (EDA job scheduler)

See the `sge-job` skill (`.claude/skills/sge-job/SKILL.md`) for submitting, polling, and reading results from `hqsub` jobs, and setting up `rtl-test/ol_*/runs` NFS symlinks.

## Block cocotb regression

See the `block-regression` skill (`.claude/skills/block-regression/SKILL.md`) for running the full cocotb suite for a specific `src/` block via SGE (NFS sync, block → suite mapping, special-arg suites like `trouper_capture`). Currently onboarded: `psram_buf_ctrl`.
