# QVision "Rendered HD" package: lighting and albedo split (classic lightmap), shown unlit on visionOS.
#
#   final colour = tone(albedo(UV1) x tint x lightmap(UV0) x exposure)
#
# Runs AFTER the v1 pipeline (qv_bake.py prep/uv/bake/post) on the same work blend and bakes:
#   blender -b --python-exit-code 1 --python qv_hd.py -- <stage> --config <scene.json>
#
# Stages:
#   hd_prep    copy the v1 work blend to <name>_hd_work.blend; classify every material's base colour:
#                const (colour)          -> white 4x4 texture x tint
#                uv    (image on a UV)   -> the original image (resized by visible size) on its UV (+ mapping)
#                box   (image, box/flat projected position or object coords) -> the image on computed UVs
#                tile  (procedural, periodic: config hd.tile_bake) -> baked seamless tile, world-planar UVs
#                bake  (anything else)   -> albedo baked into dense albedo atlases on a fresh unwrap
#                lowres (config hd.lowres) -> the v1 albedo atlas on the lightmap UV
#              writes the UV1 layer "AlbedoUV" and all albedo textures (work/hd/tex) + work/hd/manifest.json
#   hd_light   lightmap = v1 combined (denoised) / v1 albedo, per atlas; log2-encoded 8-bit RGB PNG (raw data);
#              fits the tone curve (rational, per channel) to the v1 AgX output; reports the reconstruction error
#   hd_export  materials with BOTH outputs: UsdPreviewSurface = v1 baked atlas on st (fallback, Quick Look) and
#              outputs:mtlx:surface = the HD graph (specializes one master material). USDZ + sidecar, usdchecker.
#   hd_verify  previews with the same math (Blender node replica of the USD graph, values read from the USDZ)
#              + close-ups + v1-vs-HD comparison sheet + thumbnail.

import bpy, bmesh, os, sys, re, json, math, time, shutil
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qv_bake as Q  # noqa: E402

log = Q.log
ALB_UV = 'AlbedoUV'
LN2 = math.log(2.0)


# ----------------------------------------------------------------------------------------------- config
def hd(cfg):
    h = dict(cfg.get('hd', {}))
    out = cfg['out_dir']
    h.setdefault('name', cfg['name'] + '_HD')
    h.setdefault('title', cfg['title'] + ' HD')
    h['work'] = os.path.join(out, 'work', cfg['name'] + '_hd_work.blend')
    h['dir'] = os.path.join(out, 'work', 'hd')
    h['tex'] = os.path.join(h['dir'], 'tex')
    h['light'] = os.path.join(h['dir'], 'light')
    h['manifest'] = os.path.join(h['dir'], 'manifest.json')
    h['previews'] = os.path.join(out, 'previews_hd')
    for d in (h['dir'], h['tex'], h['light'], h['previews']):
        os.makedirs(d, exist_ok=True)
    h.setdefault('tile_bake', {})          # {material: {"period_m": 2.4, "size": 4096, "axes": ["Z"]}}
    h.setdefault('lowres', [])             # regex: keep the v1 albedo atlas (lightmap resolution)
    h.setdefault('force_bake', [])         # regex: always bake the albedo
    h.setdefault('hero', [])               # regex: albedo at full native resolution
    h.setdefault('texel_mm', 0.8)          # target albedo texel for uv-mapped assets
    h.setdefault('hero_texel_mm', 0.4)
    h.setdefault('max_size', 4096)
    h.setdefault('ext_max_size', 1024)     # materials only seen outside
    h.setdefault('bake_atlas_size', 4096)
    h.setdefault('bake_atlas_max', 2)
    h.setdefault('bake_texel_mm', 1.2)
    h.setdefault('lightmap_size', {'main': 4096, 'ext': 2048})
    h.setdefault('log2_range', [-10.0, 5.0])
    h.setdefault('albedo_floor', 0.01)
    h.setdefault('jpeg_quality', 90)
    h.setdefault('fallback_size', 2048)
    h.setdefault('closeups', [])
    return h


def save_manifest(H, man):
    with open(H['manifest'], 'w', encoding='utf-8') as f:
        json.dump(man, f, indent=1)


def load_manifest(H):
    with open(H['manifest'], encoding='utf-8') as f:
        return json.load(f)


def safe(s):
    return re.sub(r'[^A-Za-z0-9_]', '_', s)


# ----------------------------------------------------------------------------------------------- image io
def srgb_encode(x):
    import numpy as np
    x = np.clip(x, 0.0, 1.0)
    return np.where(x <= 0.0031308, x * 12.92, 1.055 * np.power(x, 1 / 2.4) - 0.055)


def srgb_decode(x):
    import numpy as np
    return np.where(x <= 0.04045, x / 12.92, np.power((x + 0.055) / 1.055, 2.4))


def write_bytes_image(arr01, path, fmt, quality=90):
    """arr01: HxWx3|4 float array of the exact 8-bit values (0..1) to store (no colour conversion)."""
    import numpy as np
    h, w = arr01.shape[:2]
    c = arr01.shape[2]
    rgba = np.ones((h, w, 4), dtype=np.float32)
    rgba[..., :c] = arr01[..., :c]
    name = '_qv_out'
    old = bpy.data.images.get(name)
    if old:
        bpy.data.images.remove(old)
    img = bpy.data.images.new(name, w, h, alpha=(c == 4), float_buffer=False)
    img.colorspace_settings.name = 'Non-Color'     # stored values untouched
    img.pixels.foreach_set(rgba.ravel())
    img.filepath_raw = path
    img.file_format = fmt
    if fmt == 'JPEG':
        img.save(filepath=path, quality=quality)
    else:
        img.save(filepath=path)
    bpy.data.images.remove(img)


def image_linear_rgb(img):
    """Image -> HxWx3 linear float (Blender converts byte sRGB images to linear in .pixels? no: bytes are raw)."""
    import numpy as np
    w, h = img.size
    a = np.empty(w * h * 4, dtype=np.float32)
    img.pixels.foreach_get(a)
    a = a.reshape(h, w, 4)
    if not img.is_float and img.colorspace_settings.name.lower().startswith('srgb'):
        return srgb_decode(a[..., :3]), a
    return a[..., :3], a


def export_image(img, path, max_dim, quality):
    """Copy a Blender image to a JPEG with its longest side <= max_dim (stored sRGB values kept)."""
    import numpy as np
    w, h = img.size
    cp = img.copy()
    cp.name = '_qv_resize'
    s = min(1.0, max_dim / float(max(w, h)))
    if s < 0.999:
        cp.scale(max(1, int(round(w * s))), max(1, int(round(h * s))))
    W, Hh = cp.size
    a = np.empty(W * Hh * 4, dtype=np.float32)
    cp.pixels.foreach_get(a)
    a = a.reshape(Hh, W, 4)
    if cp.is_float or not cp.colorspace_settings.name.lower().startswith('srgb'):
        a[..., :3] = srgb_encode(a[..., :3])
    bpy.data.images.remove(cp)
    write_bytes_image(a[..., :3], path, 'JPEG', quality)
    return W, Hh


# ----------------------------------------------------------------------------------------------- material analysis
def _const(sock):
    v = sock.default_value
    return [float(v[0]), float(v[1]), float(v[2])]


def _vec_source(sock):
    """Vector input of an image node -> ('uv', name, scale, loc) | ('pos', swz, scale) | None."""
    if not sock.is_linked:
        return ('uv', None, (1.0, 1.0, 1.0), (0.0, 0.0, 0.0))
    l = sock.links[0]; n = l.from_node; out = l.from_socket.name
    scale = (1.0, 1.0, 1.0); loc = (0.0, 0.0, 0.0)
    if n.type == 'MAPPING':
        if n.vector_type != 'POINT' or any(abs(x) > 1e-6 for x in n.inputs['Rotation'].default_value) \
                or n.inputs['Scale'].is_linked or n.inputs['Location'].is_linked or n.inputs['Rotation'].is_linked:
            return None
        scale = tuple(n.inputs['Scale'].default_value); loc = tuple(n.inputs['Location'].default_value)
        if not n.inputs['Vector'].is_linked:
            return None
        l = n.inputs['Vector'].links[0]; n = l.from_node; out = l.from_socket.name
    if n.type == 'UVMAP':
        return ('uv', n.uv_map or None, scale, loc)
    if n.type == 'TEX_COORD' and out == 'UV':
        return ('uv', None, scale, loc)
    if (n.type == 'NEW_GEOMETRY' and out == 'Position') or (n.type == 'TEX_COORD' and out == 'Object'):
        return ('pos', (0, 1, 2), scale, loc)          # transforms are applied: object space == world space
    if n.type == 'COMBXYZ':
        swz = []
        src = None
        for ax in ('X', 'Y', 'Z'):
            i = n.inputs[ax]
            if not i.is_linked or i.links[0].from_node.type != 'SEPXYZ':
                return None
            sep = i.links[0].from_node
            swz.append('XYZ'.index(i.links[0].from_socket.name))
            s2 = _vec_source(sep.inputs['Vector'])
            if not s2 or s2[0] != 'pos' or s2[2] != (1.0, 1.0, 1.0):
                return None
            src = s2
        return ('pos', tuple(swz), scale, loc)
    return None


