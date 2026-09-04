#!/usr/bin/env python3
"""Build the ENHANCED replacement pack for the SkyNET Godot port.

Downloads CC0 models from Poly Haven (https://polyhaven.com, license
CC0 1.0 — free for any use, no attribution required; we credit anyway)
into <game>/converted/enhanced_pack/models/<id>/ (glTF 1k) and writes
<game>/converted/enhanced_pack/replace.cfg, the mapping the game reads in ENHANCED mode
(scripts/replacements.gd): which DOS billboard sprite (TEXTURE.<bank>
record <rec>) is drawn as which model.

    python tools/enhanced_pack.py [--game C:/games/skynet] [--res 1k]
                                  [--only Barrel_01,rock_07]

Pick models by eye from docs/enhanced_pack.md (the sprite sheet comes
from `map_dump.tscn -- --inventory=DIR`).
"""
import argparse, json, os, sys, time, urllib.request, hashlib

API = "https://api.polyhaven.com"

# sprite (bank_rec) -> (poly haven id, options)
#   fit:   "h" scale so the model's height equals the sprite's world
#          height (default), "w" use the sprite's width instead
#   scale: extra multiplier
#   yaw:   "random" (default) or a fixed angle in degrees
#   tint:  r,g,b multiplier on the albedo (fits the dusk palette)
SPRITES = {
    # barrels / drums / crates
    "T204_001": ("Barrel_01", {}),
    "T204_000": ("Barrel_01", {}),
    "T206_000": ("Barrel_02", {}),
    "T213_010": ("barrel_03", {}),
    # T204_002 is a canister with a RADIATION TREFOIL on it — a plain
    # barrel loses the marking, and radiation is a real hazard in the
    # port now, so the DOS sprite stays.
    "T201_007": ("old_military_crate", {"fit": "w"}),
    # Dead vegetation. The DOS sprites are a bare THIN tree (208_000), a
    # dead branch (215_007), dry branches on the ground (215_006,
    # 242_002), a burnt bush (242_003) and a charred stump (213_012).
    # The quiver-tree models that were here first are Aloe dichotoma —
    # fat, pale, forked limbs: "it looks like a baobab and does not fit
    # at all" (2026-09-04). Dead pine trunks and branches do.
    "T208_000": ("dead_tree_trunk_02", {}),
    "T215_007": ("dry_branches_medium_01", {}),
    "T215_006": ("dry_branches_medium_01", {"fit": "w"}),
    "T242_002": ("dry_branches_medium_01", {"fit": "w"}),
    "T242_003": ("bark_debris_01", {"fit": "w"}),
    "T213_012": ("tree_stump_01", {}),
    # rocks / rubble
    "T211_003": ("rock_09", {"fit": "w"}),
    "T211_002": ("rock_07", {}),
    "T211_005": ("sand_rocks_small_01", {"fit": "w"}),
    "T211_004": ("namaqualand_stones_01", {"fit": "w"}),
    "T211_001": ("namaqualand_boulder_02", {"fit": "w"}),
    "T211_000": ("sand_rocks_small_01", {"fit": "w"}),
    "T210_000": ("namaqualand_boulders_01", {"fit": "w"}),
    "T210_009": ("namaqualand_stones_01", {"fit": "w"}),
    "T210_002": ("moon_rock_02", {"fit": "w"}),
    "T210_013": ("rock_07", {"fit": "w"}),
    "T210_010": ("rock_09", {"fit": "w"}),
    "T210_008": ("moon_rock_03", {"fit": "w"}),
    "T210_003": ("rock_07", {"fit": "w"}),
    "T210_011": ("rock_09", {"fit": "w"}),
    "T215_011": ("namaqualand_boulder_03", {"fit": "w"}),
    # street furniture
    # T204_017/005 are hanging cables with a fitting on the end, not a
    # hydrant and not a lamp body.
    # T204_022 is a MODERN three-head floodlight mast (and its heads are
    # lit); street_lamp_01 is a Victorian gas lamp — wrong century.
    # T209_012 is a wooden utility pole with cross-arms, not a lamp.
    "T213_009": ("old_tyre", {"fit": "w"}),
    "T213_011": ("rusted_wheel_rim_01", {"fit": "w"}),
    # hanging lamps (indoor)
    "T204_007": ("caged_hanging_light", {}),
    "T204_008": ("caged_hanging_light", {}),
    "T204_010": ("caged_hanging_light", {}),
    "T204_011": ("caged_hanging_light", {}),
    "T204_018": ("hanging_industrial_lamp", {}),
    "T204_015": ("hanging_industrial_lamp", {}),
}

