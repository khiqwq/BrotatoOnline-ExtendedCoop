"""Detokenize Godot 3.x GDScript binary token files (.gdc, bytecode version 13).

Local-only recovery helper for auditing the target game build (AP-004). Token and
built-in function tables are read from the target engine binary by
pe_string_tables.py, so the mapping follows the exact build instead of a guess.
Output keeps the original line numbers where the token line table allows it.

Usage: python -I gdc_detokenize.py <tables.json> <src_root> <dst_root>
"""
import json
import os
import struct
import sys

TOKEN_BYTE_MASK = 0x80
TOKEN_BITS = 8
TOKEN_MASK = (1 << TOKEN_BITS) - 1
TOKEN_LINE_BITS = 24
TOKEN_LINE_MASK = (1 << TOKEN_LINE_BITS) - 1
ENCODE_FLAG_64 = 1 << 16

VARIANT_TYPES = [
    "null", "bool", "int", "float", "String", "Vector2", "Rect2", "Vector3",
    "Transform2D", "Plane", "Quat", "AABB", "Basis", "Transform", "Color",
    "NodePath", "RID", "Object", "Dictionary", "Array", "PoolByteArray",
    "PoolIntArray", "PoolRealArray", "PoolStringArray", "PoolVector2Array",
    "PoolVector3Array", "PoolColorArray",
]
# token_names[] in the binary is display text. In the rpc keyword block the
# display order differs from the Token enum, so that block is rebuilt by enum.
RPC_BLOCK = ["remote", "sync", "master", "slave", "puppet", "remotesync", "mastersync", "puppetsync"]


class Tables:
    def __init__(self, path):
        data = json.load(open(path, encoding="utf-8"))
        names = data["token_names"]
        self.funcs = data["builtin_funcs"]
        self.text = [n[1:-1] if len(n) >= 2 and n[0] == "'" and n[-1] == "'" else n for n in names]
        bp = names.index("breakpoint")
        for k, kw in enumerate(RPC_BLOCK):
            self.text[bp + 1 + k] = kw
        # Display-only spellings that are not valid source text.
        self.text[names.index("In")] = "in"
        t = {n: i for i, n in enumerate(names)}
        self.IDENT = t["Identifier"]
        self.CONST = t["Constant"]
        self.SELF = t["Self"]
        self.BTYPE = t["Built-In Type"]
        self.BFUNC = t["Built-In Func"]
        self.NEWLINE = t["'\\n'"]
        self.EOF = t["EOF"]
        self.DOLLAR = t["'$'"]
        self.DIV = t["'/'"]
        self.PERIOD = t["'.'"]
        self.COMMA = t["','"]
        self.COLON = t["':'"]
        self.SEMI = t["';'"]
        self.PO = t["'('"]
        self.PC = t["')'"]
        self.BO = t["'['"]
        self.BC = t["']'"]
        self.CO = t["'{'"]
        self.CC = t["'}'"]
        self.SUB = t["'-'"]
        self.ADD = t["'+'"]
        self.INV = t["'~'"]
        self.ASSIGN = t["'='"]
        self.value_end = {self.IDENT, self.CONST, self.SELF, self.BTYPE, self.PC, self.BC, self.CC,
                          t["PI"], t["TAU"], t["INF"], t["NAN"], t["_"]}
        self.callable_kw = {t["preload"], t["assert"], t["yield"], t["export"]}
        self.literal_like = set(range(t["if"], bp + 1 + len(RPC_BLOCK))) | {
            self.IDENT, self.BTYPE, self.BFUNC, self.SELF, t["PI"], t["TAU"], t["INF"], t["NAN"], t["_"]}


def decode_variant(buf, off):
    (head,) = struct.unpack_from("<I", buf, off)
    typ = head & 0xFFFF
    flag64 = bool(head & ENCODE_FLAG_64)
    p = off + 4
    if typ == 0:
        return None, p
    if typ == 1:
        (v,) = struct.unpack_from("<I", buf, p)
        return bool(v), p + 4
    if typ == 2:
        if flag64:
            (v,) = struct.unpack_from("<q", buf, p)
            return v, p + 8
        (v,) = struct.unpack_from("<i", buf, p)
        return v, p + 4
    if typ == 3:
        if flag64:
            (v,) = struct.unpack_from("<d", buf, p)
            return float(v), p + 8
        (v,) = struct.unpack_from("<f", buf, p)
        return float(v), p + 4
    if typ == 4:
        (ln,) = struct.unpack_from("<I", buf, p)
        p += 4
        s = buf[p:p + ln].decode("utf-8")
        p += ln + (4 - ln % 4) % 4
        return s, p
    raise ValueError("unsupported constant variant type %d" % typ)


def fmt_float(v):
    if v != v:
        return "NAN"
    if v in (float("inf"), float("-inf")):
        return "INF" if v > 0 else "-INF"
    r = repr(v)
    if "e" in r:
        mant, exp = r.split("e")
        if "." not in mant:
            mant += ".0"
        return mant + "e" + exp
    return r if "." in r else r + ".0"


def fmt_string(s):
    out = ['"']
    for ch in s:
        o = ord(ch)
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\t":
            out.append("\\t")
        elif ch == "\r":
            out.append("\\r")
        elif o < 0x20 or o == 0x7F:
            out.append("\\u%04x" % o)
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def fmt_const(v):
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return fmt_float(v)
    if isinstance(v, str):
        return fmt_string(v)
    raise ValueError(repr(v))


