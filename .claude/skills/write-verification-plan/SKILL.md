---
name: write-verification-plan
description: Create or revise evidence-based block-level RTL verification plans from design source, specifications, traceability, risks, formal properties, and actual tests. Use when asked to write a verification plan, test plan, verification closure tracker, coverage plan, or requirement-to-test matrix for one or more Verilog/SystemVerilog blocks under `src/`, especially documents under `planning/verification-plan/`.
---

# Write Verification Plan

Create a precise closure tracker, not a generic list of desirable tests. Separate
what is already verified from partial evidence, missing tests, analysis-only
requirements, and specification/RTL conflicts.

Read [references/plan-template.md](references/plan-template.md) before drafting.

## Workflow

### 1. Establish scope

1. Read repository guidance (`AGENTS.md`, then `CLAUDE.md` when directed).
2. Resolve every requested DUT to its current `src/` RTL file.
3. Create one plan per DUT unless the user explicitly requests a combined
   interface/system plan. Shared tests may appear in multiple plans when each
   plan explains the block-specific evidence they provide.
4. Default the output to
   `planning/verification-plan/<block-name>-verification-plan.md`.
5. Preserve unrelated worktree changes.

### 2. Build the evidence set

Inspect sources in this order:

1. Current RTL, including its top-level instantiation and integration logic.
2. `planning/Trouper Chip Specification.md` requirement rows for the block.
3. Authoritative interface documents such as `planning/Register Map.md`.
4. `planning/Traceability.md` and `planning/Open Risks.md`.
5. Current block documents and focused migration/design plans.
6. Existing cocotb, legacy RTL, differential, and formal tests.
7. Test Makefiles/configuration to establish what is compiled and how it runs.
8. Physical constraints or signoff reports when timing/CDC is in scope.

Use `rg`/`rg --files` to find relevant material. Read test bodies, assertions,
stimulus ranges, and scoreboards; never infer coverage from a filename or
Traceability entry alone.

Treat current RTL and authoritative current specifications as primary evidence.
Flag stale secondary documents instead of silently copying them.

### 3. Audit behavior and requirements

For each requirement and meaningful RTL behavior:

- Identify reset behavior, state transitions, legal/illegal inputs, boundary
  values, precedence on simultaneous events, sticky/pulse lifetime, and
  protocol timing.
- Trace each output and side effect through integration wiring where needed.
- Identify clock-domain, reset-domain, clock-enable, bus-arbitration, and
  physical-timing contracts.
- Look for undocumented robustness cases revealed by RTL review.
- Record explicit non-goals and assign interface behavior to the owning block.
- Flag specification/RTL/test disagreements as resolution-gated rows. Do not
  invent an expected result when the contract is unresolved.

### 4. Classify existing evidence

Use these status rules consistently:

- `✅ done` — the named current test/property directly checks the stated
  behavior and has credible pass evidence. Cite a known job/commit only when it
  exists in repository evidence.
- `🟨 partial` — relevant evidence exists but does not close the complete row,
  is integration-only where cycle-level proof is missing, or is stale and
  needs a current rerun.
- `⬜ new` / `⬜ planned` — no adequate current test or signoff evidence exists.
- `⚠️ spec/RTL issue` — expected behavior must be resolved before the test can
  be finalized.
- `ANALYSIS` / `INTERFACE` — use only where the requirement is legitimately
  satisfied by analysis, construction, or another block.

Do not mark a requirement done merely because a test writes or reads the
associated register. State the observable pass criterion.

### 5. Write the plan

Follow the referenced template and the style of
`planning/verification-plan/psram-buf-ctrl-verification-plan.md`.

Include:

1. DUT, scope, and exact inputs reviewed.
2. Current methodology and honest closure gaps.
3. A functional-coverage/constrained-random strategy tied to identified axes.
4. A numbered test table with test, type, testbench, requirement/gap, and
   status.
5. Directed closure order that resolves contract issues before writing tests.
6. Exact runnable regression commands using current paths and required
   arguments.
7. Explicit non-goals and interface boundaries.

Keep each row atomic enough to have one clear pass criterion. Retain directed
tests after randomization; close on coverage or documented waivers, not seed
count.

### 6. Validate

1. Cross-check every requirement ID and register address against its source.
2. Confirm every named test function/file exists and actually exercises the
   claimed behavior.
3. Confirm commands reference current sources and required environment
   arguments.
4. Run `git diff --check` on the new plan.
5. Run lightweight available validation where useful. If a simulator or
   signoff tool is unavailable, say so; do not claim a run.
6. Report the created files and the most important surfaced gaps.

## Guardrails

- Do not modify RTL, tests, specifications, or traceability unless the user also
  requested implementation or reconciliation.
- Do not copy historical job numbers or “done” claims without repository
  evidence.
- Do not require deterministic reset values from intentionally resetless
  storage.
- Do not confuse RTL simulation at a target frequency with STA/signoff closure.
- Do not hide interface conflicts under a broad “integration test” row.
- Keep `planning/Trouper Chip Specification.md` precise when citing it; quote
  requirement meaning accurately without weakening SHALL language.
