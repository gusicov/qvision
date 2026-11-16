# QVision "Rendered" bake pipeline (Blender 5.x, Cycles).
#
# Usage (always background):
#   blender -b <blend> --python qv_bake.py -- <stage> --config <scene.json> [--work <work.blend>] [options]
#
# Stages (run in order; each one opens the work blend that the previous stage saved):
#   prep     open the SOURCE blend (passed as <blend>), save it immediately as the work blend, then clean it:
#            single-user data, render modifiers applied, transforms applied, hidden/junk removed,
#            glass/alpha faces split off, materials made bake-friendly, sun + sky + AgX set.
#   lookdev  quick low-res renders of the scene cameras (sun study).                    (optional)
#   uv       lightmap UVs ("BakeUV"): per-face texel weights, island scaling, atlas assignment, packing.
#   bake     Cycles bake per atlas: COMBINED (diffuse+transmission+emission, direct+indirect, no glossy)
#            + albedo (for the denoiser) + alpha mask (alpha atlas). Float EXR, resumable.
#   post     OIDN denoise (compositor, albedo-guided), AgX + exposure (scene view transform), dilate, JPEG/PNG.
#   export   new unlit-style materials (base colour = baked atlas via BakeUV), glass tint + opacity,
#            USDZ (Y-up, metres, textures packed), sidecar JSON, thumbnail.
#   verify   (run with an EMPTY scene: blender -b --factory-startup) import the USDZ, all materials emission-only,
#            render preview viewpoints + contact sheet.
#
# All paths come from the JSON config / arguments. Nothing is ever written next to the source blend.

import bpy, bmesh, sys, os, re, json, math, time, argparse
from mathutils import Vector, Matrix

T0 = time.time()


def log(*a):
    print('[qv_bake %6.1fs]' % (time.time() - T0), *a, flush=True)


# ----------------------------------------------------------------------------------------------- args / config
def parse():
    argv = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
    p = argparse.ArgumentParser()
    p.add_argument('stage')
    p.add_argument('--config', required=True)
    p.add_argument('--work', default=None, help='work .blend (default <out_dir>/work/<name>_bake_work.blend)')
    p.add_argument('--atlas', default=None, help='bake/post: only these atlas indices, e.g. 0,3')
    p.add_argument('--samples', type=int, default=None)
    p.add_argument('--res', type=int, default=None, help='lookdev/verify: render width')
    p.add_argument('--tag', default='', help='lookdev: output tag')
    p.add_argument('--cams', default='', help='lookdev: camera name filter, comma separated')
    p.add_argument('--sun', default=None, help='lookdev: "elev,azim" override')
    p.add_argument('--exposure', type=float, default=None)
    p.add_argument('--force', action='store_true', help='bake/post: redo existing atlases')
    a = p.parse_args(argv)
    with open(a.config, 'r', encoding='utf-8') as f:
        cfg = json.load(f)
    out = cfg['out_dir']
    cfg['_work'] = a.work or os.path.join(out, 'work', cfg['name'] + '_bake_work.blend')
    cfg['_bakedir'] = os.path.join(out, 'work', 'bake')
    cfg['_atlasdir'] = os.path.join(out, 'work', 'atlas')
    cfg['_previews'] = os.path.join(out, 'previews')
    for d in (os.path.dirname(cfg['_work']), cfg['_bakedir'], cfg['_atlasdir'], cfg['_previews']):
        os.makedirs(d, exist_ok=True)
    return a, cfg


def rx_any(pats, s):
    return any(re.search(p, s) for p in pats)


# ----------------------------------------------------------------------------------------------- helpers
def principled(mat):
    if not mat or not mat.node_tree:
        return None
    return next((n for n in mat.node_tree.nodes if n.type == 'BSDF_PRINCIPLED'), None)


def mat_class(mat, cfg):
    """glass | alpha | translucent | normal"""
    if mat is None:
        return 'normal'
    if rx_any(cfg['glass_materials'], mat.name):
        return 'glass'
    if mat.name in cfg.get('translucent_materials', {}):
        return 'translucent'
    b = principled(mat)
    if b and b.inputs['Alpha'].is_linked:
        return 'alpha'
    return 'normal'


def setup_gpu(scene):
    scene.render.engine = 'CYCLES'
    prefs = bpy.context.preferences.addons['cycles'].preferences
    for t in ('OPTIX', 'CUDA'):
        try:
            prefs.compute_device_type = t
            prefs.get_devices()
            ds = [d for d in prefs.devices if d.type == t]
            if ds:
                for d in prefs.devices:
                    d.use = (d.type == t)
                scene.cycles.device = 'GPU'
                log('GPU', t, [d.name for d in ds])
                return t
        except Exception as ex:
            log('gpu', t, ex)
    scene.cycles.device = 'CPU'
    return 'CPU'


def world_bbox(objs):
    mn = Vector((1e9,) * 3); mx = Vector((-1e9,) * 3)
    for o in objs:
        for c in o.bound_box:
            v = o.matrix_world @ Vector(c)
            mn = Vector(map(min, mn, v)); mx = Vector(map(max, mx, v))
    return mn, mx


def tri_count(objs):
    return sum(sum(len(p.vertices) - 2 for p in o.data.polygons) for o in objs if o.type == 'MESH')


def mesh_objects():
    return [o for o in bpy.context.scene.objects if o.type == 'MESH']


def split_faces(obj, face_pred, new_name):
    """Move the faces for which face_pred(poly) is True into a new object. Returns it (or None)."""
    me = obj.data
    sel = [face_pred(p) for p in me.polygons]
    if not any(sel) or all(sel):
        return None
    new = obj.copy(); new.data = me.copy(); new.name = new_name
    for c in obj.users_collection:
        c.objects.link(new)
    for target, keep in ((obj, False), (new, True)):
        bm = bmesh.new(); bm.from_mesh(target.data); bm.faces.ensure_lookup_table()
        kill = [f for f in bm.faces if sel[f.index] != keep]
        bmesh.ops.delete(bm, geom=kill, context='FACES')
        bm.to_mesh(target.data); bm.free()
    return new


# ----------------------------------------------------------------------------------------------- lighting
def setup_lighting(scene, cfg, sun_override=None, exposure=None):
    el, az = cfg['sun']['elevation'], cfg['sun']['azimuth']
    if sun_override:
        el, az = sun_override
    EL, AZ = math.radians(el), math.radians(az)
    w = scene.world or bpy.data.worlds.new('World')
    scene.world = w
    nt = w.node_tree
    for n in list(nt.nodes):
        nt.nodes.remove(n)
    out = nt.nodes.new('ShaderNodeOutputWorld'); bg = nt.nodes.new('ShaderNodeBackground'); sky = nt.nodes.new('ShaderNodeTexSky')
    ids = [i.identifier for i in sky.bl_rna.properties['sky_type'].enum_items]
    sky.sky_type = next((i for i in ids if 'MULTIPLE' in i), next((i for i in ids if 'NISHITA' in i), ids[-1]))
    sky.sun_elevation = EL
    # Blender's sky: sun_rotation is measured from +Y towards -X? -> calibrated in lookdev 'skycheck'; config azimuth is from +Y towards +X.
    sky.sun_rotation = math.radians(cfg.get('sky_rotation_offset', 0.0)) + (AZ if cfg.get('sky_rotation_sign', 1) > 0 else -AZ)
    sky.sun_disc = bool(cfg['sky'].get('disc', False))
    nt.links.new(sky.outputs[0], bg.inputs['Color']); nt.links.new(bg.outputs[0], out.inputs['Surface'])
    bg.inputs['Strength'].default_value = cfg['sky']['strength']
    sun = next((o for o in scene.objects if o.type == 'LIGHT' and o.data.type == 'SUN'), None)
    if sun is None:
        L = bpy.data.lights.new('Sun', 'SUN'); sun = bpy.data.objects.new('Sun', L); scene.collection.objects.link(sun)
    L = sun.data
    L.energy = cfg['sun']['strength']; L.angle = math.radians(cfg['sun']['angle']); L.color = cfg['sun']['color']
    d = Vector((math.sin(AZ) * math.cos(EL), math.cos(AZ) * math.cos(EL), math.sin(EL)))
    sun.rotation_euler = d.to_track_quat('Z', 'Y').to_euler()
    vs = scene.view_settings
    vs.view_transform = cfg['view']['transform']
    try:
        vs.look = cfg['view']['look']
    except Exception as ex:
        log('look', ex)
    vs.exposure = cfg['view']['exposure'] if exposure is None else exposure
    vs.gamma = 1.0
    scene.cycles.film_exposure = 1.0
    return sun


