"""Add every upstream method our extensions override to tests/fixtures/upstream_contract.json.

For each extension under mods-unpacked/<mod>/extensions/, the parent chain is
resolved the way it exists in game: a vanilla path is first extended by Brotato
Online's extension for that path (if any), then the vanilla script. Each function
the extension declares that also exists upstream is recorded with the upstream
parameter count. Existing entries are kept; only missing ones are added.

Run only while (re)auditing a locked upstream version: the fixture is the frozen
baseline that tests/integration/test_upstream_contract.gd checks against.

Usage: python -I gen_contract.py <repo root> <recovered game src> <brotato online dir>
"""
import json
import os
import re
import sys

EXTENDS_RE = re.compile(r'^extends\s+"(res://[^"]+)"', re.M)
FUNC_RE = re.compile(r"^(?:static\s+)?func\s+(\w+)\s*\(([^)]*)\)", re.M)
BO_ID = "six666-BrotatoOnline"


def param_count(params):
    params = params.strip()
    if not params:
        return 0
    depth, count = 0, 1
    for c in params:
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == "," and depth == 0:
            count += 1
    return count


def functions(path):
    text = open(path, encoding="utf-8").read()
    return {m.group(1): param_count(m.group(2)) for m in FUNC_RE.finditer(text)}


def res_to_file(res, game_src, bo_dir):
    rel = res[len("res://"):]
    prefix = "mods-unpacked/%s/" % BO_ID
    if rel.startswith(prefix):
        return os.path.join(bo_dir, *rel[len(prefix):].split("/"))
    return os.path.join(game_src, *rel.split("/"))


def bo_extensions(bo_dir):
    """vanilla res:// path -> list of BO extension res:// paths (BO installs them in mod_main._init)."""
    out = {}
    ext_dir = os.path.join(bo_dir, "extensions")
    for name in sorted(os.listdir(ext_dir)):
        if not name.endswith(".gd"):
            continue
        m = EXTENDS_RE.search(open(os.path.join(ext_dir, name), encoding="utf-8").read())
        if m:
            out.setdefault(m.group(1), []).append("res://mods-unpacked/%s/extensions/%s" % (BO_ID, name))
    return out


def main():
    repo, game_src, bo_dir = sys.argv[1], sys.argv[2], sys.argv[3]
    fixture_path = os.path.join(repo, "tests", "fixtures", "upstream_contract.json")
    fixture = json.load(open(fixture_path, encoding="utf-8"))
    scripts = fixture.setdefault("scripts", {})
    bo_ext = bo_extensions(bo_dir)
    lock = json.load(open(os.path.join(repo, "project.lock.json"), encoding="utf-8"))
    ext_root = os.path.join(repo, "mods-unpacked", lock["extension"]["id"], "extensions")
    added = 0
    for dirpath, _dirs, files in os.walk(ext_root):
        for name in sorted(files):
            if not name.endswith(".gd"):
                continue
            ours = os.path.join(dirpath, name)
            m = EXTENDS_RE.search(open(ours, encoding="utf-8").read())
            if not m:
                continue
            target = m.group(1)
            chain = list(reversed(bo_ext.get(target, []))) + [target]
            parents = [(res, functions(res_to_file(res, game_src, bo_dir))) for res in chain
                       if os.path.exists(res_to_file(res, game_src, bo_dir))]
            for func in functions(ours):
                for res, funcs in parents:
                    if func in funcs:
                        entry = scripts.setdefault(res, {"methods": {}, "constants": {}})
                        if func not in entry["methods"]:
                            entry["methods"][func] = funcs[func]
                            added += 1
                        break
    with open(fixture_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(json.dumps(fixture, ensure_ascii=False, indent=2) + "\n")
    print("contract entries added:", added)


if __name__ == "__main__":
    main()
