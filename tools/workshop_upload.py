"""Upload the release package to the Steam Workshop item (see docs/runbooks/workshop-release.md).

Talks to the running, signed-in Steam client through the game's own
steam_api64.dll (ISteamUGC v021, manual callback dispatch); no credentials are
involved. The item id lives in docs/release/workshop-item-id.txt: without it a
new item is created and the id written there; with it the existing item is
updated. Each upload sets the title and description from
docs/release/workshop-description.txt, the visibility (friends only unless
--public), the content folder (only the release zip), the preview image and
the gallery (the extra screenshots: every .jpg/.png in .local/release/gallery,
in name order, replacing the item's current ones; left alone when that folder
is empty or missing), then adds Brotato Online as a required item.

Usage: python tools/workshop_upload.py --dry-run | --upload [--note "change note"] [--public]
"""
import ctypes
import json
import os
import struct
import sys
import time
from ctypes import POINTER, Structure, byref, c_bool, c_char_p, c_int, c_int32, c_uint32, c_uint64, c_void_p

APP_ID = 1942280
BROTATO_ONLINE_ID = 3741034628
VISIBILITY_PUBLIC = 0
VISIBILITY_FRIENDS_ONLY = 1
FILE_TYPE_COMMUNITY = 0
ERESULT_OK = 1
ERESULT_DUPLICATE = 29
PREVIEW_TYPE_IMAGE = 0
CB_API_CALL_COMPLETED = 703
CB_UGC_QUERY_COMPLETED = 3401
CB_CREATE_ITEM = 3403
CB_SUBMIT_ITEM_UPDATE = 3404
CB_ADD_DEPENDENCY = 3412
ZIP_NAME = "CoopPlus-OnlineExtendedCoop.zip"

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RELEASE = os.path.join(REPO, ".local", "release")
CONTENT_DIR = os.path.join(RELEASE, "workshop_content")
PREVIEW = os.path.join(RELEASE, "preview.jpg")
GALLERY_DIR = os.path.join(RELEASE, "gallery")
TEXT_FILE = os.path.join(REPO, "docs", "release", "workshop-description.txt")
ID_FILE = os.path.join(REPO, "docs", "release", "workshop-item-id.txt")


class CallbackMsg(Structure):
    _fields_ = [("user", c_int32), ("callback", c_int32), ("param", c_void_p), ("cub", c_int32)]


def load_text():
    lines = open(TEXT_FILE, encoding="utf-8").read().split("\n")
    title = lines[lines.index("标题：") + 1].strip()
    start = next(i for i, line in enumerate(lines) if line.startswith("说明")) + 1
    description = "\n".join(lines[start:]).strip()
    if not title or not description.startswith("[h1]"):
        raise SystemExit("unexpected layout in " + TEXT_FILE)
    return title, description


def steam_dll():
    config = json.load(open(os.path.join(REPO, ".local", "config.json"), encoding="utf-8"))
    return os.path.join(config["game_path"], "steam_api64.dll")