def parse_color(sock, depth=0):
    """Base-colour socket -> {'mode': const|image|other, ...} with an accumulated multiply tint."""
    if depth > 6:
        return {'mode': 'other'}
    if not sock.is_linked:
        return {'mode': 'const', 'tint': _const(sock)}
    l = sock.links[0]; n = l.from_node
    if n.type == 'RGB':
        return {'mode': 'const', 'tint': _const(n.outputs[0])}
    fac = next((i for i in n.inputs if i.identifier == 'Factor_Float'), None) if n.type == 'MIX' else None
    if n.type == 'MIX' and n.data_type == 'RGBA' and n.blend_type == 'MULTIPLY' and fac is not None \
            and not fac.is_linked and abs(fac.default_value - 1.0) < 1e-6:
        A = next(i for i in n.inputs if i.identifier == 'A_Color'); B = next(i for i in n.inputs if i.identifier == 'B_Color')
        if A.is_linked and B.is_linked:
            return {'mode': 'other'}
        lk, ct = (A, B) if A.is_linked else (B, A)
        r = parse_color(lk, depth + 1) if lk.is_linked else {'mode': 'const', 'tint': _const(lk)}
        if r['mode'] == 'other':
            return r
        k = _const(ct)
        r['tint'] = [r['tint'][j] * k[j] for j in range(3)]
        return r
    if n.type == 'TEX_IMAGE' and l.from_socket.name == 'Color' and n.image:
        vs = _vec_source(n.inputs['Vector'])
        if vs is None:
            return {'mode': 'other'}
        r = {'mode': 'image', 'image': n.image.name, 'tint': [1.0, 1.0, 1.0]}
        if vs[0] == 'uv':
            if n.projection != 'FLAT':
                return {'mode': 'other'}
            r.update(coord='uv', uv=vs[1], scale=list(vs[2]), loc=list(vs[3]))
        else:
            r.update(coord='box' if n.projection == 'BOX' else ('flat' if n.projection == 'FLAT' else 'other'),
                     swz=list(vs[1]), scale=list(vs[2]), loc=list(vs[3]))
            if r['coord'] == 'other':
                return {'mode': 'other'}
        return r
    return {'mode': 'other'}


def material_mode(mat, H):
    if Q.rx_any(H['force_bake'], mat.name):
        return {'mode': 'bake'}
    if mat.name in H['tile_bake']:
        return dict(mode='tile', **H['tile_bake'][mat.name])
    if Q.rx_any(H['lowres'], mat.name):
        return {'mode': 'lowres'}
    b = Q.principled(mat)
    if not b:
        return {'mode': 'const', 'tint': [0.6, 0.6, 0.6]}
    r = parse_color(b.inputs['Base Color'])
    if r['mode'] == 'image':
        r['mode'] = 'uv' if r['coord'] == 'uv' else 'box'
    elif r['mode'] == 'other':
        r = {'mode': 'bake'}
    return r


def set_target(mat, img):
    nt = mat.node_tree
    n = nt.nodes.get('QV_BAKE_TARGET') or nt.nodes.new('ShaderNodeTexImage')
    n.name = 'QV_BAKE_TARGET'; n.image = img
    for x in nt.nodes:
        x.select = False
    n.select = True; nt.nodes.active = n


# ----------------------------------------------------------------------------------------------- UV1 computation
def box_uv(co, n):
    """Cycles box projection (svm_node_tex_image_box), dominant axis only."""
    ax = max(range(3), key=lambda i: abs(n[i]))
    if ax == 0:
        return ((1.0 - co[1]) if n[0] < 0 else co[1], co[2])
    if ax == 1:
        return ((1.0 - co[0]) if n[1] > 0 else co[0], co[2])
    return ((1.0 - co[1]) if n[2] > 0 else co[1], co[0])


def visible_faces(o):
    """Faces that got a real lightmap density in the v1 UV stage (hidden faces were shrunk ~12x)."""
    import numpy as np
    me = o.data
    uv = me.uv_layers[Q.BAKE_UV]
    n = len(me.loops)
    u = np.empty(n * 2, dtype=np.float64); uv.data.foreach_get('uv', u); u = u.reshape(-1, 2)
    d = np.zeros(len(me.polygons))
    for p in me.polygons:
        q = u[p.loop_start:p.loop_start + p.loop_total]
        a2 = abs(np.dot(q[:, 0], np.roll(q[:, 1], 1)) - np.dot(q[:, 1], np.roll(q[:, 0], 1))) / 2
        d[p.index] = math.sqrt(a2 / p.area) if p.area > 1e-10 else 0
    return d


