"""Read selected settings from a Godot 3.x project.binary and emit a validation project.godot.

Only autoload names and the global class registry are carried over. Autoloads point
at stubs so recovered scripts can be compiled without running any game singleton
code. With <recovered root>, each autoload gets its own stub carrying the real
script's top-level enums and literal constants (needed by upstream const
expressions such as CoopService.PlayerType.GAMEPAD_XBOX); otherwise one empty stub.

Usage: python -I project_binary.py <project.binary> <out project.godot> <out settings.json> [recovered root]
"""
import json
import os
import re
import struct
import sys

ENCODE_FLAG_64 = 1 << 16
STUB = "res://__validation__/autoload_stub.gd"

CONST_RE = re.compile(r"^const\s+(\w+)\s*(:\s*\w+)?\s*:?=\s*(.+?)\s*$")
STRING_RE = re.compile(r'"(?:[^"\\]|\\.)*"')
EXT_SCRIPT_RE = re.compile(r'\[ext_resource path="res://([^"]+)" type="Script" id=(\d+)\]')
ROOT_NODE_RE = re.compile(r'\[node name="[^"]+"(?![^\]]*parent=)[^\]]*\](.*?)(?:\n\[|\Z)', re.S)
NODE_SCRIPT_RE = re.compile(r"^script = ExtResource\( (\d+) \)", re.M)
LITERAL_WORDS = {"true", "false", "null", "INF", "NAN", "PI", "TAU"}


def decode(buf, p):
    (head,) = struct.unpack_from("<I", buf, p)
    typ = head & 0xFFFF
    f64 = bool(head & ENCODE_FLAG_64)
    p += 4
    if typ == 0:
        return None, p
    if typ == 1:
        return bool(struct.unpack_from("<I", buf, p)[0]), p + 4
    if typ == 2:
        if f64:
            return struct.unpack_from("<q", buf, p)[0], p + 8
        return struct.unpack_from("<i", buf, p)[0], p + 4
    if typ == 3:
        if f64:
            return struct.unpack_from("<d", buf, p)[0], p + 8
        return struct.unpack_from("<f", buf, p)[0], p + 4
    if typ == 4:
        (ln,) = struct.unpack_from("<I", buf, p)
        p += 4
        s = buf[p:p + ln].decode("utf-8")
        return s, p + ln + (4 - ln % 4) % 4
    if typ == 14:
        return {"Color": struct.unpack_from("<4f", buf, p)}, p + 16
    if typ == 5:
        return {"Vector2": struct.unpack_from("<2f", buf, p)}, p + 8
    if typ == 17:
        # Encoded object; only null objects are expected in settings.
        (cls_len,) = struct.unpack_from("<I", buf, p)
        if cls_len == 0:
            return None, p + 4
        raise ValueError("object values are not supported")
    if typ == 18:
        (cnt,) = struct.unpack_from("<I", buf, p)
        p += 4
        d = {}
        for _ in range(cnt & 0x7FFFFFFF):
            k, p = decode(buf, p)
            v, p = decode(buf, p)
            d[json.dumps(k) if not isinstance(k, str) else k] = v
        return d, p
    if typ == 19:
        (cnt,) = struct.unpack_from("<I", buf, p)
        p += 4
        a = []
        for _ in range(cnt & 0x7FFFFFFF):
            v, p = decode(buf, p)
            a.append(v)
        return a, p
    if typ == 23:
        (cnt,) = struct.unpack_from("<I", buf, p)
        p += 4
        a = []
        for _ in range(cnt):
            (ln,) = struct.unpack_from("<I", buf, p)
            p += 4
            a.append(buf[p:p + ln].decode("utf-8").rstrip("\0"))
            p += ln + (4 - ln % 4) % 4
        return a, p
    raise ValueError("unsupported variant type %d" % typ)


