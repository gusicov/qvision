"""QVision v0.11.1: pick data for a quantity package (tap an element on the headset).

The headset only loads the light context USDZ (one mesh per layer and material). To tell which
element a tap hit, this tool writes, next to the package's other data:

  Data/pick.json  the mesh table, the element ID table, statistics
  Data/pick.bin   little-endian blocks, 4-byte aligned, per context mesh:
                    positions  float32 xyz * vertexCount   (welded, model metres, Y-up, world transforms applied)
                    indices    uint16 or uint32 * 3 * triangleCount (indexSize 2 or 4; padded to 4 bytes)
                    elements   uint32 * triangleCount      (index into elementIds, 0xFFFFFFFF = unknown)

Context triangles are mapped to elements by geometry: every triangle of the main per-element USDZ
gives its world-space centroid rounded to 1 mm (exact hash), with a fallback on the nearest
main centroid within 5 mm (numpy grid). The package's own manifest.json is never changed.

Run with Blender's Python (it ships pxr):
  blender.exe -b --factory-startup --python qv_pick.py -- <package dir> [<package dir> ...]
"""
import hashlib
import json
import os
import sys
import time

import numpy as np
from pxr import Usd, UsdGeom

UNKNOWN = 0xFFFFFFFF
EXACT_M = 0.001
NEAREST_M = 0.005
BIAS = 1 << 20          # quantised coordinates must stay in 21 bits (+-1 km at 1 mm)


def log(*parts):
    print("[qv_pick]", *parts, flush=True)


def mesh_triangles(prim):
    """World-space points (float64, N x 3) and triangle indices (T x 3) of a Mesh prim."""
    mesh = UsdGeom.Mesh(prim)
    points = mesh.GetPointsAttr().Get()
    counts = mesh.GetFaceVertexCountsAttr().Get()
    indices = mesh.GetFaceVertexIndicesAttr().Get()
    if not points or not counts or not indices:
        return None, None
    pts = np.asarray(points, dtype=np.float64).reshape(-1, 3)
    counts = np.asarray(counts, dtype=np.int64)
    idx = np.asarray(indices, dtype=np.int64)
    if np.all(counts == 3):
        tris = idx.reshape(-1, 3)
    else:   # fan-triangulate polygons
        starts = np.concatenate([[0], np.cumsum(counts)[:-1]])
        rows = []
        for start, n in zip(starts, counts):
            for k in range(1, n - 1):
                rows.append((idx[start], idx[start + k], idx[start + k + 1]))
        tris = np.asarray(rows, dtype=np.int64).reshape(-1, 3)
    matrix = np.asarray(UsdGeom.Xformable(prim).ComputeLocalToWorldTransform(Usd.TimeCode.Default()),
                        dtype=np.float64)
    world = pts @ matrix[:3, :3] + matrix[3, :3]
    return world, tris


def quantise(points, step):
    q = np.floor(points / step + 0.5).astype(np.int64) + BIAS
    if q.min() < 0 or q.max() >= (1 << 21):
        raise SystemExit("model is too large for the 1 mm key")
    return (q[:, 0] << 42) | (q[:, 1] << 21) | q[:, 2]


def cells(points, step):
    return np.floor(points / step).astype(np.int64) + BIAS


def cell_key(c):
    return (c[:, 0] << 42) | (c[:, 1] << 21) | c[:, 2]


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def element_lookup(elements_json):
    by_path, by_name, layer_of = {}, {}, {}
    for e in elements_json["elements"]:
        by_path[e["primPath"]] = e["elementId"]
        by_name[e["entityName"]] = e["elementId"]
        layer_of[e["elementId"]] = e.get("layerId")
    return by_path, by_name, layer_of


def layer_code(codes, layer):
    return codes.setdefault(layer or "", len(codes))


