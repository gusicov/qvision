# QVision "Environments" (docs/v0.10-ENVIRONMENTS.md, E1/E2): one baked, unlit package per room, built for a
# viewing area (a ~1.5 m circle on the floor) like Apple's WWDC24 custom-environment workflow.
#
#   blender -b --python-exit-code 1 --python qv_env.py -- <stage> --config <scene.json> [--room 01] [...]
#
# Stages (env_prep once; the rest per room):
#   env_prep    open the SOURCE blend, save <work>/<Group>_base.blend, clean it (qv_bake prep) keeping the blend's
#               own lighting, world, view transform and materials (keep_lighting, bake.glossy)
#   env_vis     viewing area from the room camera; ~64 eye points; ID-coded equirect renders give, per face,
#               "seen?" + nearest distance + best viewing angle. Unseen objects/faces and far objects are dropped
#               (far ones live in the panorama); per-face texel target = max(1 mm, 0.5 mm per metre)
#   env_uv      lightmap UVs ("BakeUV") with those densities, <= max_atlases x 4096, packed
#   env_bake    Cycles COMBINED incl. GLOSSY with "View From: Active Camera" = the viewing-area centre at eye height
#               (reflections correct from the centre), + albedo + alpha mask (qv_bake stage_bake)
#   env_post    OIDN + the blend's own view transform / look / exposure (qv_bake stage_post)
#   env_pano    8K equirect from the centre with every kept object invisible to camera rays -> far field
#               (garden, trees, HDRI, neighbours) as seen from the room, fully lit by the whole scene
#   env_export  USDZ: baked meshes + an inside-out panorama sphere (unlit), sidecar with kind "environment"
#   env_verify  unlit previews (headset look) from the reference camera, side by side with the reference render

import bpy, bmesh, os, sys, re, json, math, time, argparse, types
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qv_bake as Q  # noqa: E402

log = Q.log


def safe(s):
    return re.sub(r'_+', '_', re.sub(r'[^A-Za-z0-9]+', '_', s)).strip('_')


# ----------------------------------------------------------------------------------------------- config / paths
def parse():
    argv = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
    p = argparse.ArgumentParser()
    p.add_argument('stage')
    p.add_argument('--config', required=True)
    p.add_argument('--room', default=None, help="room id, e.g. 01")
    p.add_argument('--atlas', default=None)
    p.add_argument('--samples', type=int, default=None)
    p.add_argument('--res', type=int, default=None)
    p.add_argument('--exposure', type=float, default=None)
    p.add_argument('--force', action='store_true')
    a = p.parse_args(argv)
    with open(a.config, encoding='utf-8') as f:
        cfg = json.load(f)
    return a, cfg


def env_defaults(cfg):
    E = dict(radius_m=1.5, eye_points=64, eye_height_min=1.2, eye_height_max=1.8, eye_height_center=1.6,
             vis_res=4096, far_m=12.0, texel_near_mm=1.0, texel_per_m_mm=0.5, unseen_texel_mm=40.0,
             drop_unseen_area_m2=0.02, max_atlases=12, max_triangles=800000, pano_size=8192, pano_samples=256,
             sphere_radius_m=500.0, pano_collections=[], atlas_fill=0.5, dice_area_m2=2.0, dice_m=1.0,
             far_texel_mm=25.0, density_bin=1.41, decimate_from_m=5.0, decimate_min_faces=3000)
    E.update(cfg.get('env', {}))
    return E


def paths(cfg, room=None):
    out = cfg['out_dir']
    work = os.path.join(out, cfg.get('work_subdir', 'work_env'))
    P = {'work': work, 'base': os.path.join(work, safe(cfg['group']) + '_base.blend'),
         'previews': os.path.join(out, 'previews_env')}
    if room:
        rid = '%s_%s' % (room['id'], safe(room['title']))
        rd = os.path.join(work, rid)
        P.update(rid=rid, room_dir=rd, blend=os.path.join(rd, rid + '.blend'), info=os.path.join(rd, 'room.json'),
                 pano=os.path.join(rd, 'pano.jpg'), name=safe(cfg['group']) + '_' + rid)
    for d in [v for k, v in P.items() if k in ('work', 'previews', 'room_dir')]:
        os.makedirs(d, exist_ok=True)
    return P


def get_room(cfg, rid):
    r = next((r for r in cfg['rooms'] if r['id'] == rid), None)
    if r is None:
        raise SystemExit('unknown room %s' % rid)
    return r


def room_cfg(cfg, room):
    """A qv_bake-style config for one room (its own work blend, bake and atlas folders, package name)."""
    P = paths(cfg, room)
    c = json.loads(json.dumps(cfg))
    c['env'] = env_defaults(cfg); c['env'].update(room.get('env', {}))
    c['_work'] = P['blend']
    c['_bakedir'] = os.path.join(P['room_dir'], 'bake')
    c['_atlasdir'] = os.path.join(P['room_dir'], 'atlas')
    c['_previews'] = P['previews']
    c['name'] = P['name']
    for d in (c['_bakedir'], c['_atlasdir']):
        os.makedirs(d, exist_ok=True)
    return c, P


def qargs(a):
    return types.SimpleNamespace(atlas=a.atlas, samples=a.samples, force=a.force, exposure=a.exposure, res=a.res,
                                 stage=a.stage, sun=None, cams='', tag='')


# ----------------------------------------------------------------------------------------------- env_prep
def stage_env_prep(a, cfg):
    P = paths(cfg)
    sc = bpy.context.scene
    vl_name = cfg.get('view_layer')
    if vl_name and vl_name in sc.view_layers:
        for w in bpy.context.window_manager.windows:
            w.view_layer = sc.view_layers[vl_name]
    sc.frame_set(cfg.get('frame', sc.frame_current))
    c = dict(cfg); c['_work'] = P['base']
    Q.stage_prep(a, c)        # saves the base copy FIRST, then cleans it (keep_lighting / bake.glossy honoured)


