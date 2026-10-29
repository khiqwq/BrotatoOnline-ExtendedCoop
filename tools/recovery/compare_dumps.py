"""Compare validation dumps of original bytecode and recovered sources.

Inputs are the JSON files written by validation/dump_scripts.gd and the two engine
logs. Error lines are compared per script and message only: bytecode and text
parsing report neighbouring line numbers for the same statement.

Usage: python -I compare_dumps.py <orig.json> <recovered.json> <orig.log> <recovered.log> <report.json>
"""
import collections
import json
import re
import sys

ERR_RE = re.compile(r"SCRIPT ERROR: (.*?)\s*\n\s*at: \S+ \((res://[^:)]+?)(?:\.gdc|\.gd)?:\d+\)")


def errors(log_path):
    text = open(log_path, encoding="utf-8", errors="replace").read()
    c = collections.Counter()
    for msg, path in ERR_RE.findall(text):
        c[(path + ".gd", msg)] += 1
    return c


def main():
    orig = json.load(open(sys.argv[1], encoding="utf-8"))
    rec = json.load(open(sys.argv[2], encoding="utf-8"))
    eo, er = errors(sys.argv[3]), errors(sys.argv[4])
    report = {"scripts": len(orig), "structure_mismatch": {}, "load_mismatch": [],
              "errors_only_recovered": [], "errors_only_original": []}
    for path, o in sorted(orig.items()):
        r = rec.get(path)
        if r is None or o.get("loaded") != r.get("loaded") or o.get("valid") != r.get("valid"):
            report["load_mismatch"].append({"path": path, "orig": o.get("valid"), "recovered": None if r is None else r.get("valid")})
            continue
        diff = {}
        for key in ("methods", "props", "signals"):
            if o.get(key) != r.get(key):
                diff[key] = {"orig_only": sorted(set(o.get(key, [])) - set(r.get(key, []))),
                             "recovered_only": sorted(set(r.get(key, [])) - set(o.get(key, [])))}
        oc, rc = o.get("consts", {}), r.get("consts", {})
        cdiff = {k: [oc.get(k), rc.get(k)] for k in set(oc) | set(rc) if oc.get(k) != rc.get(k)}
        if cdiff:
            diff["consts"] = cdiff
        if diff:
            report["structure_mismatch"][path] = diff
    for k in sorted(set(eo) | set(er)):
        if er[k] > eo[k]:
            report["errors_only_recovered"].append({"path": k[0], "message": k[1], "count": er[k] - eo[k]})
        elif eo[k] > er[k]:
            report["errors_only_original"].append({"path": k[0], "message": k[1], "count": eo[k] - er[k]})
    report["summary"] = {
        "scripts": len(orig),
        "valid_original": sum(1 for v in orig.values() if v.get("valid")),
        "valid_recovered": sum(1 for v in rec.values() if v.get("valid")),
        "load_mismatch": len(report["load_mismatch"]),
        "structure_mismatch": len(report["structure_mismatch"]),
        "errors_only_recovered": len(report["errors_only_recovered"]),
        "errors_only_original": len(report["errors_only_original"]),
    }
    json.dump(report, open(sys.argv[5], "w", encoding="utf-8"), indent=1, ensure_ascii=False)
    print(json.dumps(report["summary"]))
    return 0 if not (report["load_mismatch"] or report["structure_mismatch"] or report["errors_only_recovered"]) else 1


if __name__ == "__main__":
    sys.exit(main())