def main_centroids(stage, by_path, by_name, layer_of, codes):
    """Centroids (T x 3), element index and layer code per triangle of the main per-element USDZ."""
    chunks, owners, layers, names = [], [], [], []
    missing = 0
    for prim in stage.Traverse():
        if not prim.IsA(UsdGeom.Mesh):
            continue
        element = None
        custom = prim.GetCustomDataByKey("elementId")
        if isinstance(custom, str) and custom in layer_of:
            element = custom
        node = prim
        while element is None and node and not node.IsPseudoRoot():
            element = by_path.get(str(node.GetPath())) or by_name.get(node.GetName())
            node = node.GetParent()
        if element is None:
            missing += 1
            continue
        world, tris = mesh_triangles(prim)
        if world is None or len(tris) == 0:
            continue
        layer = prim.GetCustomDataByKey("layerId")
        chunks.append(world[tris].mean(axis=1))
        owners.append(np.full(len(tris), len(names), dtype=np.int64))
        layers.append(np.full(len(tris), layer_code(codes, layer if isinstance(layer, str) else layer_of[element]),
                              dtype=np.int64))
        names.append(element)
    if missing:
        log(f"  {missing} main meshes have no element")
    return np.concatenate(chunks), np.concatenate(owners), np.concatenate(layers), names


def rank_match(main_group, ctx_group, main_owner):
    """Matches context rows to main rows of the same group, one to one by occurrence rank
    (coincident triangles of different elements are shared out, not all given to one).
    Returns (owner or -1 per context row, rows whose group has more than one owner)."""
    morder = np.argsort(main_group, kind="stable")
    msorted = main_group[morder]
    first = np.searchsorted(msorted, ctx_group, side="left")
    count = np.searchsorted(msorted, ctx_group, side="right") - first
    corder = np.argsort(ctx_group, kind="stable")
    csorted = ctx_group[corder]
    rank = np.empty(len(ctx_group), dtype=np.int64)
    rank[corder] = np.arange(len(csorted)) - np.searchsorted(csorted, csorted, side="left")
    hit = count > 0
    owner = np.full(len(ctx_group), -1, dtype=np.int64)
    pick = first[hit] + np.minimum(rank[hit], count[hit] - 1)
    owner[hit] = main_owner[morder[pick]]
    # Groups whose main rows belong to more than one element.
    sowner = main_owner[morder]
    differs = (msorted[1:] == msorted[:-1]) & (sowner[1:] != sowner[:-1])
    mixed = np.isin(ctx_group, msorted[1:][differs]) & hit
    return owner, mixed


def groups(*columns):
    """A shared small-integer group ID per row of the stacked key columns."""
    stacked = np.stack(columns, axis=1)
    _, inverse = np.unique(stacked, axis=0, return_inverse=True)
    return inverse.reshape(-1)