def stage_hd_prep(a, cfg):
    import numpy as np
    H = hd(cfg)
    sc = bpy.context.scene
    bpy.ops.wm.save_as_mainfile(filepath=H['work'], compress=False)
    log('HD work copy', H['work'])
    atlases = {A['index']: A for A in Q.load_atlases(sc)}
    objs = [o for o in Q.mesh_objects() if o.get('qv_kind') in ('main', 'ext', 'context') and 'qv_atlas' in o
            and not all(Q.mat_class(s.material, cfg) == 'glass' for s in o.material_slots)]
    Q.ensure_materials(objs)

    # 1) per-material mode + visible area per (material)
    modes = {}
    vis_area = {}
    inst = {}
    only_ext = {}
    dens_cache = {}
    for o in objs:
        d = visible_faces(o); dens_cache[o.name] = d
        ref = np.percentile(d[d > 0], 90) if (d > 0).any() else 1.0
        ext = o.get('qv_kind') in ('ext', 'context')
        for s in o.material_slots:
            m = s.material
            if m.name not in modes:
                modes[m.name] = material_mode(m, H)
                vis_area[m.name] = 0.0; inst[m.name] = set(); only_ext[m.name] = True
            inst[m.name].add(o.name); only_ext[m.name] &= ext
        for p in o.data.polygons:
            if d[p.index] > 0.3 * ref:
                vis_area[o.material_slots[p.material_index].material.name] += p.area
    for m, md in sorted(modes.items(), key=lambda x: -vis_area[x[0]]):
        log('  mode %-7s %-30s vis %.1f m2' % (md['mode'], m, vis_area[m]), md.get('image', ''), md.get('coord', ''))

    # 2) UV1 per face
    for o in objs:
        me = o.data
        if ALB_UV in me.uv_layers:
            me.uv_layers.remove(me.uv_layers[ALB_UV])
        src_uv = next((l for l in me.uv_layers if l.active_render), None)
        alb = me.uv_layers.new(name=ALB_UV, do_init=False)
        bake_uv = me.uv_layers[Q.BAKE_UV]
        verts = me.vertices
        for p in me.polygons:
            md = modes[o.material_slots[p.material_index].material.name]
            m = md['mode']
            for li in p.loop_indices:
                vi = me.loops[li].vertex_index
                if m == 'const':
                    uvv = (0.5, 0.5)
                elif m == 'uv':
                    lay = me.uv_layers.get(md.get('uv') or '') or src_uv
                    if lay is None or lay.name in (Q.BAKE_UV, ALB_UV):
                        uvv = (0.5, 0.5)
                    else:
                        u0 = lay.data[li].uv
                        uvv = (u0.x * md['scale'][0] + md['loc'][0], u0.y * md['scale'][1] + md['loc'][1])
                elif m == 'box' or m == 'tile':
                    co = verts[vi].co
                    if m == 'box':
                        sw = md['swz']; sc3 = md['scale']; lc = md['loc']
                        c3 = [co[sw[k]] * sc3[k] + lc[k] for k in range(3)]
                        if md['coord'] == 'flat':
                            uvv = (c3[0], c3[1])
                        else:
                            uvv = box_uv(c3, p.normal)
                    else:
                        P = md['period_m']
                        ax = max(range(3), key=lambda i: abs(p.normal[i]))
                        uvv = ((co[1], co[2]) if ax == 0 else (co[0], co[2]) if ax == 1 else (co[0], co[1]))
                        uvv = (uvv[0] / P, uvv[1] / P)
                elif m == 'lowres':
                    uvv = tuple(bake_uv.data[li].uv)
                else:   # bake: set by the unwrap below
                    uvv = (0.5, 0.5)
                alb.data[li].uv = uvv
        me.uv_layers.active = bake_uv
    man = {'materials': {}, 'images': {}, 'bake_atlases': [], 'tiles': {}}

    # 3) textures for const / uv / box
    white = os.path.join(H['tex'], 'white4.png')
    write_bytes_image(np.ones((4, 4, 3), dtype=np.float32), white, 'PNG')
    man['images']['white4.png'] = {'w': 4, 'h': 4}
    for mname, md in modes.items():
        e = {'mode': md['mode'], 'tint': md.get('tint', [1, 1, 1]), 'vis_area': round(vis_area[mname], 2)}
        if md['mode'] == 'const':
            e['albedo'] = 'white4.png'
        elif md['mode'] in ('uv', 'box'):
            img = bpy.data.images[md['image']]
            w, h = img.size
            if md['mode'] == 'uv':
                a1 = vis_area[mname] / max(1, len(inst[mname]))
                t = (H['hero_texel_mm'] if Q.rx_any(H['hero'], mname) else H['texel_mm']) / 1000.0
                req = math.sqrt(max(a1, 1e-4)) / t
                dim = min(max(w, h), max(256, 2 ** int(math.ceil(math.log2(max(req, 1))))))
            else:
                dim = max(w, h)
            dim = min(dim, H['max_size'], H['ext_max_size'] if only_ext[mname] else H['max_size'])
            fn = safe(md['image']) + '_%d.jpg' % dim
            if fn not in man['images']:
                W, Hh = export_image(img, os.path.join(H['tex'], fn), dim, H['jpeg_quality'])
                man['images'][fn] = {'w': W, 'h': Hh}
            e['albedo'] = fn
        man['materials'][mname] = e

    # 4) tile bakes (seamless periodic albedo on a plane, per axis)
    sc.render.engine = 'CYCLES'; Q.setup_gpu(sc)
    sc.cycles.samples = 16
    for mname, md in modes.items():
        if md['mode'] != 'tile':
            continue
        P = md['period_m']; size = int(md.get('size', 4096))
        for axn in md.get('axes', ['Z']):
            ax = 'XYZ'.index(axn)
            zs = [v.co[ax] for o in objs for v in o.data.vertices if any(s.material and s.material.name == mname for s in o.material_slots)]
            c0 = float(np.median(zs)) if zs else 0.0
            bm = bmesh.new()
            pts = [(0, 0), (P, 0), (P, P), (0, P)]
            vs = []
            for (s_, t_) in pts:
                v = [0.0, 0.0, 0.0]
                oth = [i for i in range(3) if i != ax]
                v[oth[0]] = s_; v[oth[1]] = t_; v[ax] = c0
                vs.append(bm.verts.new(v))
            f = bm.faces.new(vs)
            f.normal_update()
            if f.normal[ax] < 0:
                f.normal_flip()
            me = bpy.data.meshes.new('_qv_tile'); bm.to_mesh(me); bm.free()
            uvl = me.uv_layers.new(name=ALB_UV)
            oth = [i for i in range(3) if i != ax]
            for li, loop in enumerate(me.loops):
                co = me.vertices[loop.vertex_index].co
                uvl.data[li].uv = (co[oth[0]] / P, co[oth[1]] / P)
            ob = bpy.data.objects.new('_qv_tile', me); sc.collection.objects.link(ob)
            me.materials.append(bpy.data.materials[mname])
            img = Q.new_float_image('QV_tile', size)
            Q.set_bake_target([ob], img)
            Q.select_only([ob])
            bpy.ops.object.bake(type='DIFFUSE', pass_filter={'COLOR'}, margin=0, use_clear=True,
                                target='IMAGE_TEXTURES', uv_layer=ALB_UV)
            lin, _ = image_linear_rgb(img)
            fn = 'tile_%s_%s.jpg' % (safe(mname), axn)
            write_bytes_image(srgb_encode(lin), os.path.join(H['tex'], fn), 'JPEG', H['jpeg_quality'])
            man['images'][fn] = {'w': size, 'h': size}
            man['tiles'].setdefault(mname, {})[axn] = fn
            bpy.data.objects.remove(ob); bpy.data.meshes.remove(me); bpy.data.images.remove(img)
            log('tile baked', mname, axn, 'P=%.2f m' % P, size, 'px (%.2f mm/texel)' % (1000 * P / size))
        man['materials'][mname]['albedo'] = man['tiles'][mname].get('Z') or next(iter(man['tiles'][mname].values()))

    # 5) bake mode: dense albedo atlases on a fresh unwrap of the visible 'bake' faces
    bake_objs = []
    tot = 0.0
    for o in objs:
        idx = [i for i, s in enumerate(o.material_slots) if modes[s.material.name]['mode'] == 'bake']
        if idx:
            bake_objs.append((o, set(idx)))
            tot += sum(p.area for p in o.data.polygons if p.material_index in idx and dens_cache[o.name][p.index] > 0)
    if bake_objs:
        S = H['bake_atlas_size']
        per_atlas_m2 = 0.7 * (S * H['bake_texel_mm'] / 1000.0) ** 2
        n_at = max(1, min(H['bake_atlas_max'], int(math.ceil(tot / per_atlas_m2))))
        log('bake-mode albedo: %.1f m2 -> %d atlas(es) of %d' % (tot, n_at, S))
        # unwrap only bake faces
        sc.tool_settings.use_uv_select_sync = True
        Q.edit_objects([o for o, _ in bake_objs])
        bpy.ops.mesh.select_all(action='DESELECT')
        bpy.ops.object.mode_set(mode='OBJECT')
        for o, idx in bake_objs:
            o.data.uv_layers.active = o.data.uv_layers[ALB_UV]
            for p in o.data.polygons:
                p.select = p.material_index in idx
        bpy.ops.object.mode_set(mode='EDIT')
        bpy.ops.uv.smart_project(angle_limit=math.radians(60), margin_method='FRACTION', island_margin=0.0,
                                 area_weight=0.0, correct_aspect=True, scale_to_bounds=False)
        bpy.ops.object.mode_set(mode='OBJECT')
        # island scale: world area, hidden faces tiny
        from bpy_extras.bmesh_utils import bmesh_linked_uv_islands
        groups = [[] for _ in range(n_at)]
        loads = [0.0] * n_at
        for o, idx in sorted(bake_objs, key=lambda x: -sum(p.area for p in x[0].data.polygons)):
            d = dens_cache[o.name]; ref = np.percentile(d[d > 0], 90) if (d > 0).any() else 1.0
            bm = bmesh.new(); bm.from_mesh(o.data); bm.faces.ensure_lookup_table()
            uvl = bm.loops.layers.uv[ALB_UV]
            faces = [f for f in bm.faces if f.material_index in idx]
            sub = set(faces)
            for isl in bmesh_linked_uv_islands(bm, uvl):
                if not isl or isl[0] not in sub:
                    continue
                a3 = 0.0; auv = 0.0; cx = cy = 0.0; nl = 0
                for f in isl:
                    w = 1.0 if d[f.index] > 0.3 * ref else 0.1
                    a3 += f.calc_area() * w * w
                    uvs = [l[uvl].uv.copy() for l in f.loops]
                    auv += Q.poly_uv_area(uvs)
                    for u_ in uvs:
                        cx += u_.x; cy += u_.y; nl += 1
                s_ = math.sqrt(a3 / auv) if auv > 1e-14 and a3 > 1e-12 else 1e-4
                cx /= max(nl, 1); cy /= max(nl, 1)
                for f in isl:
                    for l in f.loops:
                        uu = l[uvl].uv; uu.x = (uu.x - cx) * s_; uu.y = (uu.y - cy) * s_
            bm.to_mesh(o.data); bm.free()
            k = loads.index(min(loads)); groups[k].append((o, idx))
            loads[k] += sum(p.area for p in o.data.polygons if p.material_index in idx)
        bake_mats = sorted({m for m, md in modes.items() if md['mode'] == 'bake'})
        for k, grp in enumerate(groups):
            if not grp:
                continue
            Q.edit_objects([o for o, _ in grp])
            bpy.ops.mesh.select_all(action='DESELECT')
            bpy.ops.object.mode_set(mode='OBJECT')
            for o, idx in grp:
                o.data.uv_layers.active = o.data.uv_layers[ALB_UV]
                for p in o.data.polygons:
                    p.select = p.material_index in idx
            bpy.ops.object.mode_set(mode='EDIT')
            bpy.ops.uv.pack_islands(udim_source='CLOSEST_UDIM', rotate=True, rotate_method='ANY', scale=True,
                                    merge_overlap=False, margin_method='FRACTION', margin=8.0 / S, shape_method='CONCAVE')
            bpy.ops.object.mode_set(mode='OBJECT')
            img = Q.new_float_image('QV_albbake_%d' % k, S)
            dummy = Q.new_float_image('QV_dummy', 8)
            gobjs = [o for o, _ in grp]
            # bake target: image for 'bake' materials, a throwaway image for the others
            for mm in {s.material for o in gobjs for s in o.material_slots}:
                set_target(mm, img if mm.name in bake_mats else dummy)
            Q.select_only(gobjs)
            bpy.ops.object.bake(type='DIFFUSE', pass_filter={'COLOR'}, margin=16, margin_type='EXTEND',
                                use_clear=True, target='IMAGE_TEXTURES', uv_layer=ALB_UV)
            lin, raw = image_linear_rgb(img)
            cov = raw[..., 3] > 0.5
            lin = Q.push_pull(lin, cov)
            fn = 'albbake_%d.jpg' % k
            write_bytes_image(srgb_encode(lin), os.path.join(H['tex'], fn), 'JPEG', H['jpeg_quality'])
            man['images'][fn] = {'w': S, 'h': S}
            man['bake_atlases'].append({'file': fn, 'objects': [o.name for o in gobjs]})
            for o in gobjs:
                o['qv_hd_bake_atlas'] = fn
            bpy.data.images.remove(img); bpy.data.images.remove(dummy)
            # texel actually achieved
            uva = 0.0; wa = 0.0
            for o, idx in grp:
                uvl = o.data.uv_layers[ALB_UV]
                for p in o.data.polygons:
                    if p.material_index in idx and p.area > 0.01:
                        uva += Q.poly_uv_area([uvl.data[li].uv for li in p.loop_indices]); wa += p.area
            log('albedo bake atlas', fn, 'objects', len(gobjs), 'texel %.2f mm' % (1000.0 / (math.sqrt(uva / wa) * S) if uva > 0 else -1))
        for o, _ in bake_objs:
            o.data.uv_layers.active = o.data.uv_layers[Q.BAKE_UV]
    man['modes'] = {m: {k: v for k, v in md.items()} for m, md in modes.items()}
    save_manifest(H, man)
    bpy.ops.wm.save_mainfile(filepath=H['work'], compress=False)
    log('HD prep done: materials', len(modes), 'images', len(man['images']))