# ----------------------------------------------------------------------------------------------- stage: prep
def stage_prep(a, cfg):
    src = bpy.data.filepath
    if os.path.normcase(os.path.abspath(src)) == os.path.normcase(os.path.abspath(cfg['_work'])):
        raise SystemExit('prep must be started on the SOURCE blend')
    # save our own copy FIRST, before touching anything
    bpy.ops.wm.save_as_mainfile(filepath=cfg['_work'], relative_remap=True, compress=False)
    log('work copy saved', cfg['_work'], 'from', src)
    sc = bpy.context.scene
    sc.render.use_simplify = False

    # 1) remove excluded collections (asset library, orphans) and anything not visible/renderable
    for cname in cfg.get('remove_collections', []):
        c = bpy.data.collections.get(cname)
        if not c:
            continue
        for o in list(c.all_objects):
            bpy.data.objects.remove(o, do_unlink=True)
        for ch in list(c.children_recursive):
            bpy.data.collections.remove(ch)
        bpy.data.collections.remove(c)
    vl = bpy.context.view_layer
    n_rm = 0
    for o in list(sc.objects):
        if o.type in ('MESH', 'CURVE', 'SURFACE', 'META', 'FONT') and (o.hide_render or not o.visible_get(view_layer=vl)):
            bpy.data.objects.remove(o, do_unlink=True); n_rm += 1
    log('removed hidden', n_rm)

    # 2) convert curves/text to mesh, apply render modifiers, make single-user, apply transforms
    for o in sc.objects:
        for m in getattr(o, 'modifiers', []):
            m.show_viewport = m.show_render
    dg = bpy.context.evaluated_depsgraph_get()
    geo = [o for o in sc.objects if o.type in ('MESH', 'CURVE', 'SURFACE', 'META', 'FONT')]
    for o in geo:
        mw = o.matrix_world.copy()
        mats = [s.material for s in o.material_slots]
        ev = o.evaluated_get(dg)
        me = bpy.data.meshes.new_from_object(ev, preserve_all_data_layers=True, depsgraph=dg)
        me.name = o.name
        if o.type != 'MESH':
            new = bpy.data.objects.new(o.name + '_mesh', me)
            for c in o.users_collection:
                c.objects.link(new)
            bpy.data.objects.remove(o, do_unlink=True)
            o = new
        else:
            o.modifiers.clear()
            o.data = me
        # NB: materials.clear() would reset every face's material_index -> assign slot by slot
        for i, m in enumerate(mats):
            if i < len(me.materials):
                me.materials[i] = m
            else:
                me.materials.append(m)
        for s in o.material_slots:
            s.link = 'DATA'
        o.parent = None
        me.transform(mw)
        if mw.determinant() < 0:
            me.flip_normals()
        o.matrix_world = Matrix.Identity(4)
    for o in list(sc.objects):
        if o.type == 'EMPTY':
            bpy.data.objects.remove(o, do_unlink=True)
    for me in list(bpy.data.meshes):
        if me.users == 0:
            bpy.data.meshes.remove(me)
    # degenerate / empty meshes
    for o in list(mesh_objects()):
        if len(o.data.polygons) == 0:
            bpy.data.objects.remove(o, do_unlink=True)
    if not cfg.get('keep_cameras', True):
        for o in list(sc.objects):
            if o.type == 'CAMERA':
                bpy.data.objects.remove(o, do_unlink=True)

    # 3) split glass / alpha / translucent faces into their own objects
    n_split = 0
    for o in list(mesh_objects()):
        classes = [mat_class(s.material, cfg) for s in o.material_slots]
        if len(set(classes)) <= 1:
            continue
        for cl in sorted(set(classes) - {'normal'}):
            idx = {i for i, c in enumerate(classes) if c == cl}
            if split_faces(o, lambda p, idx=idx: p.material_index in idx, o.name + '_' + cl):
                n_split += 1
    log('split objects', n_split)

    # 4) bake-friendly materials: metals -> darkened dielectric (diffuse bake has no glossy), mirrors -> grey
    for mat in bpy.data.materials:
        b = principled(mat)
        if not b:
            continue
        nt = mat.node_tree
        if rx_any(cfg.get('mirror_materials', []), mat.name):
            for l in list(b.inputs['Base Color'].links):
                nt.links.remove(l)
            b.inputs['Base Color'].default_value = (0.20, 0.215, 0.23, 1)
            for l in list(b.inputs['Metallic'].links):
                nt.links.remove(l)
            b.inputs['Metallic'].default_value = 0.0
            continue
        met = b.inputs['Metallic']
        if met.is_linked or met.default_value > 0.3:
            for l in list(met.links):
                nt.links.remove(l)
            met.default_value = 0.0
            k = cfg.get('metal_darken', 0.75)
            bc = b.inputs['Base Color']
            if bc.is_linked:
                src_sock = bc.links[0].from_socket
                mix = nt.nodes.new('ShaderNodeMix'); mix.data_type = 'RGBA'; mix.blend_type = 'MULTIPLY'
                mix.inputs['Factor'].default_value = 1.0
                mix.inputs[7].default_value = (k, k, k, 1)
                nt.links.new(src_sock, mix.inputs[6]); nt.links.new(mix.outputs[2], bc)
            else:
                c = bc.default_value
                bc.default_value = (c[0] * k, c[1] * k, c[2] * k, 1)

    # 5) lights, sky, colour management, cycles
    for L in bpy.data.lights:
        if L.type != 'SUN':
            L.energy *= cfg.get('lamp_scale', 1.0)
    setup_lighting(sc, cfg)
    setup_gpu(sc)
    cy = sc.cycles
    cy.max_bounces = 12; cy.diffuse_bounces = 6; cy.glossy_bounces = 3; cy.transmission_bounces = 8
    cy.transparent_max_bounces = 16; cy.sample_clamp_indirect = 10.0
    cy.caustics_reflective = False; cy.caustics_refractive = False
    for me in bpy.data.meshes:
        if me.users == 0:
            bpy.data.meshes.remove(me)
    bpy.ops.outliner.orphans_purge(do_recursive=True)
    objs = mesh_objects()
    fl = fix_inward_normals([o for o in objs if obj_kind(o, cfg) in ('main', 'alpha')])   # interiors only: shells fool the test
    log('inward-facing faces flipped', sum(fl.values()), 'in', len(fl), 'objects')
    tris = tri_count(objs)
    log('PREP objects', len(objs), 'triangles', tris)
    if tris > cfg.get('max_triangles', 1.5e6):
        log('WARNING triangle budget exceeded')
    bpy.ops.wm.save_mainfile(filepath=cfg['_work'], compress=False)
    log('saved', cfg['_work'])


# ----------------------------------------------------------------------------------------------- stage: lookdev
def stage_lookdev(a, cfg):
    sc = bpy.context.scene
    setup_gpu(sc)
    sun = tuple(float(x) for x in a.sun.split(',')) if a.sun else None
    setup_lighting(sc, cfg, sun, a.exposure)
    outdir = os.path.join(cfg['out_dir'], 'work', 'lookdev'); os.makedirs(outdir, exist_ok=True)
    sc.cycles.samples = a.samples or 96
    sc.cycles.use_denoising = True
    sc.cycles.use_adaptive_sampling = True
    sc.render.resolution_x = a.res or 720; sc.render.resolution_y = int((a.res or 720) * 2 / 3)
    sc.render.resolution_percentage = 100
    sc.render.image_settings.file_format = 'JPEG'; sc.render.image_settings.quality = 88
    if a.cams == 'skycheck':
        # calibrate the sky texture's sun_rotation against the lamp: equirect panorama, sun disc on
        w = sc.world; sky = next(n for n in w.node_tree.nodes if n.type == 'TEX_SKY'); sky.sun_disc = True
        cd = bpy.data.cameras.new('pano'); cd.type = 'PANO'
        try:
            cd.panorama_type = 'EQUIRECTANGULAR'
        except Exception:
            cd.cycles.panorama_type = 'EQUIRECTANGULAR'
        co = bpy.data.objects.new('pano', cd); sc.collection.objects.link(co)
        co.location = (0, 0, 200); co.rotation_euler = (math.pi / 2, 0, 0)
        sc.camera = co; sc.render.resolution_x = 720; sc.render.resolution_y = 360
        for o in sc.objects:
            if o.type == 'MESH':
                o.hide_render = True
        sc.cycles.samples = 16
        sc.render.image_settings.file_format = 'OPEN_EXR'
        p = os.path.join(outdir, 'skycheck.exr'); sc.render.filepath = p
        bpy.ops.render.render(write_still=True)
        log('skycheck written', p)
        return
    flt = [c for c in a.cams.split(',') if c]
    cams = sorted((o for o in sc.objects if o.type == 'CAMERA' and (not flt or any(f in o.name for f in flt))), key=lambda o: o.name)
    for c in cams:
        sc.camera = c
        p = os.path.join(outdir, '%s%s.jpg' % (a.tag + '_' if a.tag else '', c.name))
        sc.render.filepath = p
        t = time.time(); bpy.ops.render.render(write_still=True)
        log('lookdev', c.name, round(time.time() - t, 1), 's')