# placed .3D entity meshes -> model (fit to the DOS mesh's bounding box)
MESHES = {
    # The wrecked cars littering the outdoor maps. Poly Haven has no
    # burnt-out shells, but "covered_car" — a saloon under a tarpaulin —
    # is a photoscan that reads exactly right for a street full of
    # abandoned vehicles, and it beats the 60-triangle DOS mesh.
    "CARHIP1B": ("covered_car", {"fit": "w"}),
    "CARHIP1C": ("covered_car", {"fit": "w"}),
    "CARHIP2A": ("covered_car", {"fit": "w"}),
    "CARHIP2C": ("covered_car", {"fit": "w"}),
    "CARHIP3A": ("covered_car", {"fit": "w"}),
    "CARHIP3B": ("covered_car", {"fit": "w"}),
    "CARHIP3C": ("covered_car", {"fit": "w"}),
    "CARHIP4A": ("covered_car", {"fit": "w"}),
}

# --- sky ---------------------------------------------------------------
# The outdoor maps are a flat palette colour with a 57 px moon sprite in
# DOS. ENHANCED replaces both: an equirectangular panorama on the sky
# dome and a lunar photomap on a sphere (main.gd _apply_render_env /
# _make_moon_sphere). Everything here is free to redistribute.
#
#   night  Poly Haven "Rogland Clear Night" — CC0. A clear Namaqualand
#          night with the Milky Way; the same collection the terrain
#          rocks come from, and MOONLESS, so the game's own moon stays
#          the only one in the sky.
#   sunset Poly Haven "Belfast Sunset (Pure Sky)" — CC0, for the dusk
#          missions (5-8, the DOS SKY_SKY.3D dome maps).
#   moon   Solar System Scope 2k lunar colour map — CC BY 4.0, credited
#          in LICENSE.txt. Equirectangular, so longitude 0 (the near
#          side we all know) lands in the middle of the texture.
SKY_HDRIS = {
    "night": "rogland_clear_night",
    "sunset": "belfast_sunset_puresky",
}
SKY_HDRI_RES = "2k"
MOON_URL = "https://www.solarsystemscope.com/images/textures/full/2k_moon.jpg"
MOON_CREDIT = ("Solar System Scope (https://www.solarsystemscope.com/textures/), "
               "CC BY 4.0")