def match(ctx_c, ctx_layer, main_c, main_owner, main_layer):
    """Owner index per context centroid (-1 = none) and statistics."""
    n_main = len(main_c)
    main_key, ctx_key = quantise(main_c, EXACT_M), quantise(ctx_c, EXACT_M)
    # 1. Same 1 mm centroid on the same layer.
    gid = groups(np.concatenate([main_key, ctx_key]), np.concatenate([main_layer, ctx_layer]))
    result, mixed = rank_match(gid[:n_main], gid[n_main:], main_owner)
    same_layer = int((result >= 0).sum())
    # 2. Same 1 mm centroid, any layer.
    todo = np.nonzero(result < 0)[0]
    if len(todo):
        gid = groups(np.concatenate([main_key, ctx_key[todo]]))
        found, mixed2 = rank_match(gid[:n_main], gid[n_main:], main_owner)
        result[todo] = found
        mixed[todo] = mixed2
    exact = int((result >= 0).sum())
    stats = {"sameLayer": same_layer, "exact": exact, "coincident": int(mixed.sum())}

    # 3. Nearest main centroid within 5 mm (grid of 5 mm cells, 27 neighbours).
    todo = np.nonzero(result < 0)[0]
    nearest = 0
    if len(todo):
        main_cells = cell_key(cells(main_c, NEAREST_M))
        corder = np.argsort(main_cells, kind="stable")
        csorted = main_cells[corder]
        pts = ctx_c[todo]
        base = cells(pts, NEAREST_M)
        best_d = np.full(len(todo), NEAREST_M * NEAREST_M)
        best_i = np.full(len(todo), -1, dtype=np.int64)
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for dz in (-1, 0, 1):
                    k = cell_key(base + np.array([dx, dy, dz]))
                    lo = np.searchsorted(csorted, k, side="left")
                    hi = np.searchsorted(csorted, k, side="right")
                    span = int((hi - lo).max()) if len(lo) else 0
                    for j in range(span):
                        idx = lo + j
                        ok = idx < hi
                        if not ok.any():
                            break
                        cand = corder[np.minimum(idx, len(corder) - 1)]
                        d = ((main_c[cand] - pts) ** 2).sum(axis=1)
                        better = ok & (d <= best_d)
                        best_d[better] = d[better]
                        best_i[better] = cand[better]
        found = best_i >= 0
        result[todo[found]] = main_owner[best_i[found]]
        nearest = int(found.sum())
    stats["nearest"] = nearest
    return result, stats