# ----------------------------------------------------------------------------------------------- stage: hd_light
def box_blur(x, r):
    """Box filter (2r+1)^2 with edge clamping, via integral images."""
    import numpy as np
    p = np.pad(x, ((r + 1, r), (r + 1, r), (0, 0)), mode='edge').cumsum(0).cumsum(1)
    k = 2 * r + 1
    return (p[k:, k:] - p[:-k, k:] - p[k:, :-k] + p[:-k, :-k]) / (k * k)


def fit_tone(x, y):
    """Fit y ~ x(ax+b)/(x(cx+d)+e) (per channel, same curve) in sRGB-encoded space. Levenberg-Marquardt."""
    import numpy as np
    def f(p, x):
        a, b, c, d, e = p
        return np.clip(x * (a * x + b) / (x * (c * x + d) + e), 0, 1)
    ye = srgb_encode(y)
    p = np.array([2.51, 0.03, 2.43, 0.59, 0.14])
    lam = 1e-2
    def res(p):
        return srgb_encode(f(p, x)) - ye
    r = res(p); cost = float((r * r).mean())
    for it in range(200):
        J = np.empty((x.size, 5))
        for k in range(5):
            dp = np.zeros(5); dp[k] = 1e-5 * max(1.0, abs(p[k]))
            J[:, k] = (res(p + dp) - r) / dp[k]
        A = J.T @ J; g = J.T @ r
        while True:
            step = np.linalg.solve(A + lam * np.diag(np.diag(A) + 1e-12), -g)
            pn = p + step
            if (pn[[2, 4]] <= 0).any():
                lam *= 10
                if lam > 1e8:
                    break
                continue
            rn = res(pn); cn = float((rn * rn).mean())
            if cn < cost:
                p, r, cost = pn, rn, cn; lam = max(lam / 3, 1e-9)
                break
            lam *= 4
            if lam > 1e8:
                break
        if lam > 1e8 or float(np.abs(step).max()) < 1e-8:
            break
    return [float(v) for v in p], math.sqrt(cost) * 255


def tone_np(p, x):
    import numpy as np
    a, b, c, d, e = p
    return np.clip(x * (a * x + b) / (x * (c * x + d) + e), 0, 1)


def stage_hd_light(a, cfg):
    import numpy as np
    H = hd(cfg)
    man = load_manifest(H)
    sc0 = bpy.context.scene
    atl = Q.load_atlases(sc0)
    lo, hi = H['log2_range']
    gain = 2.0 ** cfg['view']['exposure']
    rng = np.random.default_rng(1)
    xs, ys = [], []
    lmaps = {}
    for A in atl:
        i = A['index']
        if A['kind'] == 'alpha':
            continue
        bd = cfg['_bakedir']
        den = bpy.data.images.load(os.path.join(bd, 'atlas%d_denoised.exr' % i))
        alb = bpy.data.images.load(os.path.join(bd, 'atlas%d_albedo.exr' % i))
        C = Q.img_to_np(den)[..., :3].astype(np.float64)
        Al = Q.img_to_np(alb)[..., :3].astype(np.float64)
        bpy.data.images.remove(den); bpy.data.images.remove(alb)
        n = C.shape[0]
        cov = np.unpackbits(np.load(os.path.join(bd, 'atlas%d_cover.npy' % i)))[:n * n].reshape(n, n).astype(bool)
        Al = Q.push_pull(Al.astype(np.float32), cov).astype(np.float64)
        L = C / np.maximum(Al, H['albedo_floor'])
        # where the baked albedo is dark the ratio is fragile (texels straddling a dark frame and a bright cushion
        # spike once the full-res albedo is multiplied back): blend towards the ratio of local averages there
        r = int(H.get('dark_blur_px', 2))
        Ls = box_blur(C, r) / np.maximum(box_blur(Al, r), H['albedo_floor'])
        lum = Al @ np.array([0.2126, 0.7152, 0.0722])
        w = np.clip((lum - 0.04) / 0.16, 0.0, 1.0)[..., None]
        L = w * L + (1.0 - w) * Ls
        L = Q.push_pull(L.astype(np.float32), cov).astype(np.float64)
        pct = (np.percentile(L[cov], 50), np.percentile(L[cov], 99))
        size = H['lightmap_size'].get(A['kind'], 4096)
        if size < n:
            f = n // size
            L = np.exp(np.log(np.maximum(L, 2 ** lo)).reshape(size, f, size, f, 3).mean((1, 3)))
        enc = (np.log2(np.maximum(L, 2 ** lo)) - lo) / (hi - lo)
        enc = np.clip(enc, 0, 1)
        q = np.round(enc * 255.0) / 255.0
        fn = '%s_lightmap%d.png' % (H['name'], i)
        write_bytes_image(q.astype(np.float32), os.path.join(H['light'], fn), 'PNG')
        lmaps[str(i)] = {'file': fn, 'size': size}
        # tone-fit samples (v1 output vs. scene linear) on covered texels
        jp = bpy.data.images.load(os.path.join(cfg['_atlasdir'], '%s_atlas%d.jpg' % (cfg['name'], i)))
        V = Q.img_to_np(jp)[..., :3].astype(np.float64)    # stored sRGB values
        bpy.data.images.remove(jp)
        idx = np.flatnonzero(cov.ravel())
        pick = rng.choice(idx, size=min(60000, idx.size), replace=False)
        xs.append((C.reshape(-1, 3)[pick] * gain)); ys.append(srgb_decode(V.reshape(-1, 3)[pick]))
        # reconstruction check data
        if size == n:
            Lq = 2.0 ** (q * (hi - lo) + lo)
            lmaps[str(i)]['_recon'] = (Al.reshape(-1, 3)[pick], Lq.reshape(-1, 3)[pick], V.reshape(-1, 3)[pick])
        log('lightmap', i, fn, size, 'px; L p50/p99 = %.3f / %.2f' % pct)
    x = np.concatenate(xs).ravel(); y = np.concatenate(ys).ravel()
    m = (x > 1e-5)
    sel = rng.choice(np.flatnonzero(m), size=min(150000, int(m.sum())), replace=False)
    p, rms = fit_tone(x[sel], y[sel])
    log('tone curve', [round(v, 5) for v in p], 'rms %.2f (8-bit units)' % rms)
    errs = []
    for k, v in lmaps.items():
        if '_recon' in v:
            Al, Lq, V = v.pop('_recon')
            rec = srgb_encode(tone_np(p, Al * Lq * gain)) * 255
            err = np.abs(rec - V * 255)
            errs.append(err)
            v['recon_mae'] = float(err.mean()); v['recon_p95'] = float(np.percentile(err, 95))
            log('  atlas', k, 'v1 reconstruction |err| mean %.2f, p95 %.2f (8-bit)' % (v['recon_mae'], v['recon_p95']))
    man['light'] = {'log2_min': lo, 'log2_max': hi, 'gain': gain, 'tone': p, 'tone_rms_8bit': rms, 'atlases': lmaps}
    save_manifest(H, man)