def read_settings(path):
    buf = open(path, "rb").read()
    if buf[:4] != b"ECFG":
        raise ValueError("not a project.binary")
    (count,) = struct.unpack_from("<I", buf, 4)
    p = 8
    out = {}
    for _ in range(count):
        (klen,) = struct.unpack_from("<I", buf, p)
        p += 4
        key = buf[p:p + klen].decode("utf-8")
        p += klen
        (vlen,) = struct.unpack_from("<I", buf, p)
        p += 4
        chunk = buf[p:p + vlen]
        p += vlen
        if key.startswith("autoload/") or key in ("_global_script_classes", "_global_script_class_icons",
                                                    "application/config/name", "application/run/main_scene"):
            out[key], _ = decode(chunk, 0)
    return out


def gd_string(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _is_literal(rhs):
    bare = STRING_RE.sub('""', rhs)
    if re.search(r"[()$]", bare):
        return False
    words = {w for w in re.findall(r"[A-Za-z_]\w*", bare) if not re.fullmatch(r"e\d*", w)}
    return words <= LITERAL_WORDS and bare.count("[") == bare.count("]") and bare.count("{") == bare.count("}")


def _script_of_autoload(root, res_path):
    rel = res_path[len("res://"):]
    if rel.endswith(".gd"):
        return rel
    if not rel.endswith(".tscn"):
        return None
    text = open(os.path.join(root, *rel.split("/")), encoding="utf-8", errors="replace").read()
    ext = {rid: pth for pth, rid in EXT_SCRIPT_RE.findall(text)}
    m = ROOT_NODE_RE.search(text)
    if not m:
        return None
    sm = NODE_SCRIPT_RE.search(m.group(1))
    return ext.get(sm.group(1)) if sm else None


def make_stub(root, name, res_path, stub_dir):
    rel = _script_of_autoload(root, res_path)
    if not rel:
        return None
    path = os.path.join(root, *rel.split("/"))
    if not os.path.exists(path):
        return None
    lines = open(path, encoding="utf-8").read().split("\n")
    out = ["extends Node", "# Validation stub for autoload %s (%s): top-level enums and literal consts only." % (name, rel)]
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.startswith("enum "):
            block = [line]
            depth = line.count("{") - line.count("}")
            while depth > 0 and i + 1 < len(lines):
                i += 1
                block.append(lines[i])
                depth += lines[i].count("{") - lines[i].count("}")
            out.extend(block)
        else:
            m = CONST_RE.match(line)
            if m and _is_literal(m.group(3)):
                out.append(line)
        i += 1
    os.makedirs(stub_dir, exist_ok=True)
    with open(os.path.join(stub_dir, name + ".gd"), "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(out) + "\n")
    return "res://__validation__/stubs/%s.gd" % name


def main():
    src, out_proj, out_json = sys.argv[1], sys.argv[2], sys.argv[3]
    root = sys.argv[4] if len(sys.argv) > 4 else None
    settings = read_settings(src)
    json.dump(settings, open(out_json, "w", encoding="utf-8"), indent=1, ensure_ascii=False)
    classes = settings.get("_global_script_classes", [])
    lines = ["config_version=4", ""]
    lines.append("_global_script_classes=[ " + ", ".join(
        "{\n\"base\": %s,\n\"class\": %s,\n\"language\": %s,\n\"path\": %s\n}" % (
            gd_string(c["base"]), gd_string(c["class"]), gd_string(c["language"]), gd_string(c["path"]))
        for c in classes) + " ]")
    lines.append("_global_script_class_icons={\n" + ",\n".join(
        "%s: \"\"" % gd_string(c["class"]) for c in classes) + "\n}")
    lines += ["", "[application]", "", 'config/name="recovered-validation"', "", "[autoload]", ""]
    stubs = 0
    # Keep the original autoload order: it is the instancing order.
    for k in settings:
        if k.startswith("autoload/"):
            name = k[len("autoload/"):]
            stub = None
            if root:
                stub = make_stub(root, name, str(settings[k]).lstrip("*"), os.path.join(root, "__validation__", "stubs"))
            stubs += 1 if stub else 0
            lines.append('%s="*%s"' % (name, stub or STUB))
    lines.append("")
    open(out_proj, "w", encoding="utf-8", newline="\n").write("\n".join(lines))
    print("autoloads", sum(1 for k in settings if k.startswith("autoload/")), "classes", len(classes), "typed stubs", stubs)


if __name__ == "__main__":
    main()