def build(package_dir):
    started = time.time()
    package_dir = os.path.abspath(package_dir)
    with open(os.path.join(package_dir, "manifest.json"), encoding="utf-8") as f:
        manifest = json.load(f)
    model = manifest["model"]
    context_rel = model.get("contextPath")
    if not context_rel:
        raise SystemExit(f"{package_dir}: the manifest has no model.contextPath")
    with open(os.path.join(package_dir, "Data", "elements.json"), encoding="utf-8") as f:
        elements_json = json.load(f)
    by_path, by_name, layer_of = element_lookup(elements_json)
    codes = {}

    log(f"{manifest.get('packageId')}: reading the main model {model['path']}")
    main_stage = Usd.Stage.Open(os.path.join(package_dir, *model["path"].split("/")))
    main_c, main_owner, main_layer, main_names = main_centroids(main_stage, by_path, by_name, layer_of, codes)
    log(f"  {len(main_c):,} main triangles over {len(main_names):,} meshes")
    del main_stage

    log(f"  reading the context {context_rel}")
    ctx_stage = Usd.Stage.Open(os.path.join(package_dir, *context_rel.split("/")))
    meshes = []
    for prim in ctx_stage.Traverse():
        if not prim.IsA(UsdGeom.Mesh):
            continue
        world, tris = mesh_triangles(prim)
        if world is None or len(tris) == 0:
            continue
        layer = prim.GetCustomDataByKey("layerId") or prim.GetParent().GetCustomDataByKey("layerId")
        meshes.append((prim, world, tris, layer if isinstance(layer, str) else None))
    names = [m[0].GetName() for m in meshes]
    if len(set(names)) != len(names):
        log(f"  warning: {len(names) - len(set(names))} context mesh names repeat (the app falls back to bounds)")

    all_c = np.concatenate([w[t].mean(axis=1) for _, w, t, _ in meshes])
    ctx_layer = np.concatenate([np.full(len(t), layer_code(codes, layer), dtype=np.int64)
                                for _, _, t, layer in meshes])
    owner, stats = match(all_c, ctx_layer, main_c, main_owner, main_layer)
    exact, nearest = stats["exact"], stats["nearest"]
    total = len(all_c)
    matched = exact + nearest
    rate = matched / total if total else 0.0

    # Element table: only the elements that context triangles use.
    used = sorted(set(int(i) for i in np.unique(owner) if i >= 0))
    element_ids = sorted({main_names[i] for i in used})
    position = {eid: n for n, eid in enumerate(element_ids)}
    remap = np.full(len(main_names), UNKNOWN, dtype=np.int64)
    for i in used:
        remap[i] = position[main_names[i]]
    tri_elements = np.where(owner >= 0, remap[np.maximum(owner, 0)], UNKNOWN).astype("<u4")

    bin_path = os.path.join(package_dir, "Data", "pick.bin")
    json_path = os.path.join(package_dir, "Data", "pick.json")
    table = []
    offset = 0
    cursor = 0
    with open(bin_path + ".tmp", "wb") as out:
        def write(array):
            nonlocal offset
            raw = np.ascontiguousarray(array).tobytes()
            start = offset
            out.write(raw)
            offset += len(raw)
            pad = (-offset) % 4
            if pad:
                out.write(b"\0" * pad)
                offset += pad
            return start

        for prim, world, tris, layer in meshes:
            count = len(tris)
            pts32 = world.astype("<f4")
            unique, inverse = np.unique(pts32, axis=0, return_inverse=True)
            inverse = inverse.reshape(-1)
            local = inverse[tris].astype(np.int64)
            index_size = 2 if len(unique) <= 0xFFFF else 4
            p_off = write(unique.astype("<f4"))
            i_off = write(local.astype("<u2" if index_size == 2 else "<u4"))
            e_off = write(tri_elements[cursor:cursor + count])
            mesh_matched = int((tri_elements[cursor:cursor + count] != UNKNOWN).sum())
            cursor += count
            lo, hi = unique.min(axis=0), unique.max(axis=0)
            table.append({
                "name": prim.GetName(),
                "primPath": str(prim.GetPath()),
                "layerId": layer,
                "triangleCount": count,
                "vertexCount": int(len(unique)),
                "positionOffset": p_off,
                "indexOffset": i_off,
                "indexSize": index_size,
                "elementOffset": e_off,
                "matchedTriangles": mesh_matched,
                "bounds": [[round(float(v), 5) for v in lo], [round(float(v), 5) for v in hi]],
            })
    os.replace(bin_path + ".tmp", bin_path)

    record = manifest.get("files", {}).get(context_rel, {})
    pick = {
        "schemaVersion": 1,
        "packageId": manifest["packageId"],
        "contextPath": context_rel,
        "contextSHA256": record.get("sha256", sha256_file(os.path.join(package_dir, *context_rel.split("/")))),
        "frame": "USD world metres, Y up: the frame of both model USDZ files (full world transforms applied)",
        "byteLength": offset,
        "sha256": sha256_file(bin_path),
        "unknownElement": UNKNOWN,
        "elementIds": element_ids,
        "meshes": table,
        "statistics": {
            "triangles": total,
            "exactMatches": exact,
            "nearestMatches": nearest,
            "unmatched": total - matched,
            "sameLayerMatches": stats["sameLayer"],
            "coincidentWithOtherElements": stats["coincident"],
            "matchRate": round(rate, 6),
            "mainTriangles": int(len(main_c)),
            "exactToleranceM": EXACT_M,
            "nearestToleranceM": NEAREST_M,
        },
    }
    with open(json_path + ".tmp", "w", encoding="utf-8") as f:
        json.dump(pick, f, ensure_ascii=False, separators=(",", ":"))
    os.replace(json_path + ".tmp", json_path)
    log(f"  {len(meshes)} context meshes, {total:,} triangles: exact {exact:,}, within 5 mm {nearest:,}, "
        f"unmatched {total - matched:,}, same layer {stats['sameLayer']:,}, coincident faces shared out {stats['coincident']:,} -> match rate {rate * 100:.3f} %")
    log(f"  {len(element_ids):,} elements; pick.bin {offset / 1e6:.2f} MB, "
        f"pick.json {os.path.getsize(json_path) / 1e3:.0f} kB; {time.time() - started:.0f} s")
    return rate


def main():
    args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]
    if not args:
        raise SystemExit("usage: blender -b --factory-startup --python qv_pick.py -- <package dir> [...]")
    for path in args:
        build(path)


main()
