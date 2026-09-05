#!/usr/bin/env python3
"""Validate machine-readable evidence emitted by ol_trouper_top/mcp_audit.tcl."""
import argparse
import json
import pathlib
import sys


def load_json(path):
    with open(path, encoding="utf-8") as stream:
        return json.load(stream)


def parse_evidence(path):
    result = {"stage": None, "groups": {}}
    with open(path, encoding="utf-8") as stream:
        for raw in stream:
            fields = raw.rstrip("\n").split("|")
            if fields[:2] == ["MCP_AUDIT", "stage"] and len(fields) == 3:
                result["stage"] = fields[2]
            elif fields[:1] == ["MCP_GROUP"] and len(fields) == 6:
                group = result["groups"].setdefault(fields[1], {"objects": {"through": [], "endpoint": []}})
                group.update(setup=int(fields[2]), hold=int(fields[3]), through=int(fields[4]), endpoint=int(fields[5]))
            elif fields[:1] == ["MCP_OBJECT"] and len(fields) == 4:
                result["groups"].setdefault(fields[1], {"objects": {"through": [], "endpoint": []}})["objects"][fields[2]].append(fields[3])
            elif fields[:1] == ["MCP_ARC_REPORT"] and len(fields) == 3:
                result["groups"].setdefault(fields[1], {"objects": {"through": [], "endpoint": []}}).setdefault("arc_reports", set()).add(fields[2])
    return result


def signature(evidence):
    return {name: {"setup": group["setup"], "hold": group["hold"],
                   "through": sorted(group["objects"]["through"]),
                   "endpoint": sorted(group["objects"]["endpoint"])}
            for name, group in sorted(evidence["groups"].items())}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--evidence", required=True)
    parser.add_argument("--log", action="append", default=[])
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--update-baseline", action="store_true")
    args = parser.parse_args()

    manifest = load_json(args.manifest)
    evidence = parse_evidence(args.evidence)
    failures = []
    expected = manifest["groups"]
    if not evidence["stage"]:
        failures.append("evidence has no stage header")
    if set(expected) != set(evidence["groups"]):
        failures.append("MCP group set differs: expected %s, got %s" %
                        (sorted(expected), sorted(evidence["groups"])))
    for name, contract in expected.items():
        group = evidence["groups"].get(name)
        if not group:
            continue
        for key in ("setup", "hold"):
            if group[key] != contract[key]:
                failures.append(f"{name}: {key}={group[key]}, expected {contract[key]}")
        for key, count_key in (("through", "min_through"), ("endpoint", "min_endpoint")):
            if group[key] < contract[count_key]:
                failures.append(f"{name}: {key} collection has {group[key]}, minimum is {contract[count_key]}")
        for kind in ("through", "endpoint"):
            if len(group["objects"][kind]) != group[kind]:
                failures.append(f"{name}: {kind} object list/count mismatch")
        if group.get("arc_reports", set()) != {"max", "min"}:
            failures.append(f"{name}: missing max/min resolved timing-path report")
    for log in args.log:
        text = pathlib.Path(log).read_text(encoding="utf-8", errors="replace")
        for needle in ("STA-0361", "STA-0472", "no valid objects"):
            if needle in text:
                failures.append(f"{log}: contains {needle}")
        # `mcp_audit.tcl` emits the marker into both the evidence file and
        # OpenROAD log immediately before each JSON report_checks result.
        # A marker alone only proves the command was attempted; require at
        # least one resolved startpoint/endpoint path before accepting an MCP
        # group as non-vacuous timing-path evidence.
        markers = []
        for raw in text.splitlines():
            if raw.startswith("MCP_ARC_REPORT|"):
                fields = raw.split("|")
                if len(fields) == 3:
                    markers.append((fields[1], fields[2]))
        for name in expected:
            for phase in ("max", "min"):
                try:
                    start = markers.index((name, phase))
                except ValueError:
                    failures.append(f"{log}: {name} lacks {phase} timing-path report")
                    continue
                marker = f"MCP_ARC_REPORT|{name}|{phase}"
                begin = text.find(marker)
                following = [text.find(f"MCP_ARC_REPORT|{n}|{p}", begin + len(marker))
                             for n, p in markers]
                following = [offset for offset in following if offset >= 0]
                section = text[begin:min(following) if following else len(text)]
                if '"startpoint"' not in section or '"endpoint"' not in section:
                    failures.append(f"{log}: {name} {phase} report contains no resolved path")

    baseline_path = pathlib.Path(args.baseline)
    baseline = load_json(baseline_path)
    stage = evidence["stage"]
    new_signature = signature(evidence)
    if args.update_baseline:
        if failures:
            print("MCP audit failed; refusing baseline update:", *failures, sep="\n  ", file=sys.stderr)
            return 1
        baseline.setdefault("stages", {})[stage] = new_signature
        baseline_path.write_text(json.dumps(baseline, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(f"MCP audit baseline updated for {stage}")
        return 0
    prior = baseline.get("stages", {}).get(stage)
    if prior is None:
        failures.append(f"no approved baseline for stage '{stage}' (review then rerun --update-baseline)")
    elif prior != new_signature:
        failures.append(f"resolved MCP object set changed for stage '{stage}'; review and update baseline explicitly")
    if failures:
        print("MCP audit FAILED:", *failures, sep="\n  ", file=sys.stderr)
        return 1
    print(f"MCP audit PASS: {stage}, {len(new_signature)} groups")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