SIGNATURES = {
    "SteamAPI_InitFlat": ([c_char_p], c_int),
    "SteamAPI_Shutdown": ([], None),
    "SteamAPI_GetHSteamPipe": ([], c_int32),
    "SteamAPI_SteamUGC_v021": ([], c_void_p),
    "SteamAPI_ManualDispatch_Init": ([], None),
    "SteamAPI_ManualDispatch_RunFrame": ([c_int32], None),
    "SteamAPI_ManualDispatch_GetNextCallback": ([c_int32, POINTER(CallbackMsg)], c_bool),
    "SteamAPI_ManualDispatch_FreeLastCallback": ([c_int32], None),
    "SteamAPI_ManualDispatch_GetAPICallResult": ([c_int32, c_uint64, c_void_p, c_int, c_int, POINTER(c_bool)], c_bool),
    "SteamAPI_ISteamUGC_CreateItem": ([c_void_p, c_uint32, c_int], c_uint64),
    "SteamAPI_ISteamUGC_StartItemUpdate": ([c_void_p, c_uint32, c_uint64], c_uint64),
    "SteamAPI_ISteamUGC_SetItemTitle": ([c_void_p, c_uint64, c_char_p], c_bool),
    "SteamAPI_ISteamUGC_SetItemDescription": ([c_void_p, c_uint64, c_char_p], c_bool),
    "SteamAPI_ISteamUGC_SetItemVisibility": ([c_void_p, c_uint64, c_int], c_bool),
    "SteamAPI_ISteamUGC_SetItemContent": ([c_void_p, c_uint64, c_char_p], c_bool),
    "SteamAPI_ISteamUGC_SetItemPreview": ([c_void_p, c_uint64, c_char_p], c_bool),
    "SteamAPI_ISteamUGC_SubmitItemUpdate": ([c_void_p, c_uint64, c_char_p], c_uint64),
    "SteamAPI_ISteamUGC_GetItemUpdateProgress": ([c_void_p, c_uint64, POINTER(c_uint64), POINTER(c_uint64)], c_int),
    "SteamAPI_ISteamUGC_AddDependency": ([c_void_p, c_uint64, c_uint64], c_uint64),
    "SteamAPI_ISteamUGC_CreateQueryUGCDetailsRequest": ([c_void_p, POINTER(c_uint64), c_uint32], c_uint64),
    "SteamAPI_ISteamUGC_SetReturnAdditionalPreviews": ([c_void_p, c_uint64, c_bool], c_bool),
    "SteamAPI_ISteamUGC_SetAllowCachedResponse": ([c_void_p, c_uint64, c_uint32], c_bool),
    "SteamAPI_ISteamUGC_SendQueryUGCRequest": ([c_void_p, c_uint64], c_uint64),
    "SteamAPI_ISteamUGC_GetQueryUGCNumAdditionalPreviews": ([c_void_p, c_uint64, c_uint32], c_uint32),
    "SteamAPI_ISteamUGC_ReleaseQueryUGCRequest": ([c_void_p, c_uint64], c_bool),
    "SteamAPI_ISteamUGC_AddItemPreviewFile": ([c_void_p, c_uint64, c_char_p, c_int], c_bool),
    "SteamAPI_ISteamUGC_UpdateItemPreviewFile": ([c_void_p, c_uint64, c_uint32, c_char_p], c_bool),
    "SteamAPI_ISteamUGC_RemoveItemPreview": ([c_void_p, c_uint64, c_uint32], c_bool),
}


class Steam:
    def __init__(self):
        # What Steam sets when it launches the game; the game folder has no steam_appid.txt.
        os.environ["SteamAppId"] = str(APP_ID)
        os.environ["SteamGameId"] = str(APP_ID)
        self.lib = ctypes.CDLL(steam_dll())
        for name, (args, res) in SIGNATURES.items():
            fn = getattr(self.lib, name)
            fn.argtypes = args
            fn.restype = res
        err = ctypes.create_string_buffer(1024)
        res = self.lib.SteamAPI_InitFlat(err)
        if res != 0:
            raise SystemExit("Steam init failed (%d): %s" % (res, err.value.decode("utf-8", "replace")))
        self.lib.SteamAPI_ManualDispatch_Init()
        self.pipe = self.lib.SteamAPI_GetHSteamPipe()
        self.ugc = self.lib.SteamAPI_SteamUGC_v021()
        if not self.ugc:
            raise SystemExit("ISteamUGC v021 not available")

    # Pumps callbacks until the API call completes; returns its result struct as bytes.
    def wait(self, call, expected, timeout, on_tick=None):
        if call == 0:
            raise SystemExit("API call not started (callback %d)" % expected)
        deadline = time.time() + timeout
        msg = CallbackMsg()
        while time.time() < deadline:
            self.lib.SteamAPI_ManualDispatch_RunFrame(self.pipe)
            while self.lib.SteamAPI_ManualDispatch_GetNextCallback(self.pipe, byref(msg)):
                result = None
                if msg.callback == CB_API_CALL_COMPLETED and msg.cub >= 16:
                    handle, cb_id, cub = struct.unpack("<QiI", ctypes.string_at(msg.param, 16))
                    if handle == call:
                        buf = ctypes.create_string_buffer(cub)
                        failed = c_bool(False)
                        ok = self.lib.SteamAPI_ManualDispatch_GetAPICallResult(self.pipe, call, buf, cub, cb_id, byref(failed))
                        result = buf.raw if cb_id == expected and ok and not failed.value else (cb_id, ok, failed.value)
                self.lib.SteamAPI_ManualDispatch_FreeLastCallback(self.pipe)
                if isinstance(result, tuple):
                    raise SystemExit("API call %d failed: %r" % (expected, result))
                if result is not None:
                    return result
            if on_tick:
                on_tick()
            time.sleep(0.1)
        raise SystemExit("timed out waiting for callback %d" % expected)

    def shutdown(self):
        self.lib.SteamAPI_Shutdown()