# DOS texture record -> Poly Haven texture. The photo texture is colour
# matched to the DOS record (mean/spread of luminance and chroma) so it
# keeps the palette of the original, then written as
# enhanced/textures/T<bank>_<rec>.webp (+ _n.webp normal map; the game also
# accepts .png/.jpg). Needs the DOS
# records as PNG (--dos DIR, from `map_dump.tscn -- --bankdump=302
# --out=DIR`). Options: rot=0|90|180|270, scale=<tile repeats>, keep=<0..1>
# (how much of the DOS colour statistics to impose, default 1.0).
TEXTURES = {
    # --- corridors / interiors (TEXTURE.383, 382, 195, 235, 435, 455) ---
    "T383_000": ("rusty_metal", {}),
    "T383_001": ("rusty_metal_02", {}),
    "T383_002": ("concrete_wall_006", {}),
    "T383_003": ("metal_plate", {}),
    "T383_005": ("concrete_wall_003", {}),
    "T383_006": ("metal_plate_02", {}),
    "T383_007": ("blue_metal_plate", {}),
    "T382_004": ("concrete_floor_02", {}),
    "T382_005": ("concrete_wall_004", {}),
    "T382_006": ("concrete_wall_004", {}),
    "T195_001": ("metal_plate_02", {}),
    "T195_006": ("concrete_wall_007", {}),
    "T195_007": ("concrete_wall_005", {}),
    "T235_002": ("metal_grate_rusty", {}),
    "T235_009": ("concrete_wall_004", {}),
    "T435_001": ("concrete_wall_001", {}),
    "T435_002": ("rusty_metal_grid", {}),
    "T455_000": ("concrete_floor_02", {}),
    # --- city buildings / rubble (462, 464, 407, 406, 493, 420, 391) ---
    "T462_002": ("medieval_blocks_05", {}),
    "T462_004": ("brick_wall_005", {}),
    "T462_005": ("concrete_wall_006", {}),
    "T462_006": ("concrete_wall_008", {}),
    "T464_001": ("concrete_moss", {}),
    "T464_002": ("mossy_rock", {}),
    "T407_001": ("brick_wall_003", {}),
    "T407_007": ("rusty_corrugated_iron", {}),
    "T406_002": ("castle_brick_07", {}),
    "T406_006": ("concrete_block_wall_02", {}),
    "T406_007": ("metal_plate", {}),
    "T493_001": ("brown_mud_dry", {}),
    "T493_002": ("rusty_metal_02", {}),
    "T420_000": ("weathered_brown_planks", {}),
    "T420_001": ("weathered_planks", {}),
    "T420_002": ("dark_wooden_planks", {}),
    "T391_000": ("damaged_plaster", {}),
    "T391_001": ("grey_plaster_02", {}),
    "T391_003": ("dark_rock", {}),
    "T391_004": ("blue_metal_plate", {}),
    "T391_006": ("wood_planks", {}),
    "T391_007": ("wood_planks_grey", {}),
    "T390_001": ("dark_wood", {}),
    # --- sewers / base (508, 457, 509) ---
    "T508_000": ("concrete_moss", {}),
    "T508_001": ("concrete_moss", {}),
    "T508_004": ("mossy_rock", {}),
    "T508_005": ("green_metal_rust", {}),
    "T508_006": ("green_metal_rust", {}),
    "T457_005": ("rusty_metal_03", {}),
    "T509_002": ("concrete_floor_01", {}),
    "T509_003": ("gravel_concrete", {}),
    "T509_004": ("mud_cracked_dry_03", {}),
    "T509_005": ("dirty_tiles", {}),
    "T509_006": ("worn_tile_floor", {}),
    "T509_012": ("dark_rock", {}),
}

# Detail layers: a photo texture laid over the DOS tiles at a higher
# frequency (UV2) — albedo normalised around mid grey so it only adds
# grain, plus its normal map for real relief. Written as
# enhanced/textures/<name>_detail.png and <name>_detail_n.png.
DETAIL = {
    "terrain": ("dry_ground_rocks", {"strength": 0.55}),
}


UA = {"User-Agent": "skynet-godot-port/1.0 (enhanced pack builder)"}


def fetch_json(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60) as r:
        return json.loads(r.read().decode("utf-8"))


def download(url, path, md5=None):
    if os.path.exists(path) and md5:
        h = hashlib.md5(open(path, "rb").read()).hexdigest()
        if h == md5:
            return False
    os.makedirs(os.path.dirname(path), exist_ok=True)
    for attempt in range(3):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=120) as r, open(path, "wb") as f:
                f.write(r.read())
            return True
        except Exception as e:  # noqa
            print("   retry", attempt + 1, url, e)
            time.sleep(2)
    raise RuntimeError("download failed: " + url)


def get_model(pid, out_root, res, authors):
    files = fetch_json(f"{API}/files/{pid}")
    g = files.get("gltf", {})
    if res not in g:
        res = sorted(g.keys())[0]
    entry = g[res]["gltf"]
    d = os.path.join(out_root, "models", pid)
    main = os.path.join(d, os.path.basename(entry["url"]))
    n = 1 if download(entry["url"], main, entry.get("md5")) else 0
    for rel, inc in entry.get("include", {}).items():
        if download(inc["url"], os.path.join(d, rel), inc.get("md5")):
            n += 1
    info = fetch_json(f"{API}/info/{pid}")
    authors[pid] = ", ".join(info.get("authors", {}).keys())
    return os.path.relpath(main, out_root).replace("\\", "/"), n