# ----------------------------------------------------------------------------------------------- stage: hd_export
MASTER = 'QV_HD_Master'


def author_master(stage, root, L, mpath):
    """The one HD graph (MaterialX nodes, RealityKit unlit surface). Material inputs: Albedo, Lightmap, Tint."""
    from pxr import UsdShade, Sdf, Gf
    mat = UsdShade.Material.Define(stage, mpath)
    T = Sdf.ValueTypeNames
    in_alb = mat.CreateInput('Albedo', T.Asset)
    in_lm = mat.CreateInput('Lightmap', T.Asset)
    in_tint = mat.CreateInput('Tint', T.Color3f); in_tint.Set(Gf.Vec3f(1, 1, 1))
    in_alb.Set(Sdf.AssetPath('./textures_hd/white4.png'))
    in_lm.Set(Sdf.AssetPath('./textures_hd/white4.png'))

    def sh(name, sid):
        s = UsdShade.Shader.Define(stage, mpath.AppendChild(name))
        s.CreateIdAttr(sid)
        return s
    uv0 = sh('UV0', 'ND_texcoord_vector2'); uv0.CreateInput('index', T.Int).Set(0); uv0.CreateOutput('out', T.Float2)
    uv1 = sh('UV1', 'ND_texcoord_vector2'); uv1.CreateInput('index', T.Int).Set(1); uv1.CreateOutput('out', T.Float2)
    lm = sh('LightmapTex', 'ND_image_vector3')
    lm.CreateInput('file', T.Asset).ConnectToSource(in_lm)
    lm.CreateInput('texcoord', T.Float2).ConnectToSource(uv0.GetOutput('out'))
    lm.CreateInput('uaddressmode', T.String).Set('clamp'); lm.CreateInput('vaddressmode', T.String).Set('clamp')
    lm.CreateInput('filtertype', T.String).Set('linear')
    lm.CreateInput('default', T.Float3).Set(Gf.Vec3f(0.6, 0.6, 0.6))
    lm.CreateOutput('out', T.Float3)
    alb = sh('AlbedoTex', 'ND_image_color3')
    f = alb.CreateInput('file', T.Asset); f.ConnectToSource(in_alb)
    alb.CreateInput('texcoord', T.Float2).ConnectToSource(uv1.GetOutput('out'))
    alb.CreateInput('uaddressmode', T.String).Set('periodic'); alb.CreateInput('vaddressmode', T.String).Set('periodic')
    alb.CreateInput('filtertype', T.String).Set('linear')
    alb.CreateInput('default', T.Color3f).Set(Gf.Vec3f(0.5, 0.5, 0.5))
    alb.CreateOutput('out', T.Color3f)
    K = (L['log2_max'] - L['log2_min']) * LN2; B = L['log2_min'] * LN2
    s1 = sh('LmScale', 'ND_multiply_vector3FA'); s1.CreateInput('in1', T.Float3).ConnectToSource(lm.GetOutput('out'))
    s1.CreateInput('in2', T.Float).Set(float(K)); s1.CreateOutput('out', T.Float3)
    s2 = sh('LmBias', 'ND_add_vector3FA'); s2.CreateInput('in1', T.Float3).ConnectToSource(s1.GetOutput('out'))
    s2.CreateInput('in2', T.Float).Set(float(B)); s2.CreateOutput('out', T.Float3)
    s3 = sh('LmExp', 'ND_exp_vector3'); s3.CreateInput('in', T.Float3).ConnectToSource(s2.GetOutput('out')); s3.CreateOutput('out', T.Float3)
    s4 = sh('LmColor', 'ND_convert_vector3_color3'); s4.CreateInput('in', T.Float3).ConnectToSource(s3.GetOutput('out'))
    s4.CreateOutput('out', T.Color3f)
    t1 = sh('AlbTint', 'ND_multiply_color3'); t1.CreateInput('in1', T.Color3f).ConnectToSource(alb.GetOutput('out'))
    t1.CreateInput('in2', T.Color3f).ConnectToSource(in_tint); t1.CreateOutput('out', T.Color3f)
    t2 = sh('Lit', 'ND_multiply_color3'); t2.CreateInput('in1', T.Color3f).ConnectToSource(t1.GetOutput('out'))
    t2.CreateInput('in2', T.Color3f).ConnectToSource(s4.GetOutput('out')); t2.CreateOutput('out', T.Color3f)
    t3 = sh('Exposure', 'ND_multiply_color3FA'); t3.CreateInput('in1', T.Color3f).ConnectToSource(t2.GetOutput('out'))
    t3.CreateInput('in2', T.Float).Set(float(L['gain'])); t3.CreateOutput('out', T.Color3f)
    a_, b_, c_, d_, e_ = L['tone']
    x = t3.GetOutput('out')
    n1 = sh('ToneN1', 'ND_multiply_color3FA'); n1.CreateInput('in1', T.Color3f).ConnectToSource(x); n1.CreateInput('in2', T.Float).Set(a_); n1.CreateOutput('out', T.Color3f)
    n2 = sh('ToneN2', 'ND_add_color3FA'); n2.CreateInput('in1', T.Color3f).ConnectToSource(n1.GetOutput('out')); n2.CreateInput('in2', T.Float).Set(b_); n2.CreateOutput('out', T.Color3f)
    n3 = sh('ToneNum', 'ND_multiply_color3'); n3.CreateInput('in1', T.Color3f).ConnectToSource(n2.GetOutput('out')); n3.CreateInput('in2', T.Color3f).ConnectToSource(x); n3.CreateOutput('out', T.Color3f)
    d1 = sh('ToneD1', 'ND_multiply_color3FA'); d1.CreateInput('in1', T.Color3f).ConnectToSource(x); d1.CreateInput('in2', T.Float).Set(c_); d1.CreateOutput('out', T.Color3f)
    d2 = sh('ToneD2', 'ND_add_color3FA'); d2.CreateInput('in1', T.Color3f).ConnectToSource(d1.GetOutput('out')); d2.CreateInput('in2', T.Float).Set(d_); d2.CreateOutput('out', T.Color3f)
    d3 = sh('ToneD3', 'ND_multiply_color3'); d3.CreateInput('in1', T.Color3f).ConnectToSource(d2.GetOutput('out')); d3.CreateInput('in2', T.Color3f).ConnectToSource(x); d3.CreateOutput('out', T.Color3f)
    d4 = sh('ToneDen', 'ND_add_color3FA'); d4.CreateInput('in1', T.Color3f).ConnectToSource(d3.GetOutput('out')); d4.CreateInput('in2', T.Float).Set(e_); d4.CreateOutput('out', T.Color3f)
    dv = sh('Tone', 'ND_divide_color3'); dv.CreateInput('in1', T.Color3f).ConnectToSource(n3.GetOutput('out')); dv.CreateInput('in2', T.Color3f).ConnectToSource(d4.GetOutput('out')); dv.CreateOutput('out', T.Color3f)
    cl = sh('Clamp', 'ND_clamp_color3FA'); cl.CreateInput('in', T.Color3f).ConnectToSource(dv.GetOutput('out'))
    cl.CreateInput('low', T.Float).Set(0.0); cl.CreateInput('high', T.Float).Set(1.0); cl.CreateOutput('out', T.Color3f)
    un = sh('UnlitSurface', 'ND_realitykit_unlit_surfaceshader')
    un.CreateInput('color', T.Color3f).ConnectToSource(cl.GetOutput('out'))
    un.CreateInput('opacity', T.Float).Set(1.0)
    un.CreateInput('applyPostProcessToneMap', T.Bool).Set(False)
    un.CreateInput('hasPremultipliedAlpha', T.Bool).Set(False)
    out = un.CreateOutput('out', T.Token)
    mat.CreateSurfaceOutput('mtlx').ConnectToSource(out)
    return mat