# ----------------------------------------------------------------------------------------------- env_vis
def unbind_marker_cameras(sc):
    """Timeline markers bound to cameras switch scene.camera at render time: our pano/visibility/bake cameras
    would silently be replaced by the reference camera of the current frame."""
    n = 0
    for m in sc.timeline_markers:
        if m.camera is not None:
            m.camera = None; n += 1
    if n:
        log('unbound', n, 'marker cameras')


def ray(sc, origin, direction, dist):
    dg = bpy.context.evaluated_depsgraph_get()
    hit, loc, nrm, idx, ob, _ = sc.ray_cast(dg, origin, direction, distance=dist)
    return (loc, ob) if hit else (None, None)


def viewing_area(sc, room, E):
    cam = bpy.data.objects[room['camera']]
    m = cam.matrix_world
    pos = m.translation.copy()
    fwd = (m.to_quaternion() @ Vector((0, 0, -1)))
    cxy = room.get('center_xy') or [pos.x, pos.y]
    loc, ob = ray(sc, Vector((cxy[0], cxy[1], pos.z)), Vector((0, 0, -1)), 50)
    floor = loc.z if loc is not None else pos.z - 1.5
    center = Vector((cxy[0], cxy[1], floor))
    eye_c = center + Vector((0, 0, E['eye_height_center']))
    yaw_vec = Vector((fwd.x, fwd.y, 0)).normalized() if Vector((fwd.x, fwd.y)).length > 1e-3 else Vector((0, 1, 0))
    # eye points: golden-angle disk, heights spread, kept only if visible from the centre eye (inside the room)
    eyes = [eye_c.copy()]
    n = E['eye_points']; ga = math.pi * (3 - math.sqrt(5))
    for i in range(1, n * 2):
        if len(eyes) >= n:
            break
        r = E['radius_m'] * math.sqrt(i / (2.0 * n))
        th = i * ga
        h = E['eye_height_min'] + (E['eye_height_max'] - E['eye_height_min']) * ((i * 0.618034) % 1.0)
        p = center + Vector((r * math.cos(th), r * math.sin(th), h))
        d = p - eye_c
        if d.length > 1e-3:
            hit, _ = ray(sc, eye_c, d.normalized(), d.length + 0.15)
            if hit is not None:
                continue
        eyes.append(p)
    return {'camera': cam.name, 'cam_pos': list(pos), 'cam_fwd': list(fwd), 'cam_lens': cam.data.lens,
            'cam_sensor': cam.data.sensor_width, 'center': list(center), 'eye_center': list(eye_c),
            'yaw_vec': list(yaw_vec), 'eyes': [list(e) for e in eyes]}


def vis_material():
    m = bpy.data.materials.new('QV_VIS')
    nt = m.node_tree
    for n in list(nt.nodes):
        nt.nodes.remove(n)
    at = nt.nodes.new('ShaderNodeAttribute'); at.attribute_type = 'GEOMETRY'; at.attribute_name = 'qv_fid'
    cd = nt.nodes.new('ShaderNodeCameraData')
    geo = nt.nodes.new('ShaderNodeNewGeometry')
    dot = nt.nodes.new('ShaderNodeVectorMath'); dot.operation = 'DOT_PRODUCT'
    nt.links.new(geo.outputs['Incoming'], dot.inputs[0]); nt.links.new(geo.outputs['True Normal'], dot.inputs[1])
    ab = nt.nodes.new('ShaderNodeMath'); ab.operation = 'ABSOLUTE'; nt.links.new(dot.outputs['Value'], ab.inputs[0])
    comb = nt.nodes.new('ShaderNodeCombineXYZ')
    nt.links.new(at.outputs['Fac'], comb.inputs[0]); nt.links.new(cd.outputs['View Distance'], comb.inputs[1])
    nt.links.new(ab.outputs[0], comb.inputs[2])
    em = nt.nodes.new('ShaderNodeEmission'); em.inputs['Strength'].default_value = 1.0
    nt.links.new(comb.outputs[0], em.inputs['Color'])
    o = nt.nodes.new('ShaderNodeOutputMaterial'); nt.links.new(em.outputs[0], o.inputs['Surface'])
    return m


def dice_large_faces(o, max_area, step):
    """Cut faces bigger than max_area on a world grid (transforms are applied) so the density can vary along
    big walls, floors and ground planes."""
    import numpy as np
    me = o.data
    ar = np.empty(len(me.polygons), np.float32); me.polygons.foreach_get('area', ar)
    if not (ar > max_area).any():
        return 0
    bm = bmesh.new(); bm.from_mesh(me)
    n0 = len(bm.faces)
    for ax in range(3):
        big = [f for f in bm.faces if f.calc_area() > max_area]
        if not big:
            break
        vs = {v for f in big for v in f.verts}
        lo = min(v.co[ax] for v in vs); hi = max(v.co[ax] for v in vs)
        k = math.floor(lo / step) + 1
        while k * step < hi:
            big = [f for f in bm.faces if f.calc_area() > max_area * 0.25]
            geom = list({e for f in big for e in f.edges}) + big + list({v for f in big for v in f.verts})
            no = Vector((0, 0, 0)); no[ax] = 1.0; co = Vector((0, 0, 0)); co[ax] = k * step
            bmesh.ops.bisect_plane(bm, geom=geom, plane_co=co, plane_no=no)
            k += 1
    n1 = len(bm.faces)
    bm.to_mesh(me); bm.free(); me.update()
    return n1 - n0