def get_sky(out_root):
    """Fetch the ENHANCED sky panoramas and the lunar photomap."""
    made = []
    for name, pid in SKY_HDRIS.items():
        try:
            files = fetch_json(f"{API}/files/{pid}")
            fam = files.get("hdri", {})
            res = SKY_HDRI_RES if SKY_HDRI_RES in fam else sorted(fam.keys())[0]
            entry = fam[res]["hdr"]
            path = os.path.join(out_root, "sky", name + ".hdr")
            download(entry["url"], path, entry.get("md5"))
            info = fetch_json(f"{API}/info/{pid}")
            SKY_AUTHORS[pid] = ", ".join(info.get("authors", {}).keys())
            made.append(f"sky/{name}.hdr  <- polyhaven {pid} ({res})")
        except Exception as e:  # noqa
            print(f"sky {name}: FAILED: {e}")
    try:
        # Not a Poly Haven asset: a plain file, and the site only serves
        # it to a browser-shaped request.
        req = urllib.request.Request(MOON_URL, headers={
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"})
        path = os.path.join(out_root, "sky", "moon.jpg")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with urllib.request.urlopen(req, timeout=120) as r, open(path, "wb") as f:
            f.write(r.read())
        made.append("sky/moon.jpg  <- " + MOON_CREDIT)
    except Exception as e:  # noqa
        print("moon: FAILED:", e)
    for m in made:
        print(" ", m)
    return made


SKY_AUTHORS = {}


def get_texture(tid, out_root, res):
    """Download the diffuse + GL normal map (jpg) of a Poly Haven texture."""
    files = fetch_json(f"{API}/files/{tid}")
    out = {}
    for key, tag in (("Diffuse", "diff"), ("nor_gl", "nor")):
        fam = files.get(key, {})
        r = res if res in fam else (sorted(fam.keys())[0] if fam else None)
        if r is None:
            continue
        entry = fam[r].get("jpg") or fam[r].get("png")
        if not entry:
            continue
        path = os.path.join(src_root, "textures", tid, os.path.basename(entry["url"]))
        download(entry["url"], path, entry.get("md5"))
        out[tag] = path
    try:
        info = fetch_json(f"{API}/info/{tid}")
        TEX_AUTHORS[tid] = ", ".join(info.get("authors", {}).keys())
    except Exception:  # noqa
        pass
    return out


TEX_AUTHORS = {}


def match_colors(photo, dos, keep=1.0):
    """Impose the DOS record's colour statistics on the photo texture.
    Works in a luma/chroma space: mean and standard deviation of Y, Cb, Cr
    are moved toward the DOS values (keep = how far)."""
    import numpy as np
    def to_ycc(a):
        r, g, b = a[..., 0], a[..., 1], a[..., 2]
        y = 0.299 * r + 0.587 * g + 0.114 * b
        return np.stack([y, (b - y) * 0.564, (r - y) * 0.713], -1)
    def from_ycc(a):
        y, cb, cr = a[..., 0], a[..., 1], a[..., 2]
        r = y + cr / 0.713
        b = y + cb / 0.564
        g = (y - 0.299 * r - 0.114 * b) / 0.587
        return np.stack([r, g, b], -1)
    ph = to_ycc(np.asarray(photo.convert("RGB"), dtype=np.float32) / 255.0)
    ds = to_ycc(np.asarray(dos.convert("RGB"), dtype=np.float32) / 255.0)
    out = ph.copy()
    for c in range(3):
        pm, ps = ph[..., c].mean(), ph[..., c].std() + 1e-6
        dm, dsd = ds[..., c].mean(), ds[..., c].std() + 1e-6
        # keep some of the photo's own spread so it does not go flat
        target_sd = dsd * keep + ps * (1.0 - keep)
        target_m = dm * keep + pm * (1.0 - keep)
        out[..., c] = (ph[..., c] - pm) / ps * target_sd + target_m
    rgb = np.clip(from_ycc(out), 0.0, 1.0)
    from PIL import Image
    return Image.fromarray((rgb * 255.0 + 0.5).astype("uint8"), "RGB")


def build_detail(out_root, res, only):
    from PIL import Image
    import numpy as np
    tdir = os.path.join(out_root, "textures")
    os.makedirs(tdir, exist_ok=True)
    for name, (tid, opt) in sorted(DETAIL.items()):
        if only and tid not in only:
            continue
        try:
            src = get_texture(tid, out_root, res)
        except Exception as e:  # noqa
            print(f"detail {name} <- {tid}: FAILED {e}")
            continue
        if "diff" not in src:
            continue
        a = np.asarray(Image.open(src["diff"]).convert("L"), dtype=np.float32) / 255.0
        k = float(opt.get("strength", 0.5))
        # High-pass around 0.5: the game multiplies albedo by 2·detail.
        a = np.clip(0.5 + (a - a.mean()) * k, 0.0, 1.0)
        Image.fromarray((a * 255.0 + 0.5).astype("uint8"), "L").convert("RGB").save(
            os.path.join(tdir, f"{name}_detail.webp"), quality=90, method=6)
        if "nor" in src:
            Image.open(src["nor"]).convert("RGB").save(os.path.join(tdir, f"{name}_detail_n.webp"), quality=95, method=6)
        print(f"detail {name} <- {tid}  ok")


def build_textures(out_root, dos_dir, res, only):
    from PIL import Image
    tdir = os.path.join(out_root, "textures")
    os.makedirs(tdir, exist_ok=True)
    n = 0
    for rec, (tid, opt) in sorted(TEXTURES.items()):
        if only and tid not in only:
            continue
        dos_png = os.path.join(dos_dir, rec + ".png")
        if not os.path.exists(dos_png):
            print(f"{rec}: no DOS reference {dos_png} — skipped")
            continue
        try:
            src = get_texture(tid, out_root, res)
        except Exception as e:  # noqa
            print(f"{rec} <- {tid}: FAILED {e}")
            continue
        if "diff" not in src:
            print(f"{rec} <- {tid}: no diffuse")
            continue
        photo = Image.open(src["diff"]).convert("RGB")
        rot = int(opt.get("rot", 0))
        if rot:
            photo = photo.rotate(rot, expand=True)
        reps = int(opt.get("scale", 1))
        if reps > 1:
            w, h = photo.size
            photo = photo.resize((w // reps, h // reps), Image.LANCZOS)
            tiled = Image.new("RGB", (w, h))
            for y in range(reps):
                for x in range(reps):
                    tiled.paste(photo, (x * (w // reps), y * (h // reps)))
            photo = tiled
        dos = Image.open(dos_png)
        graded = match_colors(photo, dos, float(opt.get("keep", 0.85)))
        graded.save(os.path.join(tdir, rec + ".webp"), quality=90, method=6)
        if "nor" in src:
            nm = Image.open(src["nor"]).convert("RGB")
            if rot:
                nm = nm.rotate(rot, expand=True)
            if reps > 1:
                w, h = nm.size
                nm = nm.resize((w // reps, h // reps), Image.LANCZOS)
                tiled = Image.new("RGB", (w, h))
                for y in range(reps):
                    for x in range(reps):
                        tiled.paste(nm, (x * (w // reps), y * (h // reps)))
                nm = tiled
            nm.save(os.path.join(tdir, rec + "_n.webp"), quality=95, method=6)
        n += 1
        print(f"{rec} <- {tid}  ok")
    print(f"{n} textures written to {tdir}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--game", default=os.path.join(os.path.dirname(__file__), "..", "..", "gamedata", ".."))
    ap.add_argument("--res", default="1k")
    ap.add_argument("--src", default="", help="build-time source cache (default <game>/assets_src)")
    ap.add_argument("--only", default="")
    ap.add_argument("--textures", action="store_true", help="build the texture replacements (needs --dos)")
    ap.add_argument("--dos", default="", help="directory with the DOS records as PNG (map_dump --bankdump)")
    ap.add_argument("--no-models", action="store_true")
    ap.add_argument("--sky", action="store_true",
                    help="fetch the night/dusk sky panoramas and the moon map")
    a = ap.parse_args()
    game = os.path.abspath(a.game)
    # What the GAME reads at run time (shipped, packed into enhanced.pck).
    out_root = os.path.join(game, "converted", "enhanced_pack")
    # Downloaded originals the colour matching works from: build-time
    # only, outside the game data so they are never shipped or cached.
    global src_root
    src_root = a.src or os.path.join(game, "assets_src")
    os.makedirs(os.path.join(out_root, "models"), exist_ok=True)
    if a.sky:
        get_sky(out_root)
        if a.no_models:
            return
    if a.textures:
        build_detail(out_root, a.res, set(x for x in a.only.split(",") if x))
        build_textures(out_root, a.dos, a.res, set(x for x in a.only.split(",") if x))
        if a.no_models:
            return
    only = set(x for x in a.only.split(",") if x)
    ids = sorted(set(v[0] for v in SPRITES.values()) | set(v[0] for v in MESHES.values()))
    paths, authors = {}, {}
    for pid in ids:
        if only and pid not in only:
            continue
        try:
            rel, n = get_model(pid, out_root, a.res, authors)
            paths[pid] = rel
            print(f"{pid:32s} {rel}  ({n} new files)")
        except Exception as e:  # noqa
            print(f"{pid:32s} FAILED: {e}")
    cfg = ["; SkyNET ENHANCED replacement pack — read by scripts/replacements.gd",
           "; key = model path relative to this file; options after '|':",
           ";   fit=h|w  scale=1.0  yaw=random|<deg>  tint=r,g,b", "",
           "[sprites]"]
    for spr, (pid, opt) in sorted(SPRITES.items()):
        if pid not in paths:
            continue
        o = " ".join(f"{k}={v}" for k, v in opt.items())
        cfg.append(f'{spr}="{paths[pid]}{("|" + o) if o else ""}"')
    cfg += ["", "[meshes]"]
    for nm, (pid, opt) in sorted(MESHES.items()):
        if pid not in paths:
            continue
        o = " ".join(f"{k}={v}" for k, v in opt.items())
        cfg.append(f'{nm}="{paths[pid]}{("|" + o) if o else ""}"')
    with open(os.path.join(out_root, "replace.cfg"), "w", encoding="utf-8") as f:
        f.write("\n".join(cfg) + "\n")
    lic = ["SkyNET ENHANCED pack — third-party assets", "",
           "All models below come from Poly Haven (https://polyhaven.com) and are",
           "released under CC0 1.0 Universal (public domain): free to use, modify",
           "and redistribute for any purpose. Credits (not required, given anyway):", ""]
    for pid in sorted(authors):
        lic.append(f"  {pid}: {authors[pid]}  https://polyhaven.com/a/{pid}")
    for tid in sorted(TEX_AUTHORS):
        lic.append(f"  {tid} (texture): {TEX_AUTHORS[tid]}  https://polyhaven.com/a/{tid}")
    for pid in sorted(SKY_AUTHORS):
        lic.append(f"  {pid} (sky): {SKY_AUTHORS[pid]}  https://polyhaven.com/a/{pid}")
    if os.path.exists(os.path.join(out_root, "sky", "moon.jpg")):
        lic += ["", "The lunar colour map sky/moon.jpg is NOT CC0 — it is",
                "  " + MOON_CREDIT,
                "which requires attribution. Keep this file with the pack."]
    with open(os.path.join(out_root, "LICENSE.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(lic) + "\n")
    print("wrote", os.path.join(out_root, "replace.cfg"), "and LICENSE.txt")


if __name__ == "__main__":
    main()