def stage_hd_export(a, cfg):
    H = hd(cfg)
    man = load_manifest(H)
    L = man['light']
    sc = bpy.context.scene
    name = H['name']; out = cfg['out_dir']
    p, floor_obj, yaw = Q.start_info(sc, cfg)
    for o in list(sc.objects):
        if o.type != 'MESH':
            bpy.data.objects.remove(o, do_unlink=True)
    atlases = {A['index']: A for A in Q.load_atlases(sc)}
    # v1 atlas images (preview-surface fallback = exactly the v1 look)
    v1img = {}
    for i, A in atlases.items():
        alpha = A['kind'] == 'alpha'
        path = os.path.join(cfg['_atlasdir'], '%s_atlas%d.%s' % (cfg['name'], i, 'png' if alpha else 'jpg'))
        if not alpha and A['size'] > H['fallback_size']:
            # the fallback only shows if the HD graph is not used: keep it lighter
            src = bpy.data.images.load(path)
            path = os.path.join(H['tex'], 'fallback_atlas%d.jpg' % i)
            export_image(src, path, H['fallback_size'], H['jpeg_quality']); bpy.data.images.remove(src)
        img = bpy.data.images.load(path); img.colorspace_settings.name = 'sRGB'; img.name = os.path.basename(path)
        v1img[i] = img
    glass_mats = {}
    for gname, (r, g, bb, op) in cfg.get('glass_tint', {}).items():
        m = bpy.data.materials.new('QV_Glass' if gname == 'Glass' else 'QV_Glass_' + gname)
        b = Q.principled(m)
        b.inputs['Base Color'].default_value = (r, g, bb, 1); b.inputs['Alpha'].default_value = op
        b.inputs['Roughness'].default_value = 0.05; b.inputs['Specular IOR Level'].default_value = 0.0
        glass_mats[gname] = m
    hdmat = {}      # blender material name -> {albedo, tint, lightmap}
    blmats = {}

    def get_mat(orig, i, alpha):
        key = (orig, i, alpha)
        if key in blmats:
            return blmats[key]
        nm = ('V1_A%d' % i) if alpha else ('HD_%03d_A%d' % (len(blmats), i))
        m = bpy.data.materials.new(nm)
        nt = m.node_tree; b = Q.principled(m)
        t = nt.nodes.new('ShaderNodeTexImage'); t.image = v1img[i]
        nt.links.new(t.outputs['Color'], b.inputs['Base Color'])
        b.inputs['Roughness'].default_value = 1.0; b.inputs['Specular IOR Level'].default_value = 0.0
        if alpha:
            nt.links.new(t.outputs['Alpha'], b.inputs['Alpha'])
        else:
            e = man['materials'][orig]
            alb = e.get('albedo')
            if e['mode'] == 'lowres':
                alb = 'albedo_atlas%d.jpg' % i
            elif e['mode'] == 'bake':
                alb = None     # per object: filled below
            hdmat[nm] = {'orig': orig, 'albedo': alb, 'tint': e.get('tint', [1, 1, 1]),
                         'lightmap': L['atlases'][str(i)]['file'], 'mode': e['mode']}
        blmats[key] = m
        return m

    groups = {}
    need_alb_atlas = set()
    for o in Q.mesh_objects():
        me = o.data
        names = [s.material.name if s.material else '' for s in o.material_slots]
        if o.get('qv_kind') == 'glass' or (o.material_slots and all(Q.mat_class(s_.material, cfg) == 'glass' for s_ in o.material_slots)):
            gm = next((glass_mats[k] for k in glass_mats if any(re.search('^' + k + '$', n) for n in names)), None) or glass_mats['Glass']
            for l in list(me.uv_layers):
                me.uv_layers.remove(l)
            me.materials.clear(); me.materials.append(gm)
            groups.setdefault('G_' + gm.name, []).append(o)
            continue
        if 'qv_atlas' not in o:
            bpy.data.objects.remove(o, do_unlink=True); continue
        i = o['qv_atlas']; alpha = atlases[i]['kind'] == 'alpha'
        new = []
        for n_ in names:
            m = get_mat(n_, i, alpha)
            if not alpha and man['materials'][n_]['mode'] == 'bake':
                # one material per (orig, atlas, bake atlas file)
                fn = o.get('qv_hd_bake_atlas')
                key = (n_, i, False, fn)
                if key not in blmats:
                    mm = m.copy(); mm.name = 'HD_%03d_A%d' % (len(blmats), i)
                    blmats[key] = mm
                    hdmat[mm.name] = dict(hdmat[m.name], albedo=fn)
                m = blmats[key]
            if not alpha and man['materials'][n_]['mode'] == 'lowres':
                need_alb_atlas.add(i)
            new.append(m)
        for k_, m in enumerate(new):
            me.materials[k_] = m
        keep = [Q.BAKE_UV] + ([] if alpha else [ALB_UV])
        for l in [l for l in me.uv_layers if l.name not in keep]:
            me.uv_layers.remove(l)
        me.uv_layers[Q.BAKE_UV].name = 'st'
        if not alpha:
            me.uv_layers[ALB_UV].name = 'st1'
        me.uv_layers['st'].active = True; me.uv_layers['st'].active_render = True
        for k in list(o.keys()):
            del o[k]
        groups.setdefault(('A%d' % i) + ('_alpha' if alpha else ''), []).append(o)
    # albedo atlases (v1 resolution) for lowres materials
    import numpy as np
    for i in sorted(need_alb_atlas):
        al = bpy.data.images.load(os.path.join(cfg['_bakedir'], 'atlas%d_albedo.exr' % i))
        A_ = Q.img_to_np(al)[..., :3]; bpy.data.images.remove(al)
        n = A_.shape[0]
        cov = np.unpackbits(np.load(os.path.join(cfg['_bakedir'], 'atlas%d_cover.npy' % i)))[:n * n].reshape(n, n).astype(bool)
        A_ = Q.push_pull(A_, cov)
        sz = H['lightmap_size'].get(atlases[i]['kind'], n)
        if sz < n:
            f_ = n // sz
            A_ = A_.reshape(sz, f_, sz, f_, 3).mean((1, 3))
        write_bytes_image(srgb_encode(A_), os.path.join(H['tex'], 'albedo_atlas%d.jpg' % i), 'JPEG', H['jpeg_quality'])
        man['images']['albedo_atlas%d.jpg' % i] = {'w': A_.shape[1], 'h': A_.shape[0]}
    for key, objs in groups.items():
        Q.select_only(objs)
        if len(objs) > 1:
            bpy.ops.object.join()
        j = bpy.context.view_layer.objects.active
        j.name = key if isinstance(key, str) else str(key); j.data.name = j.name
    for m in list(bpy.data.materials):
        if m.users == 0:
            bpy.data.materials.remove(m)
    for k in [k for k in hdmat if k not in bpy.data.materials]:
        del hdmat[k]
    objs = Q.mesh_objects()
    tris = Q.tri_count(objs)
    log('HD export meshes', len(objs), 'materials', len(hdmat), 'triangles', tris)
    stage_dir = os.path.join(out, 'work', 'usd_hd')
    if os.path.isdir(stage_dir):
        shutil.rmtree(stage_dir)
    os.makedirs(stage_dir)
    usdc = os.path.join(stage_dir, name + '.usdc')
    bpy.ops.wm.usd_export(filepath=usdc, selected_objects_only=False, export_animation=False, export_hair=False,
                          export_uvmaps=True, rename_uvmaps=False, export_mesh_colors=False, export_normals=False,
                          export_materials=True, generate_preview_surface=True, generate_materialx_network=False,
                          export_textures_mode='NEW', overwrite_textures=True, relative_paths=True, use_instancing=False,
                          evaluation_mode='RENDER', convert_orientation=True,
                          export_global_forward_selection='NEGATIVE_Z', export_global_up_selection='Y',
                          export_lights=False, export_cameras=False, convert_world_material=False,
                          triangulate_meshes=True, root_prim_path='/root',
                          convert_scene_units='METERS', export_custom_properties=False)
    # copy HD textures
    tdir = os.path.join(stage_dir, 'textures_hd'); os.makedirs(tdir, exist_ok=True)
    used = {'white4.png'}
    for e in hdmat.values():
        used.add(e['albedo']); used.add(e['lightmap'])
    for fn in used:
        src = os.path.join(H['light'] if 'lightmap' in fn else H['tex'], fn)
        shutil.copy2(src, os.path.join(tdir, fn))
    # author: opacity for glass / cut-outs, the master HD graph, HD materials specialize it
    from pxr import Usd, UsdShade, UsdGeom, UsdUtils, Sdf, Gf
    st = Usd.Stage.Open(usdc)
    opac = {m.name: Q.principled(m).inputs['Alpha'].default_value for m in bpy.data.materials
            if Q.principled(m) and not Q.principled(m).inputs['Alpha'].is_linked and Q.principled(m).inputs['Alpha'].default_value < 0.999}
    cut = [m.name for m in bpy.data.materials if Q.principled(m) and Q.principled(m).inputs['Alpha'].is_linked]
    mroot = Sdf.Path('/root/_materials')
    master = author_master(st, Sdf.Path('/root'), L, mroot.AppendChild(MASTER))
    n_hd = 0
    for prim in list(st.Traverse()):
        if prim.IsA(UsdShade.Material) and prim.GetName() != MASTER:
            mname = prim.GetName()
            for ch in Usd.PrimRange(prim):
                s_ = UsdShade.Shader(ch)
                if s_ and s_.GetIdAttr().Get() == 'UsdPreviewSurface':
                    if mname in opac:
                        s_.CreateInput('opacity', Sdf.ValueTypeNames.Float).Set(float(opac[mname]))
                    if mname in cut:
                        s_.CreateInput('opacityThreshold', Sdf.ValueTypeNames.Float).Set(0.5)
                    s_.CreateInput('metallic', Sdf.ValueTypeNames.Float).Set(0.0)
            if mname in hdmat:
                e = hdmat[mname]
                prim.GetSpecializes().AddSpecialize(master.GetPath())
                m_ = UsdShade.Material(prim)
                m_.CreateInput('Albedo', Sdf.ValueTypeNames.Asset).Set(Sdf.AssetPath('./textures_hd/' + e['albedo']))
                m_.CreateInput('Lightmap', Sdf.ValueTypeNames.Asset).Set(Sdf.AssetPath('./textures_hd/' + e['lightmap']))
                m_.CreateInput('Tint', Sdf.ValueTypeNames.Color3f).Set(Gf.Vec3f(*[float(v) for v in e['tint']]))
                n_hd += 1
        if prim.IsA(UsdGeom.Mesh):
            pv = UsdGeom.PrimvarsAPI(prim)
            for nm in ('Color', 'displayColor', 'displayOpacity'):
                if pv.HasPrimvar(nm):
                    pv.RemovePrimvar(nm)
    # colour space of the albedo file input (sRGB); the lightmap is raw data (vector3 image)
    st.GetPrimAtPath(master.GetPath().AppendChild('AlbedoTex')).GetAttribute('inputs:file').SetMetadata('colorSpace', 'srgb_texture')
    st.GetRootLayer().Save()
    log('HD materials authored', n_hd)
    usdz = os.path.join(out, name + '.usdz')
    if os.path.exists(usdz):
        os.remove(usdz)
    if not UsdUtils.CreateNewUsdzPackage(Sdf.AssetPath(usdc), usdz):
        raise SystemExit('USDZ packaging failed')
    size = os.path.getsize(usdz)
    log('USDZ', usdz, round(size / 1e6, 1), 'MB')
    # validation
    chk = UsdUtils.ComplianceChecker(arkit=False, skipARKitRootLayerCheck=False, rootPackageOnly=False, skipVariants=False, verbose=False)
    chk.CheckCompliance(usdz)
    errs, warns, fails = chk.GetErrors(), chk.GetWarnings(), chk.GetFailedChecks()
    log('usdchecker: errors', len(errs), 'failed', len(fails), 'warnings', len(warns))
    for x in (errs + fails + warns)[:20]:
        log('   ', str(x)[:300])
    # texture memory if decoded as RGBA8 with mips (runtime-loaded USDZ textures are not pre-compressed)
    mem = {'hd': 0, 'v1_fallback': 0}
    lm_size = {v['file']: v['size'] for v in L['atlases'].values()}
    for fn in used:
        if fn in lm_size:
            w_ = h_ = lm_size[fn]
        else:
            w_ = man['images'][fn]['w']; h_ = man['images'][fn]['h']
        mem['hd'] += w_ * h_ * 4 * 4 // 3
    for i, A in atlases.items():
        fs = A['size'] if A['kind'] == 'alpha' else min(A['size'], H['fallback_size'])
        mem['v1_fallback'] += fs * fs * 4 * 4 // 3
    log('texture memory (RGBA8+mips): HD %.0f MB, v1 fallback atlases %.0f MB' % (mem['hd'] / 2**20, mem['v1_fallback'] / 2**20))
    side = {
        'title': H['title'], 'version': 1,
        'start': {'position': [round(v, 3) for v in Q.blender_to_usd(p)], 'yawDegrees': round(yaw, 1) + 0.0},
        'eyeHeightIncluded': False, 'hasSky': bool(cfg.get('has_sky', False)),
        'shading': 'hd-lightmap',
        'notes': ('HD: albedo (original textures, UV1 "st1") x baked lightmap (UV0 "st", log2 RGB 2^%g..2^%g) x exposure %.3f, '
                  'tone curve x(ax+b)/(x(cx+d)+e) a..e=%s fitted to AgX "%s"; RealityKit MaterialX graph '
                  '(ND_realitykit_unlit_surfaceshader, no post tone map). Fallback outputs:surface = the v1 baked atlas on st. '
                  'Lighting: Blender %s Cycles, sun %.1f/%.1f deg.')
                 % (L['log2_min'], L['log2_max'], L['gain'], [round(v, 4) for v in L['tone']], cfg['view']['look'],
                    bpy.app.version_string, cfg['sun']['elevation'], cfg['sun']['azimuth']),
    }
    with open(os.path.join(out, name + '.json'), 'w', encoding='utf-8') as f:
        json.dump(side, f, indent=2)
    man['export'] = {'texture_mem_bytes': mem, 'usdz_bytes': size, 'triangles': tris, 'hd_materials': hdmat, 'checker_errors': [str(x) for x in errs + fails]}
    save_manifest(H, man)