# ----------------------------------------------------------------------------------------------- inward normals
def fix_inward_normals(objs, min_area=1e-4, cap=2.0, ratio=1.6):
    """Cycles bakes the side a face's normal points to. Objects authored inside-out (flutes, lattices,
    bowls) bake black. Per object, compare how open the space is in front of vs behind its faces
    (area-weighted mean free ray length, capped); flip the whole object when the back is clearly more open.
    Returns {object name: face count} of flipped objects."""
    from mathutils.bvhtree import BVHTree
    verts, polys, off = [], [], 0
    for o in objs:
        me = o.data
        verts.extend(v.co.copy() for v in me.vertices)
        polys.extend([off + i for i in p.vertices] for p in me.polygons)
        off += len(me.vertices)
    bvh = BVHTree.FromPolygons(verts, polys, all_triangles=False, epsilon=0.0)
    H = hemisphere_dirs(6)
    out = {}
    for o in objs:
        me = o.data
        polys_ = [p for p in me.polygons if p.area >= min_area]
        if len(polys_) > 4000:                         # dense scanned assets: subsample
            polys_ = polys_[::len(polys_) // 4000 + 1]
        fw = bw = wsum = 0.0
        for p in polys_:
            n = p.normal; t = n.orthogonal().normalized(); b = n.cross(t)
            for sign in (1, -1):
                acc = 0.0
                for h in H:
                    d = (t * h.x + b * h.y + n * h.z) * sign
                    loc, hn, _, dist = bvh.ray_cast(p.center + n * (0.002 * sign), d, cap)
                    acc += cap if loc is None else (dist if hn.dot(d) < 0 else 0.0)   # back-face hit = inside a volume
                if sign > 0:
                    fw += acc * p.area
                else:
                    bw += acc * p.area
            wsum += p.area
        if wsum > 0 and bw > ratio * fw and bw / (wsum * len(H)) > 0.15:
            me.flip_normals(); me.update()
            out[o.name] = len(me.polygons)
    return out


def stage_fixnormals(a, cfg):
    sc = bpy.context.scene
    objs = [o for o in mesh_objects() if obj_kind(o, cfg) in ('main', 'alpha')]
    res = fix_inward_normals(objs)
    atl = sorted({bpy.data.objects[n].get('qv_atlas') for n in res if bpy.data.objects[n].get('qv_atlas') is not None})
    log('flipped objects', len(res), '(faces', sum(res.values()), ') atlases', atl)
    for n, c in sorted(res.items(), key=lambda x: -x[1])[:40]:
        log('  ', n, c)
    bpy.ops.wm.save_mainfile(filepath=cfg['_work'], compress=False)


# ----------------------------------------------------------------------------------------------- stage: uv
BAKE_UV = 'BakeUV'


def obj_kind(o, cfg):
    classes = {mat_class(s.material, cfg) for s in o.material_slots} or {'normal'}
    if classes == {'glass'}:
        return 'glass'
    if 'alpha' in classes:
        return 'alpha'
    if rx_any(cfg.get('context_patterns', []), o.name):
        return 'context'
    if any(c.name in cfg.get('exterior_atlas_collections', []) for c in o.users_collection):
        return 'ext'
    return 'main'


def bisect_object(o, axis, at):
    """Cut o with the plane axis=at; faces on the + side go to a new object."""
    bm = bmesh.new(); bm.from_mesh(o.data)
    no = Vector((0, 0, 0)); no[axis] = 1.0; co = Vector((0, 0, 0)); co[axis] = at
    bmesh.ops.bisect_plane(bm, geom=bm.verts[:] + bm.edges[:] + bm.faces[:], plane_co=co, plane_no=no)
    bm.to_mesh(o.data); bm.free(); o.data.update()
    return split_faces(o, lambda p: p.center[axis] > at, o.name + ('_%s%d' % ('XYZ'[axis], int(at * 100))))


def hemisphere_dirs(n=12):
    d = []
    ga = math.pi * (3 - math.sqrt(5))
    for i in range(n):
        r = math.sqrt((i + 0.5) / n)          # cosine-weighted
        th = i * ga
        d.append(Vector((r * math.cos(th), r * math.sin(th), math.sqrt(max(0.0, 1 - r * r)))))
    return d


def classify_faces(objs, cfg):
    """Per-face texel weight: interior 1, exterior (sees the sky) lower, hidden (touching other geometry) tiny."""
    from mathutils.bvhtree import BVHTree
    verts, polys, off = [], [], 0
    for o in objs:
        me = o.data
        verts.extend(v.co.copy() for v in me.vertices)
        polys.extend([off + i for i in p.vertices] for p in me.polygons)
        off += len(me.vertices)
    bvh = BVHTree.FromPolygons(verts, polys, all_triangles=False, epsilon=0.0)
    log('BVH faces', len(polys))
    fw = cfg['face_weights']
    H = hemisphere_dirs(12)
    res = {}
    stats = {'interior': 0.0, 'exterior': 0.0, 'hidden': 0.0}
    det = cfg.get('detail_materials', {})
    for o in objs:
        me = o.data
        mats = [s.material.name if s.material else '' for s in o.material_slots]
        mboost = [max([v for k, v in det.items() if re.search(k, m)] or [1.0]) for m in mats] or [1.0]
        ws = []
        for p in me.polygons:
            a = p.area
            boost = mboost[p.material_index] if p.material_index < len(mboost) else 1.0
            if a < 0.0025:                       # small faces (props): not worth the rays
                ws.append(fw['interior'] * boost); continue
            n = p.normal
            t = n.orthogonal().normalized(); b = n.cross(t)
            pc = p.center
            pts = [pc]
            if a > 0.25:     # big faces: classify several points, not just the centre
                vs = [me.vertices[vi].co for vi in p.vertices][:8]
                pts += [pc + (v - pc) * f for v in vs for f in (0.85, 0.45)]
            ks = []
            for q in pts:
                c = q + n * 0.003
                hits = 0; esc = 0; near = 0; close = 0; back = 0
                for h in H:
                    d = t * h.x + b * h.y + n * h.z
                    loc, hn, _, dist = bvh.ray_cast(c, d, 60.0)
                    if loc is None:
                        esc += 1
                    else:
                        hits += 1
                        if dist < 0.04:
                            near += 1
                        if dist < 0.6:
                            close += 1
                        if hn.dot(d) > 0:
                            back += 1
                # hidden: touching other geometry, in a shallow cavity (slab undersides), or inside a closed volume
                if near >= len(H) - 1 or close == len(H) or (hits >= 0.75 * len(H) and back >= 0.6 * hits):
                    ks.append('hidden')
                elif esc / len(H) >= 0.34:
                    ks.append('exterior')
                else:
                    ks.append('interior')
            vis = [x for x in ks if x != 'hidden']
            if not vis:
                k = 'hidden'
            elif vis.count('exterior') * 2 > len(vis):
                k = 'exterior'
            else:
                k = 'interior'
            stats[k] += a
            ws.append(fw[k] * (boost if k == 'interior' else 1.0))
        res[o.name] = ws
    log('face classes (m2)', {k: round(v, 1) for k, v in stats.items()})
    return res


def uv_overlap_ok(me, uvl, res=384):
    """True if an existing UV map is inside 0..1 and (almost) non-overlapping -> reusable as lightmap layout."""
    import numpy as np
    n = len(me.loops)
    if n == 0:
        return False
    uv = np.empty(n * 2, dtype=np.float32); uvl.data.foreach_get('uv', uv); uv = uv.reshape(-1, 2)
    if uv.min() < -0.002 or uv.max() > 1.002:
        return False
    cov = np.zeros((res, res), dtype=np.int32); tot = 0
    for p in me.polygons:
        li = range(p.loop_start, p.loop_start + p.loop_total)
        pts = uv[list(li)] * res
        for k in range(1, p.loop_total - 1):
            tri = np.array([pts[0], pts[k], pts[k + 1]])
            x0, y0 = np.floor(tri.min(0)).astype(int); x1, y1 = np.ceil(tri.max(0)).astype(int)
            x0 = max(x0, 0); y0 = max(y0, 0); x1 = min(x1, res); y1 = min(y1, res)
            if x1 <= x0 or y1 <= y0:
                continue
            xs, ys = np.meshgrid(np.arange(x0, x1) + 0.5, np.arange(y0, y1) + 0.5)
            (ax, ay), (bx, by), (cx, cy) = tri
            d = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
            if abs(d) < 1e-12:
                continue
            l1 = ((by - cy) * (xs - cx) + (cx - bx) * (ys - cy)) / d
            l2 = ((cy - ay) * (xs - cx) + (ax - cx) * (ys - cy)) / d
            m = (l1 >= 0) & (l2 >= 0) & (l1 + l2 <= 1)
            cov[y0:y1, x0:x1] += m
            tot += int(m.sum())
    if tot < res * res * 0.03:
        return False
    union = int((cov > 0).sum())
    return (tot - union) / tot < 0.02


def poly_uv_area(uvs):
    s = 0.0
    for i in range(len(uvs)):
        x0, y0 = uvs[i]; x1, y1 = uvs[(i + 1) % len(uvs)]
        s += x0 * y1 - x1 * y0
    return abs(s) * 0.5


def scale_islands(o, weights):
    from bpy_extras.bmesh_utils import bmesh_linked_uv_islands
    bm = bmesh.new(); bm.from_mesh(o.data)
    uvl = bm.loops.layers.uv[BAKE_UV]
    bm.faces.ensure_lookup_table()
    islands = bmesh_linked_uv_islands(bm, uvl)
    for isl in islands:
        a3 = 0.0; auv = 0.0; cx = cy = 0.0; nl = 0
        for f in isl:
            w = weights[f.index] if f.index < len(weights) else 1.0
            a3 += f.calc_area() * w * w
            uvs = [l[uvl].uv.copy() for l in f.loops]
            auv += poly_uv_area(uvs)
            for u in uvs:
                cx += u.x; cy += u.y; nl += 1
        if auv < 1e-14 or a3 < 1e-12:
            s = 1e-4
        else:
            s = math.sqrt(a3 / auv)
        cx /= max(nl, 1); cy /= max(nl, 1)
        for f in isl:
            for l in f.loops:
                u = l[uvl].uv
                u.x = (u.x - cx) * s; u.y = (u.y - cy) * s
    bm.to_mesh(o.data); bm.free()
    return len(islands)


def edit_objects(objs):
    bpy.ops.object.mode_set(mode='OBJECT') if bpy.context.object and bpy.context.object.mode != 'OBJECT' else None
    for o in bpy.context.scene.objects:
        o.select_set(False)
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.reveal()
    bpy.ops.mesh.select_all(action='SELECT')


def stage_uv(a, cfg):
    sc = bpy.context.scene
    sc.tool_settings.use_uv_select_sync = True
    objs = mesh_objects()
    kinds = {o.name: obj_kind(o, cfg) for o in objs}
    n_atl = cfg['atlas_count']
    has_alpha = any(k == 'alpha' for k in kinds.values())
    n_main = n_atl - 1 - (1 if has_alpha else 0)

    # 1) split very large 'main' objects so that atlases can be balanced and grouped by area
    main = [o for o in objs if kinds[o.name] == 'main']
    tot = sum(sum(p.area for p in o.data.polygons) for o in main)
    limit = 0.35 * tot / n_main
    queue = [(o, 0) for o in main]; n_cut = 0
    while queue:
        o, depth = queue.pop()
        area = sum(p.area for p in o.data.polygons)
        if area <= limit or len(o.data.polygons) < 2 or depth >= 6:
            continue
        # NB: o.bound_box is stale after a bmesh edit -> use the vertices (transforms are applied)
        import numpy as np
        co = np.empty(len(o.data.vertices) * 3, dtype=np.float64); o.data.vertices.foreach_get('co', co)
        co = co.reshape(-1, 3); mn = co.min(0); mx = co.max(0); ext = mx - mn
        ax = 0 if ext[0] >= ext[1] else 1
        new = bisect_object(o, ax, float(mn[ax] + mx[ax]) / 2)
        if new:
            kinds[new.name] = 'main'; queue += [(o, depth + 1), (new, depth + 1)]; n_cut += 1
            log('  split', o.name, '->', new.name, round(area, 1), 'm2')
    objs = mesh_objects()
    log('split large objects', n_cut, 'objects', len(objs))

    # 2) per-face texel weights (rays against everything except glass)
    bake_objs = [o for o in objs if kinds.get(o.name, obj_kind(o, cfg)) != 'glass']
    for o in objs:
        kinds.setdefault(o.name, obj_kind(o, cfg))
    weights = classify_faces([o for o in objs if kinds[o.name] != 'glass'], cfg)
    cw = cfg.get('context_weight', 0.2)
    for o in bake_objs:
        if kinds[o.name] == 'context':
            w = cw if not isinstance(cw, dict) else next((v for k, v in cw.items() if re.search(k, o.name)), 0.2)
            weights[o.name] = [w] * len(o.data.polygons)

    # 3) BakeUV: reuse a clean existing layout, else smart project
    smart = []; reused = 0
    for o in bake_objs:
        me = o.data
        if BAKE_UV in me.uv_layers:
            me.uv_layers.remove(me.uv_layers[BAKE_UV])
        if len(me.uv_layers) == 0:
            z = me.uv_layers.new(name='UVMap', do_init=False)   # keeps "no UV" materials identical (all zeros)
        orig = next(l for l in me.uv_layers if l.active_render)
        me.uv_layers.active = orig
        ok = len(me.polygons) >= 200 and uv_overlap_ok(me, orig)
        lay = me.uv_layers.new(name=BAKE_UV, do_init=True)
        for l in me.uv_layers:
            l.active_render = (l.name == orig.name)
        me.uv_layers.active = lay
        if ok:
            reused += 1
        else:
            smart.append(o)
    log('UV reuse', reused, 'smart project', len(smart))
    if smart:
        edit_objects(smart)
        bpy.ops.uv.smart_project(angle_limit=math.radians(60), margin_method='FRACTION', island_margin=0.0,
                                 area_weight=0.0, correct_aspect=True, scale_to_bounds=False)
        bpy.ops.object.mode_set(mode='OBJECT')
    n_isl = 0
    for o in bake_objs:
        n_isl += scale_islands(o, weights[o.name])
    log('islands', n_isl)

    # 4) atlas assignment
    W = {o.name: sum(p.area * w * w for p, w in zip(o.data.polygons, weights[o.name])) for o in bake_objs}
    main = [o for o in bake_objs if kinds[o.name] == 'main']

    def key(o):
        mn, mx = world_bbox([o]); c = (mn + mx) / 2
        return (int(c.y // 4.5), c.x, c.y)
    main.sort(key=key)
    tw = sum(W[o.name] for o in main); target = tw / n_main
    atl = {}; cum = 0.0
    for o in main:
        mid = cum + W[o.name] / 2
        atl[o.name] = min(n_main - 1, int(mid // target)); cum += W[o.name]
    ext_i = n_main; alpha_i = n_main + 1
    for o in bake_objs:
        if kinds[o.name] in ('ext', 'context'):
            atl[o.name] = ext_i
        elif kinds[o.name] == 'alpha':
            atl[o.name] = alpha_i
    size = cfg['atlas_size']
    atlases = []
    for i in range(n_main):
        atlases.append({'index': i, 'kind': 'main', 'size': size})
    atlases.append({'index': ext_i, 'kind': 'ext', 'size': size})
    if has_alpha:
        wa = sum(W[o.name] for o in bake_objs if atl[o.name] == alpha_i)
        atlases.append({'index': alpha_i, 'kind': 'alpha', 'size': 1024 if wa < 2 else 2048 if wa < 8 else size})
    for o in objs:
        if o.name in atl:
            o['qv_atlas'] = atl[o.name]
        elif 'qv_atlas' in o:
            del o['qv_atlas']
        o['qv_kind'] = kinds[o.name]

    # 5) pack each atlas
    for A in atlases:
        group = [o for o in bake_objs if atl[o.name] == A['index']]
        A['objects'] = len(group); A['weighted_m2'] = round(sum(W[o.name] for o in group), 1)
        if not group:
            continue
        t = time.time()
        edit_objects(group)
        margin = cfg.get('island_margin_px', 6) / A['size']
        bpy.ops.uv.pack_islands(udim_source='CLOSEST_UDIM', rotate=True, rotate_method='ANY', scale=True,
                                merge_overlap=False, margin_method='FRACTION', margin=margin,
                                shape_method=cfg.get('pack_shape', 'CONCAVE'))
        bpy.ops.object.mode_set(mode='OBJECT')
        # achieved density on full-weight faces
        uva = 0.0; wa = 0.0
        for o in group:
            me = o.data; uvl = me.uv_layers[BAKE_UV]; ws = weights[o.name]
            for p, w in zip(me.polygons, ws):
                if abs(w - 1.0) < 1e-6 and p.area > 0.01:
                    uvs = [uvl.data[li].uv for li in p.loop_indices]
                    uva += poly_uv_area(uvs); wa += p.area
        if wa > 0 and uva > 0:
            A['texel_mm'] = round(1000.0 / (math.sqrt(uva / wa) * A['size']), 2)
        else:   # ext/context: report the weight-scaled density
            uvt = sum(poly_uv_area([o.data.uv_layers[BAKE_UV].data[li].uv for li in p.loop_indices])
                      for o in group for p in o.data.polygons)
            at = sum(p.area * w * w for o in group for p, w in zip(o.data.polygons, weights[o.name]))
            A['texel_mm_weight1'] = round(1000.0 / (math.sqrt(uvt / at) * A['size']), 2) if uvt > 0 else None
        log('packed atlas', A, round(time.time() - t, 1), 's')
    sc['qv_atlases'] = json.dumps(atlases)
    bpy.ops.wm.save_mainfile(filepath=cfg['_work'], compress=False)
    with open(os.path.join(cfg['out_dir'], 'work', 'atlases.json'), 'w') as f:
        json.dump(atlases, f, indent=1)
    log('UV done', atlases)


# ----------------------------------------------------------------------------------------------- stage: bake
def load_atlases(sc):
    return json.loads(sc['qv_atlases'])


def atlas_objects(i):
    return [o for o in mesh_objects() if o.get('qv_atlas') == i]


def wanted(a, i):
    return a.atlas is None or str(i) in a.atlas.split(',')


def ensure_materials(objs):
    dm = bpy.data.materials.get('QV_Default')
    if dm is None:
        dm = bpy.data.materials.new('QV_Default')
        principled(dm).inputs['Base Color'].default_value = (0.6, 0.6, 0.6, 1)
    for o in objs:
        if len(o.material_slots) == 0:
            o.data.materials.append(dm)
        for s in o.material_slots:
            if s.material is None:
                s.material = dm


def set_bake_target(objs, img):
    for m in {s.material for o in objs for s in o.material_slots if s.material}:
        nt = m.node_tree
        n = nt.nodes.get('QV_BAKE_TARGET') or nt.nodes.new('ShaderNodeTexImage')
        n.name = 'QV_BAKE_TARGET'; n.image = img
        for x in nt.nodes:
            x.select = False
        n.select = True; nt.nodes.active = n


def select_only(objs):
    for o in bpy.context.scene.objects:
        o.select_set(False)
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]


def new_float_image(name, size):
    old = bpy.data.images.get(name)
    if old:
        bpy.data.images.remove(old)
    img = bpy.data.images.new(name, size, size, alpha=True, float_buffer=True)
    img.generated_color = (0, 0, 0, 0)
    return img


def save_exr(img, path):
    img.filepath_raw = path
    img.file_format = 'OPEN_EXR'
    img.save()


def bake_one(type_, passes, objs, img, cfg):
    set_bake_target(objs, img)
    select_only(objs)
    kw = dict(type=type_, margin=cfg['bake']['margin_px'], margin_type='EXTEND', use_clear=False,
              target='IMAGE_TEXTURES', uv_layer=BAKE_UV, use_selected_to_active=False)
    if passes is not None:
        kw['pass_filter'] = passes
    bpy.ops.object.bake(**kw)


def bake_alpha_mask(objs, img, cfg):
    """EMIT bake of each alpha material's alpha source (cut-out mask)."""
    saved = []
    for m in {s.material for o in objs for s in o.material_slots if s.material}:
        nt = m.node_tree; b = principled(m)
        out = next((n for n in nt.nodes if n.type == 'OUTPUT_MATERIAL' and n.is_active_output), None) or \
            next(n for n in nt.nodes if n.type == 'OUTPUT_MATERIAL')
        prev = out.inputs['Surface'].links[0].from_socket if out.inputs['Surface'].is_linked else None
        em = nt.nodes.new('ShaderNodeEmission'); em.name = 'QV_MASK'
        if b and b.inputs['Alpha'].is_linked:
            nt.links.new(b.inputs['Alpha'].links[0].from_socket, em.inputs['Color'])
        else:
            v = b.inputs['Alpha'].default_value if b else 1.0
            em.inputs['Color'].default_value = (v, v, v, 1)
        nt.links.new(em.outputs[0], out.inputs['Surface'])
        saved.append((m, out, prev, em))
    try:
        bake_one('EMIT', None, objs, img, cfg)
    finally:
        for m, out, prev, em in saved:
            nt = m.node_tree
            nt.nodes.remove(em)
            if prev is not None:
                nt.links.new(prev, out.inputs['Surface'])


def stage_bake(a, cfg):
    sc = bpy.context.scene
    setup_gpu(sc)
    setup_lighting(sc, cfg)          # always bake with the CURRENT config sun/sky
    cy = sc.cycles
    cy.use_denoising = False
    try:
        cy.use_auto_tile = True; cy.tile_size = cfg['bake'].get('tile', 2048)
    except Exception:
        pass
    ensure_materials(mesh_objects())
    timing = {}
    tpath = os.path.join(cfg['_bakedir'], 'timing.json')
    if os.path.exists(tpath):
        timing = json.load(open(tpath))
    for A in load_atlases(sc):
        i = A['index']
        if not wanted(a, i):
            continue
        objs = atlas_objects(i)
        if not objs:
            continue
        comb = os.path.join(cfg['_bakedir'], 'atlas%d_combined.exr' % i)
        if os.path.exists(comb) and not a.force:
            log('skip existing', comb); continue
        size = A['size']; t = time.time()
        img = new_float_image('QV_bake_%d' % i, size)
        cy.samples = a.samples or cfg['bake']['samples']
        bake_one('COMBINED', {'EMIT', 'DIRECT', 'INDIRECT', 'DIFFUSE', 'TRANSMISSION'}, objs, img, cfg)
        tb = time.time() - t
        alb = new_float_image('QV_albedo_%d' % i, size)
        cy.samples = cfg['bake']['albedo_samples']
        bake_one('DIFFUSE', {'COLOR'}, objs, alb, cfg)
        save_exr(alb, os.path.join(cfg['_bakedir'], 'atlas%d_albedo.exr' % i))
        if A['kind'] == 'alpha':
            msk = new_float_image('QV_mask_%d' % i, size)
            cy.samples = 16
            bake_alpha_mask(objs, msk, cfg)
            save_exr(msk, os.path.join(cfg['_bakedir'], 'atlas%d_mask.exr' % i))
        save_exr(img, comb)    # last: its existence marks the atlas as done
        timing[str(i)] = {'combined_s': round(tb, 1), 'total_s': round(time.time() - t, 1), 'samples': a.samples or cfg['bake']['samples'], 'objects': len(objs)}
        json.dump(timing, open(tpath, 'w'), indent=1)
        log('BAKED atlas', i, timing[str(i)])
        for im in list(bpy.data.images):
            if im.name.startswith('QV_'):
                bpy.data.images.remove(im)


# ----------------------------------------------------------------------------------------------- stage: post
def img_to_np(img):
    import numpy as np
    w, h = img.size
    a = np.empty(w * h * 4, dtype=np.float32); img.pixels.foreach_get(a)
    return a.reshape(h, w, 4)


def np_to_img(arr, name):
    h, w = arr.shape[:2]
    old = bpy.data.images.get(name)
    if old:
        bpy.data.images.remove(old)
    img = bpy.data.images.new(name, w, h, alpha=True, float_buffer=True)
    img.pixels.foreach_set(arr.astype('float32').ravel())
    return img


def push_pull(c, m):
    """Fill pixels where m is False from coarser mask-weighted averages (no black bleed into mips)."""
    import numpy as np
    H, W = m.shape
    if m.all() or H < 2 or W < 2:
        if not m.any():
            return c
        return np.where(m[..., None], c, c[m].mean(0))
    cw = c * m[..., None]
    c2 = cw.reshape(H // 2, 2, W // 2, 2, -1).sum((1, 3))
    m2 = m.reshape(H // 2, 2, W // 2, 2).sum((1, 3))
    c2 = c2 / np.maximum(m2, 1)[..., None]
    c2 = push_pull(c2, m2 > 0)
    up = np.repeat(np.repeat(c2, 2, 0), 2, 1)
    return np.where(m[..., None], c, up)


def post_scene(cfg, size):
    sc = bpy.data.scenes.get('QV_post') or bpy.data.scenes.new('QV_post')
    sc.render.resolution_x = size; sc.render.resolution_y = size; sc.render.resolution_percentage = 100
    if not sc.camera:
        cd = bpy.data.cameras.new('QV_post_cam'); co = bpy.data.objects.new('QV_post_cam', cd)
        sc.collection.objects.link(co); sc.camera = co
    try:
        sc.render.engine = 'BLENDER_WORKBENCH'
    except TypeError:
        pass
    vs = sc.view_settings
    vs.view_transform = cfg['view']['transform']
    try:
        vs.look = cfg['view']['look']
    except Exception:
        pass
    vs.exposure = cfg['view']['exposure']; vs.gamma = 1.0
    return sc


def oidn(sc, color, albedo):
    nt = bpy.data.node_groups.get('QV_denoise')
    if nt:
        bpy.data.node_groups.remove(nt)
    nt = bpy.data.node_groups.new('QV_denoise', 'CompositorNodeTree')
    nt.interface.new_socket('Image', in_out='OUTPUT', socket_type='NodeSocketColor')
    i1 = nt.nodes.new('CompositorNodeImage'); i1.image = color
    i2 = nt.nodes.new('CompositorNodeImage'); i2.image = albedo
    dn = nt.nodes.new('CompositorNodeDenoise')
    dn.inputs['HDR'].default_value = True
    for sock, want in (('Prefilter', 'Accurate'), ('Quality', 'High')):
        try:
            dn.inputs[sock].default_value = want
        except Exception as ex:
            log('denoise option', sock, ex)
    out = nt.nodes.new('NodeGroupOutput')
    nt.links.new(i1.outputs['Image'], dn.inputs['Image'])
    nt.links.new(i2.outputs['Image'], dn.inputs['Albedo'])
    nt.links.new(dn.outputs['Image'], out.inputs[0])
    sc.compositing_node_group = nt
    sc.render.use_compositing = True
    bpy.ops.render.render(scene=sc.name)
    return bpy.data.images['Render Result']


def stage_post(a, cfg):
    import numpy as np
    sc0 = bpy.context.scene
    atlases = load_atlases(sc0)
    q = cfg['export'].get('jpeg_quality', 90)
    expo = a.exposure if a.exposure is not None else cfg['view']['exposure']
    for A in atlases:
        i = A['index']
        if not wanted(a, i):
            continue
        comb = os.path.join(cfg['_bakedir'], 'atlas%d_combined.exr' % i)
        if not os.path.exists(comb):
            log('not baked yet', i); continue
        den_path = os.path.join(cfg['_bakedir'], 'atlas%d_denoised.exr' % i)
        size = A['size']; sc = post_scene(cfg, size); sc.view_settings.exposure = expo
        t = time.time()
        if a.force or not os.path.exists(den_path):
            raw = bpy.data.images.load(comb); al = bpy.data.images.load(os.path.join(cfg['_bakedir'], 'atlas%d_albedo.exr' % i))
            c = img_to_np(raw); b = img_to_np(al)
            m = c[..., 3] > 0.5
            np.save(os.path.join(cfg['_bakedir'], 'atlas%d_cover.npy' % i), np.packbits(m))
            c[..., :3] = push_pull(c[..., :3], m); c[..., 3] = 1
            b[..., :3] = push_pull(b[..., :3], m); b[..., 3] = 1
            ci = np_to_img(c, 'QV_c'); bi = np_to_img(b, 'QV_b')
            rr = oidn(sc, ci, bi)
            sc.render.image_settings.file_format = 'OPEN_EXR'; sc.render.image_settings.color_depth = '16'
            sc.render.image_settings.color_mode = 'RGB'
            rr.save_render(den_path, scene=sc)
            for im in (raw, al, ci, bi):
                bpy.data.images.remove(im)
            log('denoised', i, round(time.time() - t, 1), 's')
        den = bpy.data.images.load(den_path)
        alpha = A['kind'] == 'alpha'
        fmt = 'PNG' if alpha else 'JPEG'
        outp = os.path.join(cfg['_atlasdir'], '%s_atlas%d.%s' % (cfg['name'], i, 'png' if alpha else 'jpg'))
        ims = sc.render.image_settings
        ims.file_format = fmt; ims.color_mode = 'RGB'; ims.color_depth = '8'
        if fmt == 'JPEG':
            ims.quality = q
        else:
            ims.compression = 15
        den.save_render(outp, scene=sc)        # applies the scene view transform (AgX + look + exposure)
        bpy.data.images.remove(den)
        if alpha:
            mk = bpy.data.images.load(os.path.join(cfg['_bakedir'], 'atlas%d_mask.exr' % i))
            mm = img_to_np(mk)[..., 0]
            cov = np.unpackbits(np.load(os.path.join(cfg['_bakedir'], 'atlas%d_cover.npy' % i)))[:mm.size].reshape(mm.shape).astype(bool)
            mm = np.where(cov, mm, 0.0)
            # dilate the mask's colour is already filled; alpha stays exact
            ti = bpy.data.images.load(outp); px = img_to_np(ti)
            px[..., 3] = np.clip(mm, 0, 1)
            oi = np_to_img(px, 'QV_out'); oi.alpha_mode = 'STRAIGHT'
            oi.filepath_raw = outp; oi.file_format = 'PNG'
            oi.colorspace_settings.name = 'sRGB' if False else oi.colorspace_settings.name
            # pixels are already display values -> write them untouched
            oi.colorspace_settings.is_data = True
            oi.save()
            for im in (mk, ti, oi):
                bpy.data.images.remove(im)
        log('POST atlas', i, outp, round(time.time() - t, 1), 's')


# ----------------------------------------------------------------------------------------------- stage: export
def blender_to_usd(v):
    """Blender Z-up -> USD Y-up (forward -Z): (x, y, z) -> (x, z, -y)."""
    return [v[0], v[2], -v[1]]


def sidecar_viewpoints(cfg):
    """Optional `viewpoints` config list -> sidecar entries (USD coords, floor level).
    Each config entry: {"name", "position_blender": [x, y, floor_z], "look_at_blender": [x, y]}."""
    out = []
    for v in cfg.get('viewpoints', []):
        p = v['position_blender']; t = v['look_at_blender']
        yaw = math.degrees(math.atan2(-(t[0] - p[0]), t[1] - p[1]))
        out.append({'name': v['name'],
                    'position': [round(c, 3) for c in blender_to_usd([p[0], p[1], p[2] if len(p) > 2 else 0.0])],
                    'yawDegrees': round(yaw, 1) + 0.0})
    return out


def floor_at(sc, x, y, z0=2.2):
    dg = bpy.context.evaluated_depsgraph_get()
    hit, loc, nrm, idx, ob, _ = sc.ray_cast(dg, Vector((x, y, z0)), Vector((0, 0, -1)), distance=10)
    return (loc.z, ob.name if ob else None) if hit else (0.0, None)


def clearance(sc, p, heights=(0.3, 1.0, 1.6), n=16):
    dg = bpy.context.evaluated_depsgraph_get(); best = 1e9
    for h in heights:
        for k in range(n):
            a = 2 * math.pi * k / n
            hit, loc, *_ = sc.ray_cast(dg, Vector((p.x, p.y, p.z + h)), Vector((math.cos(a), math.sin(a), 0)), distance=20)
            if hit:
                best = min(best, (loc - Vector((p.x, p.y, p.z + h))).length)
    return best


def start_info(sc, cfg):
    st = cfg['start']
    x, y = st['position_blender'][:2]
    z, ob = floor_at(sc, x, y)
    p = Vector((x, y, z))
    tx, ty = st['look_at_blender'][:2]
    dx, dy = tx - x, ty - y
    yaw = math.degrees(math.atan2(-dx, dy))       # 0 = looking along USD -Z (= Blender +Y), CCW about +Y
    return p, ob, yaw


def stage_export(a, cfg):
    sc = bpy.context.scene
    atlases = load_atlases(sc)
    name = cfg['name']; out = cfg['out_dir']
    # start position (before anything is joined/removed)
    p, floor_obj, yaw = start_info(sc, cfg)
    clr = clearance(sc, p)
    log('start', tuple(round(v, 3) for v in p), 'floor', floor_obj, 'yaw', round(yaw, 1), 'clearance', round(clr, 2))
    for o in list(sc.objects):
        if o.type != 'MESH':
            bpy.data.objects.remove(o, do_unlink=True)
    mats = {}
    for A in atlases:
        i = A['index']; alpha = A['kind'] == 'alpha'
        path = os.path.join(cfg['_atlasdir'], '%s_atlas%d.%s' % (name, i, 'png' if alpha else 'jpg'))
        if not os.path.exists(path):
            raise SystemExit('missing atlas ' + path)
        img = bpy.data.images.load(path); img.colorspace_settings.name = 'sRGB'
        img.name = os.path.basename(path)
        for variant, op in (('', None), ('_Sheer', 'sheer')):
            m = bpy.data.materials.new('QV_Atlas%d%s' % (i, variant))
            nt = m.node_tree; b = principled(m)
            t = nt.nodes.new('ShaderNodeTexImage'); t.image = img
            nt.links.new(t.outputs['Color'], b.inputs['Base Color'])
            b.inputs['Roughness'].default_value = 1.0; b.inputs['Metallic'].default_value = 0.0
            b.inputs['Specular IOR Level'].default_value = 0.0
            if alpha:
                nt.links.new(t.outputs['Alpha'], b.inputs['Alpha'])
            mats[(i, variant)] = m
    glass_mats = {}
    for gname, (r, g, bb, op) in cfg.get('glass_tint', {}).items():
        m = bpy.data.materials.new('QV_Glass' if gname == 'Glass' else 'QV_Glass_' + gname)
        b = principled(m)
        b.inputs['Base Color'].default_value = (r, g, bb, 1); b.inputs['Alpha'].default_value = op
        b.inputs['Roughness'].default_value = 0.05; b.inputs['Specular IOR Level'].default_value = 0.0
        glass_mats[gname] = m
    trans = cfg.get('translucent_materials', {})
    groups = {}
    for o in mesh_objects():
        me = o.data
        names = [s.material.name if s.material else '' for s in o.material_slots]
        if o.get('qv_kind') == 'glass' or (o.material_slots and all(mat_class(s_.material, cfg) == 'glass' for s_ in o.material_slots)):
            gm = next((glass_mats[k] for k in glass_mats if any(re.search('^' + k + '$', n) for n in names)), None) \
                or glass_mats.get('Glass')
            key = gm.name; mat = gm
            for l in list(me.uv_layers):
                me.uv_layers.remove(l)
        else:
            if 'qv_atlas' not in o:
                log('WARNING no atlas, dropped', o.name); bpy.data.objects.remove(o, do_unlink=True); continue
            i = o['qv_atlas']
            sheer = [trans[n] for n in names if n in trans]
            if sheer:
                mat = mats[(i, '_Sheer')]; principled(mat).inputs['Alpha'].default_value = min(sheer)
            else:
                mat = mats[(i, '')]
            key = mat.name
            for l in [l for l in me.uv_layers if l.name != BAKE_UV]:
                me.uv_layers.remove(l)
            me.uv_layers[BAKE_UV].name = 'st'
            me.uv_layers['st'].active = True; me.uv_layers['st'].active_render = True
        me.materials.clear(); me.materials.append(mat)
        for k in list(o.keys()):
            del o[k]
        groups.setdefault(key, []).append(o)
    # one mesh per material (fewer entities / draw calls on the headset)
    for key, objs in groups.items():
        select_only(objs)
        if len(objs) > 1:
            bpy.ops.object.join()
        j = bpy.context.view_layer.objects.active
        j.name = key.replace('QV_', ''); j.data.name = j.name
    for m in list(bpy.data.materials):
        if m.users == 0:
            bpy.data.materials.remove(m)
    objs = mesh_objects()
    tris = tri_count(objs)
    log('export meshes', [(o.name, len(o.data.polygons)) for o in objs], 'triangles', tris)
    usdz = os.path.join(out, name + '.usdz')
    for o in objs:
        o.select_set(True)
    # 1) plain USD + textures folder, 2) author opacity values the exporter leaves at 1, 3) package as USDZ
    stage_dir = os.path.join(out, 'work', 'usd'); os.makedirs(stage_dir, exist_ok=True)
    usdc = os.path.join(stage_dir, name + '.usdc')
    bpy.ops.wm.usd_export(filepath=usdc, selected_objects_only=False, export_animation=False, export_hair=False,
                          export_uvmaps=True, rename_uvmaps=True, export_mesh_colors=False, export_normals=False,
                          export_materials=True, generate_preview_surface=True, generate_materialx_network=False,
                          export_textures_mode='NEW', overwrite_textures=True, relative_paths=True, use_instancing=False,
                          evaluation_mode='RENDER', convert_orientation=True,
                          export_global_forward_selection='NEGATIVE_Z', export_global_up_selection='Y',
                          export_lights=False, export_cameras=False, convert_world_material=False,
                          triangulate_meshes=True, root_prim_path='/root',
                          convert_scene_units='METERS', export_custom_properties=False)
    opac = {m.name: principled(m).inputs['Alpha'].default_value for m in bpy.data.materials
            if principled(m) and not principled(m).inputs['Alpha'].is_linked and principled(m).inputs['Alpha'].default_value < 0.999}
    cut = [m.name for m in bpy.data.materials if principled(m) and principled(m).inputs['Alpha'].is_linked]
    from pxr import Usd, UsdShade, UsdGeom, UsdUtils, Sdf
    st = Usd.Stage.Open(usdc)
    for prim in st.Traverse():
        if prim.IsA(UsdShade.Material):
            mname = prim.GetName()
            for ch in Usd.PrimRange(prim):
                sh = UsdShade.Shader(ch)
                if not sh or sh.GetIdAttr().Get() != 'UsdPreviewSurface':
                    continue
                if mname in opac:
                    sh.CreateInput('opacity', Sdf.ValueTypeNames.Float).Set(float(opac[mname]))
                if mname in cut:
                    sh.CreateInput('opacityThreshold', Sdf.ValueTypeNames.Float).Set(0.5)
                sh.CreateInput('metallic', Sdf.ValueTypeNames.Float).Set(0.0)
                log('usd material', mname, 'opacity', opac.get(mname, 'tex' if mname in cut else 1.0))
        if prim.IsA(UsdGeom.Mesh):
            pv = UsdGeom.PrimvarsAPI(prim)
            for nm in ('Color', 'displayColor', 'displayOpacity'):
                if pv.HasPrimvar(nm):
                    pv.RemovePrimvar(nm)
    st.GetRootLayer().Save()
    if os.path.exists(usdz):
        os.remove(usdz)
    ok = UsdUtils.CreateNewUsdzPackage(Sdf.AssetPath(usdc), usdz)
    if not ok:
        raise SystemExit('USDZ packaging failed')
    size = os.path.getsize(usdz)
    log('USDZ', usdz, round(size / 1e6, 1), 'MB')
    pos = blender_to_usd(p)
    side = {
        'title': cfg['title'], 'version': 1,
        'start': {'position': [round(v, 3) for v in pos], 'yawDegrees': round(yaw, 1) + 0.0},
        'eyeHeightIncluded': False,
        'hasSky': bool(cfg.get('has_sky', False)),
        'viewpoints': sidecar_viewpoints(cfg),
        'notes': ('baked with Blender %s Cycles: COMBINED diffuse+transmission+emission (no glossy), %d samples + OIDN; '
                  'AgX "%s", exposure %+.2f; sun elevation %.1f deg, azimuth %.1f deg (from scene +Y towards +X); '
                  'yawDegrees: rotation about +Y (counter-clockwise seen from above), 0 = facing -Z. '
                  'Materials are display-referred sRGB: show them UNLIT. Glass materials are named "*Glass*" and carry opacity.')
                 % (bpy.app.version_string, cfg['bake']['samples'], cfg['view']['look'], cfg['view']['exposure'],
                    cfg['sun']['elevation'], cfg['sun']['azimuth']),
    }
    with open(os.path.join(out, name + '.json'), 'w', encoding='utf-8') as f:
        json.dump(side, f, indent=2)
    stats = {'triangles': tris, 'usdz_bytes': size, 'start_blender': list(p), 'start_floor_object': floor_obj,
             'start_clearance_m': clr, 'atlases': atlases}
    with open(os.path.join(out, 'work', 'export_stats.json'), 'w') as f:
        json.dump(stats, f, indent=1)
    log('sidecar', side)


# ----------------------------------------------------------------------------------------------- stage: verify
def stage_verify(a, cfg):
    import numpy as np
    name = cfg['name']; out = cfg['out_dir']
    usdz = os.path.join(out, name + '.usdz')
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    bpy.ops.wm.usd_import(filepath=usdz, import_lights=False, import_cameras=False)
    objs = [o for o in sc.objects if o.type == 'MESH']
    mn, mx = world_bbox(objs)
    log('imported', len(objs), 'meshes, tris', tri_count(objs), 'bbox', tuple(round(v, 2) for v in mn), tuple(round(v, 2) for v in mx))
    # headset look: every material emission-only (texture colour == displayed colour), opacity kept
    for m in bpy.data.materials:
        if not m.node_tree:
            continue
        nt = m.node_tree; b = principled(m)
        tex = next((n for n in nt.nodes if n.type == 'TEX_IMAGE' and n.image), None)
        col = b.inputs['Base Color'].default_value[:] if b else (1, 1, 1, 1)
        alpha_link = b.inputs['Alpha'].links[0].from_socket if b and b.inputs['Alpha'].is_linked else None
        alpha_val = b.inputs['Alpha'].default_value if b else 1.0
        if b and not alpha_link and b.inputs['Transmission Weight'].default_value > 0.001:
            # Blender's USD importer turns a constant opacity into Transmission = 1 - opacity
            alpha_val = min(alpha_val, 1.0 - b.inputs['Transmission Weight'].default_value)
        for n in list(nt.nodes):
            if n != tex and n.type not in ('UVMAP', 'TEX_COORD') and not (alpha_link and n == alpha_link.node):
                nt.nodes.remove(n)
        em = nt.nodes.new('ShaderNodeEmission'); outn = nt.nodes.new('ShaderNodeOutputMaterial')
        if tex:
            nt.links.new(tex.outputs['Color'], em.inputs['Color'])
        else:
            em.inputs['Color'].default_value = col
        last = em.outputs[0]
        if alpha_link is not None or alpha_val < 0.999:
            tr = nt.nodes.new('ShaderNodeBsdfTransparent'); mix = nt.nodes.new('ShaderNodeMixShader')
            if alpha_link is not None:
                nt.links.new(alpha_link, mix.inputs['Fac'])
            else:
                mix.inputs['Fac'].default_value = alpha_val
            nt.links.new(tr.outputs[0], mix.inputs[1]); nt.links.new(em.outputs[0], mix.inputs[2]); last = mix.outputs[0]
        nt.links.new(last, outn.inputs['Surface'])
    w = bpy.data.worlds.new('W'); sc.world = w
    bg = next(n for n in w.node_tree.nodes if n.type == 'BACKGROUND')
    bg.inputs['Color'].default_value = (0.42, 0.62, 0.92, 1)        # stand-in for the app's sky dome
    setup_gpu(sc)
    sc.cycles.samples = a.samples or 24; sc.cycles.use_denoising = False
    sc.cycles.max_bounces = 0; sc.cycles.transparent_max_bounces = 16
    sc.view_settings.view_transform = 'Standard'; sc.view_settings.look = 'None'; sc.view_settings.exposure = 0
    W = a.res or 1280; H = int(W * 0.625)
    sc.render.resolution_x = W; sc.render.resolution_y = H; sc.render.resolution_percentage = 100
    sc.render.image_settings.file_format = 'JPEG'; sc.render.image_settings.quality = 90
    # start view (from the sidecar, converted back: USD (x, y, z) -> Blender (x, -z, y))
    side = json.load(open(os.path.join(out, name + '.json')))
    sp = side['start']['position']; yaw = math.radians(side['start']['yawDegrees'])
    start_b = Vector((sp[0], -sp[2], sp[1]))
    fwd = Vector((-math.sin(yaw), math.cos(yaw), 0))
    views = [{'name': '00_start', 'pos': list(start_b + Vector((0, 0, 1.6))), 'target': list(start_b + fwd * 4 + Vector((0, 0, 1.4))), 'lens': 18}]
    views += cfg['preview_views']
    files = []
    cd = bpy.data.cameras.new('cam'); cam = bpy.data.objects.new('cam', cd); sc.collection.objects.link(cam); sc.camera = cam
    cd.sensor_width = 36; cd.clip_start = 0.05; cd.clip_end = 500
    for v in views:
        cd.lens = v.get('lens', 18)
        cam.location = v['pos']
        d = Vector(v['target']) - Vector(v['pos'])
        cam.rotation_euler = d.to_track_quat('-Z', 'Y').to_euler()
        f = os.path.join(cfg['_previews'], v['name'] + '.jpg'); sc.render.filepath = f
        bpy.ops.render.render(write_still=True); files.append(f)
        log('preview', f)
    # thumbnail (<= 512 px) from the start view
    cd.lens = 18; cam.location = views[0]['pos']
    cam.rotation_euler = (Vector(views[0]['target']) - Vector(views[0]['pos'])).to_track_quat('-Z', 'Y').to_euler()
    sc.render.resolution_x = 512; sc.render.resolution_y = 320
    sc.render.filepath = os.path.join(out, name + '.jpg'); bpy.ops.render.render(write_still=True)
    # contact sheet
    tiles = []
    for f in files:
        im = bpy.data.images.load(f); px = img_to_np(im)[..., :3]
        tiles.append(px[::2, ::2]); bpy.data.images.remove(im)
    th, tw = tiles[0].shape[:2]; cols = 4; rows = (len(tiles) + cols - 1) // cols
    sheet = np.zeros((rows * th, cols * tw, 4), dtype=np.float32); sheet[..., 3] = 1
    for k, t in enumerate(tiles):
        r = rows - 1 - k // cols; c = k % cols          # Blender images are bottom-up
        sheet[r * th:(r + 1) * th, c * tw:(c + 1) * tw, :3] = t
    si = bpy.data.images.new('sheet', cols * tw, rows * th, alpha=True)
    si.pixels.foreach_set(sheet.ravel())
    si.filepath_raw = os.path.join(cfg['_previews'], 'sheet.jpg'); si.file_format = 'JPEG'
    sc.render.image_settings.quality = 88
    si.save()
    log('sheet', si.filepath_raw)


# ----------------------------------------------------------------------------------------------- main
STAGES = {}


def main():
    a, cfg = parse()
    fn = STAGES.get(a.stage) or globals().get('stage_' + a.stage)
    if not fn:
        raise SystemExit('unknown stage ' + a.stage)
    # each stage opens the file it needs, so the wrapper only passes the config
    cur = os.path.normcase(os.path.abspath(bpy.data.filepath)) if bpy.data.filepath else ''
    if a.stage == 'prep':
        if cur != os.path.normcase(os.path.abspath(cfg['src'])):
            bpy.ops.wm.open_mainfile(filepath=cfg['src'], load_ui=False)
    elif a.stage != 'verify':
        if cur != os.path.normcase(os.path.abspath(cfg['_work'])):
            bpy.ops.wm.open_mainfile(filepath=cfg['_work'], load_ui=False)
    fn(a, cfg)
    log('DONE', a.stage)


if __name__ == '__main__':
    main()