def stage_env_vis(a, cfg):
    import numpy as np
    room = get_room(cfg, a.room)
    rc, P = room_cfg(cfg, room)
    E = rc['env']
    bpy.ops.wm.save_as_mainfile(filepath=P['blend'], compress=False)
    sc = bpy.context.scene
    unbind_marker_cameras(sc)
    va = viewing_area(sc, room, E)
    log('viewing area', [round(v, 2) for v in va['center']], 'eyes', len(va['eyes']))
    objs = Q.mesh_objects()
    pano_coll = set()
    for cn in E['pano_collections']:
        c = bpy.data.collections.get(cn)
        if c:
            pano_coll |= {o.name for o in c.all_objects}
    glass = [o for o in objs if o.material_slots and all(Q.mat_class(s.material, cfg) == 'glass' for s in o.material_slots)]
    far_only = [o for o in objs if o.name in pano_coll and o not in glass]     # panorama-only (garden planting)
    solid = [o for o in objs if o not in glass and o.name not in pano_coll]
    n_diced = 0
    for o in solid:
        n_diced += dice_large_faces(o, E['dice_area_m2'], E['dice_m'])
    log('diced large faces: +%d faces' % n_diced)
    base = {}
    off = 0
    for o in solid:
        me = o.data
        n = len(me.polygons)
        at = me.attributes.get('qv_fid') or me.attributes.new('qv_fid', 'FLOAT', 'FACE')
        at.data.foreach_set('value', (np.arange(n, dtype=np.float32) + off + 1))
        base[o.name] = (off, n)
        off += n
    N = off
    hits = np.zeros(N, np.int32); mind = np.full(N, np.inf, np.float32); maxcos = np.zeros(N, np.float32)
    # render setup (restored by not saving: the room blend is saved only after the decisions)
    Q.setup_gpu(sc)
    world0 = sc.world
    w = bpy.data.worlds.new('QV_black'); sc.world = w
    bgn = next(n for n in w.node_tree.nodes if n.type == 'BACKGROUND'); bgn.inputs['Strength'].default_value = 0.0
    vl = bpy.context.view_layer
    vl.material_override = vis_material()
    for o in glass + far_only:
        o.hide_render = True
    cy = sc.cycles
    keep = dict(samples=cy.samples, filter_width=cy.filter_width, max_bounces=cy.max_bounces,
                use_denoising=cy.use_denoising, use_adaptive_sampling=cy.use_adaptive_sampling)
    cy.samples = 1; cy.use_adaptive_sampling = False; cy.use_denoising = False; cy.filter_width = 0.01
    cy.max_bounces = 0; cy.transparent_max_bounces = 0
    rs = sc.render; rs.resolution_x = E['vis_res']; rs.resolution_y = E['vis_res'] // 2; rs.resolution_percentage = 100
    rs.use_persistent_data = True
    rs.image_settings.file_format = 'OPEN_EXR'; rs.image_settings.color_depth = '32'; rs.image_settings.color_mode = 'RGB'
    cd = bpy.data.cameras.new('QV_vis'); cd.type = 'PANO'; cd.panorama_type = 'EQUIRECTANGULAR'
    cd.clip_start = 0.01; cd.clip_end = 10000
    cam = bpy.data.objects.new('QV_vis', cd); sc.collection.objects.link(cam); sc.camera = cam
    cam.rotation_euler = (math.pi / 2, 0, 0)
    tmp = os.path.join(P['room_dir'], '_vis.exr')
    t0 = time.time()
    for k, e in enumerate(va['eyes']):
        cam.location = e
        rs.filepath = tmp
        bpy.ops.render.render(write_still=True)
        im = bpy.data.images.load(tmp)
        px = np.empty(im.size[0] * im.size[1] * 4, np.float32); im.pixels.foreach_get(px); bpy.data.images.remove(im)
        px = px.reshape(-1, 4)
        fid = np.rint(px[:, 0]).astype(np.int64) - 1
        ok = (fid >= 0) & (fid < N)
        fid = fid[ok]; dist = px[ok, 1]; cs = px[ok, 2]
        np.add.at(hits, fid, 1); np.minimum.at(mind, fid, dist); np.maximum.at(maxcos, fid, cs)
        if k % 8 == 0:
            log('  vis', k + 1, '/', len(va['eyes']), round(time.time() - t0, 1), 's')
    os.remove(tmp) if os.path.exists(tmp) else None
    # restore scene state
    vl.material_override = None
    sc.world = world0; bpy.data.worlds.remove(w)
    for o in glass + far_only:
        o.hide_render = False
    for k_, v in keep.items():
        setattr(cy, k_, v)
    bpy.data.objects.remove(cam); bpy.data.cameras.remove(cd)
    sc.camera = bpy.data.objects[room['camera']]
    # decisions
    near_mm = E['texel_near_mm']; per_m = E['texel_per_m_mm']; low_w = 1000.0 / E['unseen_texel_mm']
    kept, pano, unseen = [], [o.name for o in far_only], []
    decim = []
    tris0 = Q.tri_count(objs)
    for o in solid:
        off, n = base[o.name]
        h = hits[off:off + n]
        if h.sum() == 0:
            unseen.append(o.name); continue
        dmin = float(mind[off:off + n][h > 0].min())
        if o.name in pano_coll or dmin > E['far_m']:
            pano.append(o.name); continue
        kept.append(o.name)
        if dmin > E['decimate_from_m'] and n > E['decimate_min_faces']:
            decim.append((o, dmin)); continue      # handled below (uniform density after decimation)
        md = mind[off:off + n]; mc = maxcos[off:off + n]
        dd = np.where(np.isfinite(md), md, 1e3)
        t_mm = np.maximum(near_mm, per_m * dd) / np.sqrt(np.clip(mc, 0.25, 1.0))
        t_mm = np.where(dd > E['far_m'], np.maximum(t_mm, E['far_texel_mm']), t_mm)
        wts = np.where(h > 0, 1000.0 / t_mm, low_w).astype(np.float32)
        me = o.data
        wa = me.attributes.get('qv_w') or me.attributes.new('qv_w', 'FLOAT', 'FACE')
        wa.data.foreach_set('value', wts)
        # drop large faces nobody sees (other rooms' walls etc.); small ones stay (sampling may miss them)
        areas = np.empty(n, np.float32); me.polygons.foreach_get('area', areas)
        kill = np.flatnonzero((h == 0) & (areas > E['drop_unseen_area_m2']))
        if kill.size and kill.size < n:
            bm = bmesh.new(); bm.from_mesh(me); bm.faces.ensure_lookup_table()
            bmesh.ops.delete(bm, geom=[bm.faces[i] for i in kill], context='FACES')
            bm.to_mesh(me); bm.free()
    # heavy objects only seen from afar: decimate (ratio ~ (decimate_from_m / distance)^2, >= 0.15) with a uniform density
    n_dec = 0
    for o, dmin in decim:
        ratio = max(0.15, min(1.0, (E['decimate_from_m'] / dmin) ** 2))
        n0 = len(o.data.polygons)
        if ratio < 0.95:
            mod = o.modifiers.new('QV_decimate', 'DECIMATE'); mod.ratio = ratio; mod.use_collapse_triangulate = True
            dg_ = bpy.context.evaluated_depsgraph_get()
            me_new = bpy.data.meshes.new_from_object(o.evaluated_get(dg_), preserve_all_data_layers=True, depsgraph=dg_)
            o.modifiers.remove(mod); old = o.data; o.data = me_new
            if old.users == 0:
                bpy.data.meshes.remove(old)
        t = max(near_mm, per_m * dmin)
        wa = o.data.attributes.get('qv_w') or o.data.attributes.new('qv_w', 'FLOAT', 'FACE')
        wa.data.foreach_set('value', np.full(len(o.data.polygons), 1000.0 / t, np.float32))
        n_dec += n0 - len(o.data.polygons)
    if decim:
        log('decimated %d distant objects: -%d faces' % (len(decim), n_dec))
    # unseen / far objects stay in the scene as 'context': they still shadow and bounce light in the bake,
    # but get no UVs, are not baked and are not exported (far ones are in the panorama)
    for nm in unseen + pano:
        bpy.data.objects[nm]['qv_env'] = 'context'
    dg = bpy.context.evaluated_depsgraph_get()
    for o in glass:     # glass: keep panes that some eye point actually sees (first hit = this pane)
        seen = False
        cs = [o.matrix_world @ p.center for p in o.data.polygons][:64]
        for e in va['eyes'][::4]:
            for c_ in cs:
                d = c_ - Vector(e)
                if d.length > E['far_m']:
                    continue
                hit, loc, nrm, idx, ob, _ = sc.ray_cast(dg, Vector(e), d.normalized(), distance=d.length + 0.05)
                if hit and ob is not None and ob.name == o.name:
                    seen = True; break
            if seen:
                break
        if seen:
            kept.append(o.name)
        else:
            pano.append(o.name); o['qv_env'] = 'context'
    for o in Q.mesh_objects():
        if 'qv_fid' in o.data.attributes:
            o.data.attributes.remove(o.data.attributes['qv_fid'])
    tris = Q.tri_count([o for o in Q.mesh_objects() if o.get('qv_env') != 'context'])
    info = dict(va, kept=kept, pano=pano, unseen_count=len(unseen), triangles_before=tris0, triangles=tris,
                faces_seen=int((hits > 0).sum()), faces_total=int(N))
    with open(P['info'], 'w', encoding='utf-8') as f:
        json.dump(info, f, indent=1)
    log('kept objects %d, panorama %d, unseen %d; triangles %d -> %d' % (len(kept), len(pano), len(unseen), tris0, tris))
    if tris > E['max_triangles']:
        log('WARNING triangle budget exceeded', tris)
    bpy.ops.wm.save_mainfile(filepath=P['blend'], compress=False)