# ----------------------------------------------------------------------------------------------- stage: hd_verify
def build_hd_blender_material(m, e, L, texdir, cache):
    """Blender node replica of the USD HD graph: emission = tone(albedo(st1) x tint x exp(lm(st) K + B) x gain)."""
    nt = m.node_tree
    for n in list(nt.nodes):
        nt.nodes.remove(n)

    def img(fn, noncolor):
        k = (fn, noncolor)
        if k not in cache:
            im = bpy.data.images.load(os.path.join(texdir, fn))
            im.colorspace_settings.name = 'Non-Color' if noncolor else 'sRGB'
            cache[k] = im
        return cache[k]
    uv0 = nt.nodes.new('ShaderNodeUVMap'); uv0.uv_map = 'st'
    uv1 = nt.nodes.new('ShaderNodeUVMap'); uv1.uv_map = 'st1'
    lm = nt.nodes.new('ShaderNodeTexImage'); lm.image = img(e['lightmap'], True); lm.extension = 'EXTEND'; lm.interpolation = 'Linear'
    al = nt.nodes.new('ShaderNodeTexImage'); al.image = img(e['albedo'], False); al.extension = 'REPEAT'; al.interpolation = 'Linear'
    nt.links.new(uv0.outputs[0], lm.inputs[0]); nt.links.new(uv1.outputs[0], al.inputs[0])

    def vm(op, a, b=None, val=None):
        n = nt.nodes.new('ShaderNodeVectorMath'); n.operation = op
        nt.links.new(a, n.inputs[0])
        if b is not None:
            nt.links.new(b, n.inputs[1])
        elif val is not None:
            n.inputs[1].default_value = (val, val, val)
        return n.outputs[0]

    def const(v):
        n = nt.nodes.new('ShaderNodeCombineXYZ'); n.inputs[0].default_value, n.inputs[1].default_value, n.inputs[2].default_value = v
        return n.outputs[0]
    K = (L['log2_max'] - L['log2_min']) * LN2; Bb = L['log2_min'] * LN2
    x = vm('MULTIPLY', lm.outputs['Color'], val=K)
    x = vm('ADD', x, val=Bb)
    # exp per channel
    sep = nt.nodes.new('ShaderNodeSeparateXYZ'); nt.links.new(x, sep.inputs[0])
    comb = nt.nodes.new('ShaderNodeCombineXYZ')
    for k in range(3):
        mth = nt.nodes.new('ShaderNodeMath'); mth.operation = 'EXPONENT'
        nt.links.new(sep.outputs[k], mth.inputs[0]); nt.links.new(mth.outputs[0], comb.inputs[k])
    lit = vm('MULTIPLY', al.outputs['Color'], const(e['tint']))
    lit = vm('MULTIPLY', lit, comb.outputs[0])
    xg = vm('MULTIPLY', lit, val=L['gain'])
    a_, b_, c_, d_, e_ = L['tone']
    num = vm('MULTIPLY', vm('ADD', vm('MULTIPLY', xg, val=a_), val=b_), xg)
    den = vm('ADD', vm('MULTIPLY', vm('ADD', vm('MULTIPLY', xg, val=c_), val=d_), xg), val=e_)
    y = vm('DIVIDE', num, den)
    y = vm('MINIMUM', vm('MAXIMUM', y, val=0.0), val=1.0)
    em = nt.nodes.new('ShaderNodeEmission'); nt.links.new(y, em.inputs['Color'])
    o = nt.nodes.new('ShaderNodeOutputMaterial'); nt.links.new(em.outputs[0], o.inputs['Surface'])