def legal_note(needs):
    if needs:
        print("NOTE: the Workshop legal agreement is not accepted on this account; "
              "the item stays hidden until it is accepted on the item page.")


def gallery_files():
    if not os.path.isdir(GALLERY_DIR):
        return []
    names = sorted(n for n in os.listdir(GALLERY_DIR) if n.lower().endswith((".jpg", ".jpeg", ".png")))
    return [os.path.join(GALLERY_DIR, n) for n in names]


def count_gallery(steam, item_id):
    lib, ugc = steam.lib, steam.ugc
    ids = (c_uint64 * 1)(item_id)
    query = lib.SteamAPI_ISteamUGC_CreateQueryUGCDetailsRequest(ugc, ids, 1)
    lib.SteamAPI_ISteamUGC_SetReturnAdditionalPreviews(ugc, query, True)
    lib.SteamAPI_ISteamUGC_SetAllowCachedResponse(ugc, query, 0)
    try:
        raw = steam.wait(lib.SteamAPI_ISteamUGC_SendQueryUGCRequest(ugc, query), CB_UGC_QUERY_COMPLETED, 60)
        _, eresult, returned = struct.unpack_from("<QiI", raw)
        if eresult != ERESULT_OK or returned != 1:
            raise SystemExit("item query failed: EResult %d, %d results" % (eresult, returned))
        return lib.SteamAPI_ISteamUGC_GetQueryUGCNumAdditionalPreviews(ugc, query, 0)
    finally:
        lib.SteamAPI_ISteamUGC_ReleaseQueryUGCRequest(ugc, query)


# Replaces the item's extra screenshots with `files` in the update `handle`:
# existing slots are overwritten in place, new ones added, extra ones removed.
def set_gallery(steam, handle, files, existing):
    lib, ugc = steam.lib, steam.ugc
    ok = True
    for i, path in enumerate(files):
        data = path.encode("utf-8")
        if i < existing:
            ok = lib.SteamAPI_ISteamUGC_UpdateItemPreviewFile(ugc, handle, i, data) and ok
        else:
            ok = lib.SteamAPI_ISteamUGC_AddItemPreviewFile(ugc, handle, data, PREVIEW_TYPE_IMAGE) and ok
    for i in reversed(range(len(files), existing)):
        ok = lib.SteamAPI_ISteamUGC_RemoveItemPreview(ugc, handle, i) and ok
    return ok