def parse(buf):
    if buf[:4] != b"GDSC":
        raise ValueError("not a GDSC file")
    version, n_ident, n_const, n_line, n_tok = struct.unpack_from("<5I", buf, 4)
    if version != 13:
        raise ValueError("unsupported bytecode version %d" % version)
    p = 24
    idents = []
    for _ in range(n_ident):
        (ln,) = struct.unpack_from("<I", buf, p)
        p += 4
        raw = bytes(b ^ 0xB6 for b in buf[p:p + ln])
        p += ln
        idents.append(raw.split(b"\0", 1)[0].decode("utf-8"))
    consts = []
    for _ in range(n_const):
        v, p = decode_variant(buf, p)
        consts.append(v)
    lines = {}
    for _ in range(n_line):
        tok, linecol = struct.unpack_from("<II", buf, p)
        p += 8
        lines[tok] = linecol & TOKEN_LINE_MASK
    toks = []
    for _ in range(n_tok):
        if buf[p] & TOKEN_BYTE_MASK:
            (v,) = struct.unpack_from("<I", buf, p)
            toks.append(v & ~TOKEN_BYTE_MASK)
            p += 4
        else:
            toks.append(buf[p])
            p += 1
    return idents, consts, lines, toks


def render(T, idents, consts, lines, toks):
    out = []
    cur_line = 1
    indent = 0
    depth = 0
    at_line_start = True
    prev = None
    prev_unary = False

    def text_of(tok):
        typ = tok & TOKEN_MASK
        arg = tok >> TOKEN_BITS
        if typ == T.IDENT:
            return idents[arg]
        if typ == T.CONST:
            return fmt_const(consts[arg])
        if typ == T.BTYPE:
            return VARIANT_TYPES[arg]
        if typ == T.BFUNC:
            return T.funcs[arg]
        if typ == T.SELF:
            return "self"
        return T.text[typ]

    i = 0
    n = len(toks)
    while i < n:
        tok = toks[i]
        typ = tok & TOKEN_MASK
        if typ == T.EOF:
            break
        if typ == T.NEWLINE:
            indent = tok >> TOKEN_BITS
            out.append("\n")
            cur_line += 1
            at_line_start = True
            prev = typ
            i += 1
            continue
        tline = lines.get(i)
        if tline is not None and tline > cur_line:
            if at_line_start:
                out.append("\n" * (tline - cur_line))
            elif depth > 0:
                out.append("\n" * (tline - cur_line) + "\t" * (indent + 1))
                prev = None
            else:
                out.append(" \\" + "\n" * (tline - cur_line) + "\t" * (indent + 1))
                prev = None
            cur_line = tline
        if at_line_start:
            out.append("\t" * indent)
            at_line_start = False
            prev = None
        if typ == T.DOLLAR:
            # Node path: identifiers/strings joined by '/', exactly as the parser reads it.
            if prev is not None and prev not in (T.PO, T.BO, T.CO, T.PERIOD):
                out.append(" ")
            out.append("$")
            i += 1
            need_ident = True
            while i < n:
                t2 = toks[i] & TOKEN_MASK
                if t2 == T.CONST and need_ident:
                    out.append(fmt_const(consts[toks[i] >> TOKEN_BITS]))
                    need_ident = False
                elif t2 == T.DIV and not need_ident:
                    out.append("/")
                    need_ident = True
                elif need_ident and t2 in T.literal_like:
                    out.append(text_of(toks[i]))
                    need_ident = False
                else:
                    break
                i += 1
            prev = T.IDENT
            prev_unary = False
            continue
        unary = typ in (T.SUB, T.ADD) and (prev is None or prev not in T.value_end)
        space = True
        if prev is None:
            space = False
        elif typ in (T.COMMA, T.PC, T.BC, T.SEMI, T.COLON):
            space = False
        elif typ == T.PERIOD or prev == T.PERIOD:
            space = False
        elif typ == T.PO and (prev in (T.IDENT, T.BFUNC, T.BTYPE, T.PC, T.BC, T.SELF) or prev in T.callable_kw):
            space = False
        elif typ == T.BO and prev in (T.IDENT, T.PC, T.BC, T.CONST, T.SELF, T.BTYPE):
            space = False
        elif prev in (T.PO, T.BO, T.CO):
            space = False
        elif prev in (T.SUB, T.ADD) and prev_unary:
            space = False
        elif prev == T.INV:
            space = False
        elif prev == T.COLON and typ == T.ASSIGN:
            space = False
        if space:
            out.append(" ")
        out.append(text_of(tok))
        if typ in (T.PO, T.BO, T.CO):
            depth += 1
        elif typ in (T.PC, T.BC, T.CC):
            depth = max(0, depth - 1)
        prev_unary = unary
        prev = typ
        i += 1
    text = "".join(out)
    return "\n".join(l.rstrip() for l in text.split("\n")).rstrip() + "\n"


def main():
    tables, src, dst = sys.argv[1], sys.argv[2], sys.argv[3]
    T = Tables(tables)
    ok = fail = 0
    for root, _dirs, files in os.walk(src):
        for f in sorted(files):
            if not f.endswith(".gdc"):
                continue
            sp = os.path.join(root, f)
            rel = os.path.relpath(sp, src)
            dp = os.path.join(dst, rel[:-4] + ".gd")
            os.makedirs(os.path.dirname(dp), exist_ok=True)
            try:
                code = render(T, *parse(open(sp, "rb").read()))
                with open(dp, "w", encoding="utf-8", newline="\n") as o:
                    o.write(code)
                ok += 1
            except Exception as e:
                fail += 1
                print("FAIL", rel, e)
    print("detokenized", ok, "failed", fail)
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