def stage_hd_verify(a, cfg):
    import numpy as np
    H = hd(cfg)
    name = H['name']; out = cfg['out_dir']
    usdz = os.path.join(out, name + '.usdz')
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    bpy.ops.wm.usd_import(filepath=usdz, import_lights=False, import_cameras=False)
    objs = [o for o in sc.objects if o.type == 'MESH']
    log('imported', len(objs), 'meshes, tris', Q.tri_count(objs), 'UV sets', sorted({l.name for o in objs for l in o.data.uv_layers}))
    # read the HD inputs + master constants back from the USDZ (verifies the file, not our intentions)
    from pxr import Usd, UsdShade
    st = Usd.Stage.Open(usdz)
    mpath = '/root/_materials/' + MASTER
    mp = st.GetPrimAtPath(mpath)
    g = lambda n, i: mp.GetChild(n).GetAttribute('inputs:' + i).Get()
    K = g('LmScale', 'in2'); B = g('LmBias', 'in2')
    L = {'log2_min': B / LN2, 'log2_max': (K + B) / LN2, 'gain': g('Exposure', 'in2'),
         'tone': [g('ToneN1', 'in2'), g('ToneN2', 'in2'), g('ToneD1', 'in2'), g('ToneD2', 'in2'), g('ToneDen', 'in2')]}
    texdir = os.path.join(out, 'work', 'usd_hd', 'textures_hd')
    hdm = {}
    for prim in st.Traverse():
        if prim.IsA(UsdShade.Material) and prim.GetName() != MASTER and prim.GetAttribute('inputs:Lightmap').HasAuthoredValue():
            m_ = UsdShade.Material(prim)
            hdm[prim.GetName()] = {'albedo': os.path.basename(m_.GetInput('Albedo').Get().path),
                                   'lightmap': os.path.basename(m_.GetInput('Lightmap').Get().path),
                                   'tint': list(m_.GetInput('Tint').Get()),
                                   'mtlx': bool(m_.GetSurfaceOutput('mtlx').HasConnectedSource())}
    log('HD materials in file', len(hdm), 'with mtlx surface', sum(1 for v in hdm.values() if v['mtlx']), 'L', L)
    # two looks: 'v1' = the preview surface (baked atlas) emission-only, 'hd' = the graph replica
    v1mats = {}
    for m in bpy.data.materials:
        if not m.node_tree:
            continue
        nt = m.node_tree; b = Q.principled(m)
        tex = next((n for n in nt.nodes if n.type == 'TEX_IMAGE' and n.image), None)
        col = b.inputs['Base Color'].default_value[:] if b else (1, 1, 1, 1)
        alpha_link = b.inputs['Alpha'].links[0].from_socket if b and b.inputs['Alpha'].is_linked else None
        alpha_val = b.inputs['Alpha'].default_value if b else 1.0
        if b and not alpha_link and b.inputs['Transmission Weight'].default_value > 0.001:
            alpha_val = min(alpha_val, 1.0 - b.inputs['Transmission Weight'].default_value)
        v1mats[m.name] = (tex.image if tex else None, col, alpha_val, alpha_link is not None, tex.uv_map if False else None)
    cache = {}

    def set_look(look):
        for m in bpy.data.materials:
            if m.name not in v1mats:
                continue
            nt = m.node_tree
            if look == 'hd' and m.name in hdm:
                build_hd_blender_material(m, hdm[m.name], L, texdir, cache)
                continue
            for n in list(nt.nodes):
                nt.nodes.remove(n)
            im, col, av, has_alpha_tex, _ = v1mats[m.name]
            em = nt.nodes.new('ShaderNodeEmission'); outn = nt.nodes.new('ShaderNodeOutputMaterial')
            last = em.outputs[0]
            if im:
                t = nt.nodes.new('ShaderNodeTexImage'); t.image = im
                uv = nt.nodes.new('ShaderNodeUVMap'); uv.uv_map = 'st'; nt.links.new(uv.outputs[0], t.inputs[0])
                nt.links.new(t.outputs['Color'], em.inputs['Color'])
                if has_alpha_tex:
                    tr = nt.nodes.new('ShaderNodeBsdfTransparent'); mx = nt.nodes.new('ShaderNodeMixShader')
                    nt.links.new(t.outputs['Alpha'], mx.inputs['Fac']); nt.links.new(tr.outputs[0], mx.inputs[1]); nt.links.new(em.outputs[0], mx.inputs[2])
                    last = mx.outputs[0]
            else:
                em.inputs['Color'].default_value = col
            if av < 0.999 and not has_alpha_tex:
                tr = nt.nodes.new('ShaderNodeBsdfTransparent'); mx = nt.nodes.new('ShaderNodeMixShader')
                mx.inputs['Fac'].default_value = av
                nt.links.new(tr.outputs[0], mx.inputs[1]); nt.links.new(em.outputs[0], mx.inputs[2]); last = mx.outputs[0]
            nt.links.new(last, outn.inputs['Surface'])
    w = bpy.data.worlds.new('W'); sc.world = w
    bg = next(n for n in w.node_tree.nodes if n.type == 'BACKGROUND'); bg.inputs['Color'].default_value = (0.42, 0.62, 0.92, 1)
    Q.setup_gpu(sc)
    sc.cycles.samples = a.samples or 32; sc.cycles.use_denoising = False
    sc.cycles.max_bounces = 0; sc.cycles.transparent_max_bounces = 16
    sc.cycles.filter_width = 1.0
    sc.view_settings.view_transform = 'Standard'; sc.view_settings.look = 'None'; sc.view_settings.exposure = 0
    Wd = a.res or 1280; Ht = int(Wd * 0.625)
    sc.render.image_settings.file_format = 'JPEG'; sc.render.image_settings.quality = 92
    side = json.load(open(os.path.join(out, name + '.json')))
    sp = side['start']['position']; yaw = math.radians(side['start']['yawDegrees'])
    start_b = Vector((sp[0], -sp[2], sp[1])); fwd = Vector((-math.sin(yaw), math.cos(yaw), 0))
    views = [{'name': '00_start', 'pos': list(start_b + Vector((0, 0, 1.6))), 'target': list(start_b + fwd * 4 + Vector((0, 0, 1.4))), 'lens': 18}]
    views += cfg['preview_views'] + H['closeups']
    cd = bpy.data.cameras.new('cam'); cam = bpy.data.objects.new('cam', cd); sc.collection.objects.link(cam); sc.camera = cam
    cd.sensor_width = 36; cd.clip_start = 0.05; cd.clip_end = 500
    files = {'v1': [], 'hd': []}
    for look in ('hd', 'v1'):
        set_look(look)
        for v in views:
            sc.render.resolution_x = Wd; sc.render.resolution_y = Ht
            cd.lens = v.get('lens', 18); cam.location = v['pos']
            cam.rotation_euler = (Vector(v['target']) - Vector(v['pos'])).to_track_quat('-Z', 'Y').to_euler()
            f = os.path.join(H['previews'], ('%s.jpg' if look == 'hd' else 'v1_%s.jpg') % v['name'])
            sc.render.filepath = f; bpy.ops.render.render(write_still=True); files[look].append(f)
            log('preview', look, v['name'])
        if look == 'hd':
            cd.lens = 18; cam.location = views[0]['pos']
            cam.rotation_euler = (Vector(views[0]['target']) - Vector(views[0]['pos'])).to_track_quat('-Z', 'Y').to_euler()
            sc.render.resolution_x = 512; sc.render.resolution_y = 320
            sc.render.filepath = os.path.join(out, name + '.jpg'); bpy.ops.render.render(write_still=True)

    def sheet(paths, cols, outp, step=2):
        tiles = []
        for f in paths:
            im = bpy.data.images.load(f); px = Q.img_to_np(im)[..., :3]; tiles.append(px[::step, ::step]); bpy.data.images.remove(im)
        th, tw = tiles[0].shape[:2]; rows = (len(tiles) + cols - 1) // cols
        S = np.zeros((rows * th, cols * tw, 4), dtype=np.float32); S[..., 3] = 1
        for k, t in enumerate(tiles):
            r = rows - 1 - k // cols; c = k % cols
            S[r * th:(r + 1) * th, c * tw:(c + 1) * tw, :3] = t
        write_bytes_image(S[..., :3], outp, 'JPEG', 88)
    sheet(files['hd'], 4, os.path.join(H['previews'], 'sheet.jpg'))
    pairs = []
    for f1, f2 in zip(files['v1'], files['hd']):
        pairs += [f1, f2]
    sheet(pairs, 2, os.path.join(H['previews'], 'compare_v1_vs_hd.jpg'))
    log('HD previews', H['previews'])


# ----------------------------------------------------------------------------------------------- main
def main():
    a, cfg = Q.parse()
    fn = globals().get('stage_' + a.stage)
    if not fn:
        raise SystemExit('unknown stage ' + a.stage)
    H = hd(cfg)
    cur = os.path.normcase(os.path.abspath(bpy.data.filepath)) if bpy.data.filepath else ''
    want = {'hd_prep': cfg['_work'], 'hd_light': H['work'], 'hd_export': H['work']}.get(a.stage)
    if want and cur != os.path.normcase(os.path.abspath(want)):
        bpy.ops.wm.open_mainfile(filepath=want, load_ui=False)
    fn(a, cfg)
    log('DONE', a.stage)


if __name__ == '__main__':
    main()