# ----------------------------------------------------------------------------------------------- env_uv
def stage_env_uv(a, cfg):
    import numpy as np
    room = get_room(cfg, a.room)
    rc, P = room_cfg(cfg, room)
    E = rc['env']
    sc = bpy.context.scene
    sc.tool_settings.use_uv_select_sync = True
    S = rc['atlas_size']
    cap = E['atlas_fill'] * S * S
    objs = [o for o in Q.mesh_objects() if o.get('qv_env') != 'context'
            and not (o.material_slots and all(Q.mat_class(s.material, rc) == 'glass' for s in o.material_slots))]
    for o in objs:
        if 'qv_w' not in o.data.attributes:     # e.g. split-off parts: assume near
            wa = o.data.attributes.new('qv_w', 'FLOAT', 'FACE')
            wa.data.foreach_set('value', np.full(len(o.data.polygons), 1000.0 / E['texel_near_mm'], np.float32))

    def weights(o):
        w = np.empty(len(o.data.polygons), np.float32); o.data.attributes['qv_w'].data.foreach_get('value', w)
        return w

    def texels(o):
        ar = np.empty(len(o.data.polygons), np.float32); o.data.polygons.foreach_get('area', ar)
        return float((ar * weights(o) ** 2).sum())
    kinds = {o.name: ('alpha' if any(Q.mat_class(s.material, rc) == 'alpha' for s in o.material_slots) else 'main') for o in objs}
    total = sum(texels(o) for o in objs if kinds[o.name] == 'main')
    n_main_max = E['max_atlases'] - (1 if 'alpha' in kinds.values() else 0)
    scale = 1.0
    if total > n_main_max * cap:
        scale = math.sqrt(n_main_max * cap / total)
        for o in objs:
            wa = o.data.attributes['qv_w']; w = weights(o) * scale; wa.data.foreach_set('value', w)
        total *= scale * scale
    n_main = max(1, int(math.ceil(total / cap)))
    log('texel budget: %.1f Mtexel -> %d main atlas(es) of %d (density scale %.2f)' % (total / 1e6, n_main, S, scale))
    # split objects larger than half an atlas
    queue = [(o, 0) for o in objs if kinds[o.name] == 'main']
    while queue:
        o, depth = queue.pop()
        if texels(o) <= 0.5 * cap or depth >= 8 or len(o.data.polygons) < 2:
            continue
        co = np.empty(len(o.data.vertices) * 3); o.data.vertices.foreach_get('co', co); co = co.reshape(-1, 3)
        ext = co.max(0) - co.min(0); ax = int(np.argmax(ext[:2])) if ext[:2].max() >= ext[2] else 2
        new = Q.bisect_object(o, ax, float(co[:, ax].min() + co[:, ax].max()) / 2)
        if new:
            kinds[new.name] = 'main'; queue += [(o, depth + 1), (new, depth + 1)]
    objs = [o for o in Q.mesh_objects() if o.name in kinds or (o.get('qv_env') != 'context' and 'qv_w' in o.data.attributes
            and not (o.material_slots and all(Q.mat_class(s.material, rc) == 'glass' for s in o.material_slots)))]
    for o in objs:
        kinds.setdefault(o.name, 'main')
    # BakeUV: reuse a clean layout, else smart project; islands scaled by the per-face density
    smart = []
    for o in objs:
        me = o.data
        if Q.BAKE_UV in me.uv_layers:
            me.uv_layers.remove(me.uv_layers[Q.BAKE_UV])
        if len(me.uv_layers) == 0:
            me.uv_layers.new(name='UVMap', do_init=False)
        orig = next((l for l in me.uv_layers if l.active_render), me.uv_layers[0])
        me.uv_layers.active = orig
        ok = len(me.polygons) >= 200 and Q.uv_overlap_ok(me, orig)
        lay = me.uv_layers.new(name=Q.BAKE_UV, do_init=True)
        for l in me.uv_layers:
            l.active_render = (l.name == orig.name)
        me.uv_layers.active = lay
        if not ok:
            smart.append(o)
    if smart:
        Q.edit_objects(smart)
        bpy.ops.uv.smart_project(angle_limit=math.radians(60), margin_method='FRACTION', island_margin=0.0,
                                 area_weight=0.0, correct_aspect=True, scale_to_bounds=False)
        bpy.ops.object.mode_set(mode='OBJECT')
    for o in objs:
        scale_islands_binned(o, weights(o), E['density_bin'])
    # atlases: main objects in spatial order, filled by texel count; alpha objects share one atlas
    main = [o for o in objs if kinds[o.name] == 'main']

    def key(o):
        mn, mx = Q.world_bbox([o]); c = (mn + mx) / 2
        return (int(c.y // 3.0), c.x, c.y, c.z)
    # largest first into the least loaded atlas (one room: balance matters more than grouping)
    loads = [0.0] * n_main
    atl = {}
    for o in sorted(main, key=lambda o: -texels(o)):
        k = loads.index(min(loads)); atl[o.name] = k; loads[k] += texels(o)
    log('atlas loads (Mtexel):', [round(x / 1e6, 2) for x in loads])
    atlases = [{'index': i, 'kind': 'main', 'size': S} for i in range(n_main)]
    alpha = [o for o in objs if kinds[o.name] == 'alpha']
    if alpha:
        ta = sum(texels(o) for o in alpha) / E['atlas_fill']
        sz = E.get('alpha_atlas_size') or (1024 if ta < 1024 ** 2 else 2048 if ta < 2048 ** 2 else S)
        atlases.append({'index': n_main, 'kind': 'alpha', 'size': sz})
        for o in alpha:
            atl[o.name] = n_main
    for o in objs:
        o['qv_atlas'] = atl[o.name]; o['qv_kind'] = kinds[o.name]
    for A in atlases:
        group = [o for o in objs if atl[o.name] == A['index']]
        A['objects'] = len(group)
        if not group:
            continue
        t = time.time()
        Q.edit_objects(group)
        bpy.ops.uv.pack_islands(udim_source='CLOSEST_UDIM', rotate=True, rotate_method='ANY', scale=True,
                                merge_overlap=False, margin_method='FRACTION', margin=rc.get('island_margin_px', 6) / A['size'],
                                shape_method='CONCAVE')
        bpy.ops.object.mode_set(mode='OBJECT')
        # achieved texel on the densest (near) faces
        uva = 0.0; wa = 0.0
        for o in group:
            w = weights(o); uvl = o.data.uv_layers[Q.BAKE_UV]; wmax = w.max()
            for p in o.data.polygons:
                if w[p.index] >= 0.9 * wmax and p.area > 0.002:
                    uva += Q.poly_uv_area([uvl.data[li].uv for li in p.loop_indices]); wa += p.area
        A['near_texel_mm'] = round(1000.0 / (math.sqrt(uva / wa) * A['size']), 2) if uva > 0 and wa > 0 else None
        log('packed atlas', A, round(time.time() - t, 1), 's')
    sc['qv_atlases'] = json.dumps(atlases)
    info = json.load(open(P['info'], encoding='utf-8'))
    info['atlases'] = atlases; info['density_scale'] = scale
    json.dump(info, open(P['info'], 'w', encoding='utf-8'), indent=1)
    bpy.ops.wm.save_mainfile(filepath=P['blend'], compress=False)


def scale_islands_binned(o, w, binf):
    """Like qv_bake.scale_islands, but each island is split into density bins (ratio binf) so one big wall or
    floor can be dense near the viewer and coarse far away."""
    import numpy as np
    from bpy_extras.bmesh_utils import bmesh_linked_uv_islands
    bm = bmesh.new(); bm.from_mesh(o.data); bm.faces.ensure_lookup_table()
    uvl = bm.loops.layers.uv[Q.BAKE_UV]
    lb = math.log(binf)
    for isl in bmesh_linked_uv_islands(bm, uvl):
        groups = {}
        for f in isl:
            groups.setdefault(int(round(math.log(max(w[f.index], 1e-3)) / lb)), []).append(f)
        for faces in groups.values():
            a3 = 0.0; auv = 0.0; cx = cy = 0.0; nl = 0
            for f in faces:
                ww = float(w[f.index])
                a3 += f.calc_area() * ww * ww
                uvs = [l[uvl].uv.copy() for l in f.loops]
                auv += Q.poly_uv_area(uvs)
                for u_ in uvs:
                    cx += u_.x; cy += u_.y; nl += 1
            s_ = math.sqrt(a3 / auv) if auv > 1e-14 and a3 > 1e-12 else 1e-4
            cx /= max(nl, 1); cy /= max(nl, 1)
            for f in faces:
                for l in f.loops:
                    uu = l[uvl].uv; uu.x = (uu.x - cx) * s_; uu.y = (uu.y - cy) * s_
    bm.to_mesh(o.data); bm.free()


# ----------------------------------------------------------------------------------------------- env_bake / env_post
def view_camera(sc, info):
    """The bake's 'Active Camera' = the viewing-area centre at eye height (reflection rays start there)."""
    cam = bpy.data.objects.get('QV_ViewCenter')
    if cam is None:
        cd = bpy.data.cameras.new('QV_ViewCenter'); cam = bpy.data.objects.new('QV_ViewCenter', cd)
        sc.collection.objects.link(cam)
    cam.location = info['eye_center']
    yv = Vector(info['yaw_vec'])
    cam.rotation_euler = Vector((yv.x, yv.y, 0)).to_track_quat('-Z', 'Y').to_euler()
    sc.camera = cam
    return cam


def stage_env_bake(a, cfg):
    room = get_room(cfg, a.room)
    rc, P = room_cfg(cfg, room)
    sc = bpy.context.scene
    info = json.load(open(P['info'], encoding='utf-8'))
    unbind_marker_cameras(sc)
    view_camera(sc, info)
    sc.render.bake.view_from = 'ACTIVE_CAMERA'
    # optional: heavy far-field context (scanned trees with alpha leaves) out of the light paths. It is still
    # in the panorama; with no direct sun its effect on interior light is small and the bake gets ~4x faster.
    hidden = 0
    for cn in rc['env'].get('bake_hide_collections', []):
        c = bpy.data.collections.get(cn)
        if c:
            for o in c.all_objects:
                if o is not None and o.get('qv_env') == 'context' and not o.hide_render:
                    o.hide_render = True; hidden += 1
    # context far from the viewing area (other parts of the site) adds little light to the room but costs a lot
    rad = rc['env'].get('bake_context_radius_m')
    if rad:
        eye = Vector(info['eye_center'])
        for o in sc.objects:
            if o.type == 'MESH' and o.get('qv_env') == 'context' and not o.hide_render:
                bb = [o.matrix_world @ Vector(c) for c in o.bound_box]
                lo = Vector([min(v[i] for v in bb) for i in range(3)]); hi = Vector([max(v[i] for v in bb) for i in range(3)])
                nearest = Vector([min(max(eye[i], lo[i]), hi[i]) for i in range(3)])
                if (nearest - eye).length > rad:
                    o.hide_render = True; hidden += 1
    if hidden:
        log('hidden from the bake:', hidden, 'context objects')
    batched_bake(rc, sc, a)


def set_target(mat, img):
    nt = mat.node_tree
    n = nt.nodes.get('QV_BAKE_TARGET') or nt.nodes.new('ShaderNodeTexImage')
    n.name = 'QV_BAKE_TARGET'; n.image = img
    for x in nt.nodes:
        x.select = False
    n.select = True; nt.nodes.active = n


def batched_bake(rc, sc, a):
    """Like qv_bake.stage_bake, but several atlases per Cycles bake call (one scene sync per batch): every atlas
    gets its own copies of its materials (in memory only), each pointing at that atlas' image."""
    atlases = Q.load_atlases(sc)
    Q.setup_gpu(sc)
    cy = sc.cycles; cy.use_denoising = False
    try:
        cy.use_auto_tile = True; cy.tile_size = rc['bake'].get('tile', 2048)
    except Exception:
        pass
    bd = rc['_bakedir']
    by = {A['index']: Q.atlas_objects(A['index']) for A in atlases}
    Q.ensure_materials([o for v in by.values() for o in v])
    for i, objs in by.items():
        cache = {}
        for o in objs:
            for sl in o.material_slots:
                m = sl.material
                if m.name not in cache:
                    cache[m.name] = m.copy(); cache[m.name].name = '%s__A%d' % (m.name[:48], i)
                sl.material = cache[m.name]
    todo = [A for A in atlases if by[A['index']] and (a.force or not os.path.exists(os.path.join(bd, 'atlas%d_combined.exr' % A['index'])))]
    passes = {'EMIT', 'DIRECT', 'INDIRECT', 'DIFFUSE', 'TRANSMISSION'}
    if rc['bake'].get('glossy'):
        passes.add('GLOSSY')
    chunk = rc['bake'].get('chunk', 6)
    tpath = os.path.join(bd, 'timing.json')
    timing = json.load(open(tpath)) if os.path.exists(tpath) else {}
    margin = rc['bake']['margin_px']

    def run(grp, kind, samples):
        imgs = {A['index']: Q.new_float_image('QV_%s_%d' % (kind, A['index']), A['size']) for A in grp}
        objs = []
        for A in grp:
            for o in by[A['index']]:
                for sl in o.material_slots:
                    set_target(sl.material, imgs[A['index']])
                objs.append(o)
        Q.select_only(objs)
        cy.samples = samples
        t = time.time()
        if kind == 'combined':
            bpy.ops.object.bake(type='COMBINED', pass_filter=passes, margin=margin, margin_type='EXTEND', use_clear=False,
                                target='IMAGE_TEXTURES', uv_layer=Q.BAKE_UV)
        else:
            bpy.ops.object.bake(type='DIFFUSE', pass_filter={'COLOR'}, margin=margin, margin_type='EXTEND', use_clear=False,
                                target='IMAGE_TEXTURES', uv_layer=Q.BAKE_UV)
        return imgs, time.time() - t
    for k in range(0, len(todo), chunk):
        grp = todo[k:k + chunk]
        t0 = time.time()
        alb, ta = run(grp, 'albedo', rc['bake']['albedo_samples'])
        for i, im in alb.items():
            Q.save_exr(im, os.path.join(bd, 'atlas%d_albedo.exr' % i)); bpy.data.images.remove(im)
        for A in grp:
            if A['kind'] == 'alpha':
                msk = Q.new_float_image('QV_mask_%d' % A['index'], A['size'])
                for o in by[A['index']]:
                    for sl in o.material_slots:
                        set_target(sl.material, msk)
                cy.samples = 16
                Q.bake_alpha_mask(by[A['index']], msk, rc)
                Q.save_exr(msk, os.path.join(bd, 'atlas%d_mask.exr' % A['index'])); bpy.data.images.remove(msk)
        comb, tc = run(grp, 'combined', a.samples or rc['bake']['samples'])
        for i, im in comb.items():
            Q.save_exr(im, os.path.join(bd, 'atlas%d_combined.exr' % i)); bpy.data.images.remove(im)
        for A in grp:
            timing[str(A['index'])] = {'batch': [B['index'] for B in grp], 'batch_combined_s': round(tc, 1),
                                       'batch_total_s': round(time.time() - t0, 1), 'samples': a.samples or rc['bake']['samples']}
        json.dump(timing, open(tpath, 'w'), indent=1)
        log('BAKED atlases', [B['index'] for B in grp], 'combined %.0f s, albedo %.0f s, total %.0f s' % (tc, ta, time.time() - t0))


def stage_env_post(a, cfg):
    room = get_room(cfg, a.room)
    rc, P = room_cfg(cfg, room)
    Q.stage_post(qargs(a), rc)


# ----------------------------------------------------------------------------------------------- env_pano
def stage_env_pano(a, cfg):
    """Far field: equirect from the centre eye; everything kept as geometry is invisible to camera rays."""
    room = get_room(cfg, a.room)
    rc, P = room_cfg(cfg, room)
    E = rc['env']
    info = json.load(open(P['info'], encoding='utf-8'))
    sc = bpy.context.scene
    unbind_marker_cameras(sc)
    kept = set(info['kept'])
    eye = Vector(info['eye_center'])
    n_hidden = 0
    for o in sc.objects:
        if o.type == 'MESH' and o.name in kept:
            # kept objects that reach beyond the far distance (lawn, garden walls) stay visible in the panorama, so
            # the parts that are not geometry are still in the far field
            far = max((o.matrix_world @ Vector(c) - eye).length for c in o.bound_box)
            if far <= E['far_m']:
                o.visible_camera = False; n_hidden += 1
    Q.setup_gpu(sc)
    cd = bpy.data.cameras.new('QV_pano'); cd.type = 'PANO'; cd.panorama_type = 'EQUIRECTANGULAR'
    cd.clip_start = 0.05; cd.clip_end = 100000
    cam = bpy.data.objects.new('QV_pano', cd); sc.collection.objects.link(cam); sc.camera = cam
    cam.location = info['eye_center']; cam.rotation_euler = (math.pi / 2, 0, 0)   # u=0.5 -> +Y, see sphere_mesh()
    rs = sc.render
    rs.resolution_x = E['pano_size']; rs.resolution_y = E['pano_size'] // 2; rs.resolution_percentage = 100
    sc.cycles.samples = a.samples or E['pano_samples']; sc.cycles.use_denoising = True
    vs = sc.view_settings
    vs.view_transform = rc['view']['transform']; vs.look = rc['view']['look']; vs.exposure = rc['view']['exposure']
    rs.image_settings.file_format = 'JPEG'; rs.image_settings.quality = 92; rs.image_settings.color_mode = 'RGB'
    rs.filepath = P['pano']
    t = time.time()
    bpy.ops.render.render(write_still=True)
    info['pano_seconds'] = round(time.time() - t, 1)
    json.dump(info, open(P['info'], 'w', encoding='utf-8'), indent=1)
    log('panorama', P['pano'], E['pano_size'], 'px,', n_hidden, 'objects hidden from camera,', info['pano_seconds'], 's')


# ----------------------------------------------------------------------------------------------- env_export
def sphere_mesh(name, center, R, nu=128, nv=64):
    """Inside-facing sphere with equirect UVs matching the pano camera above:
    u = 0.5 + atan2(d.x, d.y) / 2pi, v = 0.5 + asin(d.z) / pi (calibrated in Blender 5.2)."""
    me = bpy.data.meshes.new(name)
    verts, faces, uvs = [], [], []
    for j in range(nv + 1):
        v = j / nv; th = (v - 0.5) * math.pi
        for i in range(nu + 1):
            u = i / nu; ph = (u - 0.5) * 2 * math.pi
            d = Vector((math.sin(ph) * math.cos(th), math.cos(ph) * math.cos(th), math.sin(th)))
            verts.append(Vector(center) + d * R)
    idx = lambda i, j: j * (nu + 1) + i
    for j in range(nv):
        for i in range(nu):
            faces.append((idx(i, j), idx(i, j + 1), idx(i + 1, j + 1), idx(i + 1, j)))
    me.from_pydata([tuple(v) for v in verts], [], faces)
    uvl = me.uv_layers.new(name='UVMap')
    for p in me.polygons:
        for li in p.loop_indices:
            vi = me.loops[li].vertex_index
            uvl.data[li].uv = ((vi % (nu + 1)) / nu, (vi // (nu + 1)) / nv)
    me.update()
    # normals must point to the centre
    p = me.polygons[len(me.polygons) // 2]
    if p.normal.dot(Vector(center) - p.center) < 0:
        me.flip_normals()
    return me


def stage_env_export(a, cfg):
    room = get_room(cfg, a.room)
    rc, P = room_cfg(cfg, room)
    E = rc['env']
    info = json.load(open(P['info'], encoding='utf-8'))
    sc = bpy.context.scene
    # start = viewing-area centre facing the reference camera's direction
    c = info['center']; yv = info['yaw_vec']
    rc['start'] = {'position_blender': [c[0], c[1], c[2] + 0.5], 'look_at_blender': [c[0] + yv[0], c[1] + yv[1]]}
    # far-field sphere (exported as-is: UsdPreviewSurface with the panorama, the app shows it unlit)
    me = sphere_mesh('Sky_Panorama', info['eye_center'], E['sphere_radius_m'])
    ob = bpy.data.objects.new('Sky_Panorama', me); sc.collection.objects.link(ob)
    m = bpy.data.materials.new('QV_Sky_Panorama'); b = Q.principled(m)
    t = m.node_tree.nodes.new('ShaderNodeTexImage'); t.image = bpy.data.images.load(P['pano']); t.extension = 'EXTEND'
    m.node_tree.links.new(t.outputs['Color'], b.inputs['Base Color'])
    b.inputs['Roughness'].default_value = 1.0; b.inputs['Specular IOR Level'].default_value = 0.0
    me.materials.append(m)
    ob['qv_keep_material'] = True
    for o in [o for o in sc.objects if o.get('qv_env') == 'context']:
        bpy.data.objects.remove(o, do_unlink=True)
    Q.stage_export(qargs(a), rc)
    side_p = os.path.join(rc['out_dir'], rc['name'] + '.json')
    side = json.load(open(side_p, encoding='utf-8'))
    ctr = Q.blender_to_usd(info['center'])
    side.update({'kind': 'environment', 'group': cfg['group'], 'order': room['order'], 'title': room['title'],
                 'viewingArea': {'center': [round(v, 3) for v in ctr], 'radiusMeters': E['radius_m']},
                 'hasSky': True})
    side['notes'] = ('Environment (viewing area r=%.1f m) baked with Blender %s Cycles from the source blend\'s own lighting; '
                     'COMBINED incl. glossy reflections seen from the viewing-area centre; view %s / %s / exposure %+.2f; '
                     'far field = %d px equirect panorama on an unlit sphere (r=%d m). Show UNLIT.') % (
        E['radius_m'], bpy.app.version_string, rc['view']['transform'], rc['view']['look'], rc['view']['exposure'],
        E['pano_size'], E['sphere_radius_m'])
    order = ['title', 'version', 'kind', 'group', 'order', 'viewingArea', 'start', 'eyeHeightIncluded', 'hasSky', 'notes']
    side = {k: side[k] for k in order if k in side}
    json.dump(side, open(side_p, 'w', encoding='utf-8'), indent=2)
    info['usdz'] = rc['name'] + '.usdz'
    info['usdz_bytes'] = os.path.getsize(os.path.join(rc['out_dir'], rc['name'] + '.usdz'))
    json.dump(info, open(P['info'], 'w', encoding='utf-8'), indent=1)
    log('environment sidecar', side_p)


# ----------------------------------------------------------------------------------------------- env_verify
def stage_env_verify(a, cfg):
    import numpy as np
    room = get_room(cfg, a.room)
    rc, P = room_cfg(cfg, room)
    info = json.load(open(P['info'], encoding='utf-8'))
    usdz = os.path.join(rc['out_dir'], rc['name'] + '.usdz')
    sc = Q.verify_setup(rc, usdz, a.samples)
    ref_path = os.path.join(cfg['ref_dir'], room['ref']) if room.get('ref') else None
    W = a.res or 1536; H = int(W * 2 / 3)
    if ref_path and os.path.exists(ref_path):
        ri = bpy.data.images.load(ref_path); H = int(W * ri.size[1] / ri.size[0])
    cd = bpy.data.cameras.new('cam'); cam = bpy.data.objects.new('cam', cd); sc.collection.objects.link(cam); sc.camera = cam
    cd.sensor_width = info['cam_sensor']; cd.lens = info['cam_lens']; cd.clip_start = 0.03; cd.clip_end = 2000
    sc.render.resolution_x = W; sc.render.resolution_y = H; sc.render.resolution_percentage = 100
    sc.render.image_settings.file_format = 'JPEG'; sc.render.image_settings.quality = 92

    def shot(pos, fwd, path):
        cam.location = pos
        cam.rotation_euler = Vector(fwd).to_track_quat('-Z', 'Y').to_euler()
        sc.render.filepath = path; bpy.ops.render.render(write_still=True)
    # 1) reference camera (it stands inside the viewing area); 2) the centre eye, same direction; 3) look around
    ref_view = os.path.join(P['previews'], '%s_refcam.jpg' % P['rid'])
    shot(info['cam_pos'], info['cam_fwd'], ref_view)
    yv = Vector(info['yaw_vec'])
    shot(info['eye_center'], (yv.x, yv.y, -0.05), os.path.join(P['previews'], '%s_center.jpg' % P['rid']))
    cd.lens = 16
    for k, ang in enumerate((90, 180, 270)):
        r = math.radians(ang)
        d = Vector((yv.x * math.cos(r) - yv.y * math.sin(r), yv.x * math.sin(r) + yv.y * math.cos(r), -0.05))
        shot(info['eye_center'], d, os.path.join(P['previews'], '%s_around_%03d.jpg' % (P['rid'], ang)))
    # thumbnail
    cd.lens = 18; sc.render.resolution_x = 512; sc.render.resolution_y = 320
    shot(info['eye_center'], (yv.x, yv.y, -0.05), os.path.join(rc['out_dir'], rc['name'] + '.jpg'))
    # side by side with the reference render
    if ref_path and os.path.exists(ref_path):
        import qv_hd
        mine = bpy.data.images.load(ref_view); w_, h_ = mine.size
        a1 = np.empty(w_ * h_ * 4, np.float32); mine.pixels.foreach_get(a1); a1 = a1.reshape(h_, w_, 4)[..., :3]
        ri.scale(w_, h_)
        a2 = np.empty(w_ * h_ * 4, np.float32); ri.pixels.foreach_get(a2); a2 = a2.reshape(h_, w_, 4)[..., :3]
        sheet = np.concatenate([a2, a1], axis=1)       # left: reference, right: baked (headset look)
        outp = os.path.join(P['previews'], '%s_vs_ref.jpg' % P['rid'])
        qv_hd.write_bytes_image(sheet, outp, 'JPEG', 90)
        diff = float(np.abs(a1 - a2).mean() * 255)
        info['ref_mean_abs_diff_8bit'] = round(diff, 2)
        json.dump(info, open(P['info'], 'w', encoding='utf-8'), indent=1)
        log('comparison', outp, 'mean |diff| %.1f (8-bit, includes framing/parallax differences)' % diff)


# ----------------------------------------------------------------------------------------------- main
def main():
    a, cfg = parse()
    fn = globals().get('stage_' + a.stage)
    if not fn:
        raise SystemExit('unknown stage ' + a.stage)
    P = paths(cfg, get_room(cfg, a.room) if a.room else None)
    cur = os.path.normcase(os.path.abspath(bpy.data.filepath)) if bpy.data.filepath else ''
    want = {'env_prep': cfg['src'], 'env_vis': P['base'], 'env_pano': P['base']}.get(a.stage)
    if a.stage in ('env_uv', 'env_bake', 'env_post', 'env_export'):
        want = P['blend']
    if want and cur != os.path.normcase(os.path.abspath(want)):
        bpy.ops.wm.open_mainfile(filepath=want, load_ui=False)
    fn(a, cfg)
    log('DONE', a.stage, a.room or '')


if __name__ == '__main__':
    main()
