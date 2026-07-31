# Verification-plan template

Use this structure as a starting point. Adapt sections to the DUT; do not retain
placeholders or irrelevant method types.

```markdown
# <Block Name> — Verification Plan

**DUT:** `src/<area>/<block>.v` (include mirrors only when they exist)

**Scope:** <behaviors, interfaces, and boundaries covered>

**Inputs reviewed:** <exact specifications, traceability sections, risks,
design notes, formal files, tests, and current RTL>

This is the block-level closure tracker for `<block>`. <Relationship to system
plans or adjacent block plans.>

---

## 1. Current methodology, and the path to constrained random

**Today:** <evidence-backed summary of verified behavior and open gaps>.

- **<Method>** — <what it instantiates, scenarios, checking method, limits>.
- **<Method>** — <formal/differential/legacy/signoff evidence and limits>.
- **Coverage gap** — <code coverage, functional coverage, randomization status>.

The active order is:

1. <Resolve contract/spec issues.>
2. <Close crisp directed gaps.>
3. <Instrument baseline coverage.>
4. <Add functional coverage and constrained random.>
5. <Close formal/signoff evidence.>

### 1a. Coverage model

At minimum, collect:

- <state transitions>;
- <configuration and boundary values>;
- <event/state or protocol crosses>;
- <error/sticky/pulse paths>;
- <timing/clock/reset phase axes>.

---

## 2. List of tests

`Type`: **SPEC-SIM** = directed numbered-requirement test;
**EDGE-SIM** = robustness/precedence test from RTL review;
**FORMAL** = property proof; add only relevant method types.

| # | Test | Type | Testbench | Spec / gap | Status |
|---|---|---|---|---|---|
| 1 | <atomic behavior and pass criterion> | SPEC-SIM | `<existing or new test>` | <requirement> | <evidence-backed status> |

### 2a. Directed closure order

1. <Concrete implementation/test sequence with dependencies.>

---

## 3. Regression commands

<Exact environment assumptions and runnable commands. Include special required
arguments and formal invocations.>

---

## 4. Explicit non-goals and interface boundaries

- <Behavior owned by another block or method.>
- <Unsupported/illegal environment assumptions.>
- <Physical or firmware behavior not proven by RTL simulation.>
```

## Test-row quality checklist

Each row should answer:

1. What exact stimulus or condition is applied?
2. What observable result makes it pass?
3. Is it requirement-driven, an RTL-review edge case, formal, analysis, or an
   integration boundary?
4. What current artifact supplies the evidence?
5. Is the status honest about missing axes or stale results?

Split broad rows when different behaviors have different evidence or owners.
Combine closely related cases only when one test and scoreboard naturally close
them together.