def upload(steam, title, description, zip_path, note, visibility):
    lib, ugc = steam.lib, steam.ugc
    os.makedirs(CONTENT_DIR, exist_ok=True)
    for name in os.listdir(CONTENT_DIR):
        os.remove(os.path.join(CONTENT_DIR, name))
    with open(zip_path, "rb") as src, open(os.path.join(CONTENT_DIR, ZIP_NAME), "wb") as dst:
        dst.write(src.read())

    if os.path.isfile(ID_FILE):
        item_id = int(open(ID_FILE).read().strip())
        print("updating item", item_id)
    else:
        raw = steam.wait(lib.SteamAPI_ISteamUGC_CreateItem(ugc, APP_ID, FILE_TYPE_COMMUNITY), CB_CREATE_ITEM, 120)
        eresult, item_id, needs = struct.unpack_from("<i4xQ?", raw)
        if eresult != ERESULT_OK:
            raise SystemExit("CreateItem failed, EResult %d" % eresult)
        with open(ID_FILE, "w", newline="\n") as f:
            f.write(str(item_id))
        print("created item", item_id)
        legal_note(needs)

    gallery = gallery_files()
    existing = count_gallery(steam, item_id) if gallery else 0
    if gallery:
        print("gallery: %d screenshots (item has %d)" % (len(gallery), existing))

    handle = lib.SteamAPI_ISteamUGC_StartItemUpdate(ugc, APP_ID, item_id)
    fields = {
        "title": lib.SteamAPI_ISteamUGC_SetItemTitle(ugc, handle, title.encode("utf-8")),
        "description": lib.SteamAPI_ISteamUGC_SetItemDescription(ugc, handle, description.encode("utf-8")),
        "visibility": lib.SteamAPI_ISteamUGC_SetItemVisibility(ugc, handle, visibility),
        "content": lib.SteamAPI_ISteamUGC_SetItemContent(ugc, handle, CONTENT_DIR.encode("utf-8")),
        "preview": lib.SteamAPI_ISteamUGC_SetItemPreview(ugc, handle, PREVIEW.encode("utf-8")),
    }
    if gallery:
        fields["gallery"] = set_gallery(steam, handle, gallery, existing)
    if not all(fields.values()):
        raise SystemExit("field rejected, nothing submitted: %r" % fields)

    last = [None]

    def tick():
        done, total = c_uint64(0), c_uint64(0)
        status = lib.SteamAPI_ISteamUGC_GetItemUpdateProgress(ugc, handle, byref(done), byref(total))
        if (status, done.value, total.value) != last[0]:
            last[0] = (status, done.value, total.value)
            print("  progress: status %d, %d/%d bytes" % last[0])

    raw = steam.wait(lib.SteamAPI_ISteamUGC_SubmitItemUpdate(ugc, handle, note.encode("utf-8")), CB_SUBMIT_ITEM_UPDATE, 900, tick)
    eresult, needs, _ = struct.unpack_from("<i?3xQ", raw)
    legal_note(needs)
    if eresult != ERESULT_OK:
        raise SystemExit("SubmitItemUpdate failed, EResult %d" % eresult)
    print("submitted")

    raw = steam.wait(lib.SteamAPI_ISteamUGC_AddDependency(ugc, item_id, BROTATO_ONLINE_ID), CB_ADD_DEPENDENCY, 120)
    eresult = struct.unpack_from("<i", raw)[0]
    print("required item Brotato Online: %s" % ("added" if eresult == ERESULT_OK else "already set" if eresult == ERESULT_DUPLICATE else "EResult %d" % eresult))
    print("https://steamcommunity.com/sharedfiles/filedetails/?id=%d" % item_id)


def main(argv):
    mode = argv[1] if len(argv) > 1 else "--dry-run"
    note = argv[argv.index("--note") + 1] if "--note" in argv else "update"
    visibility = VISIBILITY_PUBLIC if "--public" in argv else VISIBILITY_FRIENDS_ONLY
    title, description = load_text()
    zip_path = os.path.join(RELEASE, ZIP_NAME)
    for path in (zip_path, PREVIEW):
        if not os.path.isfile(path):
            raise SystemExit("missing " + path)
    print("title:", title)
    print("description %d chars, preview %d bytes, zip %d bytes, gallery %d, visibility %s" % (
        len(description), os.path.getsize(PREVIEW), os.path.getsize(zip_path), len(gallery_files()),
        "public" if visibility == VISIBILITY_PUBLIC else "friends only"))
    steam = Steam()
    print("steam: connected")
    try:
        if mode == "--upload":
            upload(steam, title, description, zip_path, note, visibility)
        else:
            print("dry run: nothing uploaded")
    finally:
        steam.shutdown()


if __name__ == "__main__":
    main(sys.argv)
