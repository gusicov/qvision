# tools/bake — QVision "Rendered" package producer (Blender Cycles)

Turns an architectural `.blend` into a **QVision Rendered package** (see `docs/v0.8-REQUIREMENTS.md`, R2):

- `<Name>.usdz`: Y-up, metres. Every material's base colour is a baked, tone-mapped sRGB lightmap atlas, to be shown **unlit**. Glass is a tinted `*Glass*` material with opacity.
- `<Name>.json`: sidecar with title, start position at floor level in USD coordinates, `yawDegrees`, `hasSky` and notes.
- `<Name>.jpg`: thumbnail, 512 × 320.
- `previews/*.jpg` and `previews/sheet.jpg`: renders of the re-imported USDZ with emission-only materials, i.e. what the headset shows.

The output goes to `out_dir` from the config, normally `C:\All Docs\06_Apple vision pro\assets\Rendered\`. That is the folder the QVision Library server publishes.
The source blend is only **read**: the `prep` stage saves its own work copy before touching anything.
Nothing from a client scene belongs in this repo.

## Run

```bat
tools\bake\Bake-Rendered.cmd                         :: whole pipeline, Casa SUA config
tools\bake\Bake-Rendered.cmd casa_sua.json bake      :: resume from a stage (finished atlases are skipped)
tools\bake\Bake-Rendered.cmd casa_sua.json post      :: re-tone-map after editing view.exposure, then export + verify
```

To use a different Blender, set `BLENDER=...\blender.exe` before running.
Each stage can also be run on its own:
`blender -b --python-exit-code 1 --python qv_bake.py -- <stage> --config casa_sua.json [--atlas 0,3] [--samples N] [--force]`.
The `verify` stage needs `--factory-startup`.

| stage | what it does |
|---|---|
| `prep` | Opens `src` and **immediately saves** `out_dir\work\<name>_bake_work.blend`. Then it removes excluded collections and hidden objects, converts curves, applies render-level modifiers and transforms, makes data single-user, splits glass/alpha faces into their own objects, flips inside-out objects (Cycles bakes only the side a normal points to; detected by comparing open space in front of vs behind the faces), turns metals into darkened dielectrics and mirrors into grey (the bake has no glossy component), and sets the sun, Nishita/multiple-scattering sky, lamp scale, AgX and Cycles on the GPU (OptiX). |
| `fixnormals` | *Optional / maintenance.* Runs the same inside-out check on an existing work blend (after `uv`), then re-bake the atlases it lists with `bake --atlas ... --force`. |
| `lookdev` | *Optional.* Fast denoised renders of the scene cameras for a sun study, e.g. `--sun 17.5,5 --exposure 2.2 --cams CAM_03,CAM_05`. |
| `uv` | Builds the lightmap UV `BakeUV`. Faces get texel weights from ray tests: interior 1, sees the sky 0.4, touching other geometry 0.08; art and rugs are boosted. A clean existing UV layout is reused (no overlap, inside 0–1); otherwise Smart UV Project is used. Islands are rescaled to their world area. Very large objects are bisected. Objects are assigned to atlases (N−2 interior atlases balanced and grouped by position, 1 exterior/context atlas, 1 small alpha atlas), then packed with a 6 px margin. Writes `work\atlases.json`. |
| `bake` | Per atlas: Cycles `COMBINED` with diffuse + transmission + emission, direct + indirect and **no glossy** (view-independent), into a float EXR. Also bakes albedo (to guide the denoiser) and an alpha mask for the alpha atlas. Resumable: one atlas at a time, timings in `work\bake\timing.json`. |
| `post` | Push-pull fill of empty texels, OIDN denoise (compositor, HDR, albedo-guided), and the **same AgX + look + exposure as the scene** (`save_render`) to an 8-bit sRGB JPEG. The alpha atlas is written as an RGBA PNG. |
| `export` | One material per atlas (UsdPreviewSurface base colour = atlas, roughness 1, no other maps). `QV_Glass*` materials carry tint + opacity; they cover window glass, the pool water and the sheer curtains, which are not baked. The optional `translucent_materials` setting instead bakes a material and exports it with an opacity (`_Sheer` variant). BakeUV becomes the only UV (`st`). Meshes are joined per material. USDZ is exported Y-up in metres with textures packed. Also writes the sidecar JSON; the start point is snapped to the floor by a ray. |
| `verify` | Fresh Blender: imports the USDZ, makes every material emission-only (keeping opacity), and renders the start view plus `preview_views` and the thumbnail. |

## Config (`casa_sua.json`)

- `src`, `out_dir`, `name`, `title`
- `sun`: elevation and azimuth in degrees. The azimuth is measured from scene +Y towards +X; the sky texture and the sun lamp are calibrated to agree.
- `sky`, `lamp_scale`, `view` (AgX look and exposure)
- `glass_materials` (regex) and `glass_tint` (`[r, g, b, opacity]`): these materials are not baked; they are exported as a constant tint with opacity. `translucent_materials` (name → opacity): baked, then exported see-through.
- `atlas_size`, `atlas_count`, `exterior_atlas_collections`, `context_patterns`, `context_weight`, `face_weights`, `detail_materials`
- `bake.samples`; `export.jpeg_quality`
- `start`: `position_blender` and `look_at_blender`, in Blender Z-up coordinates. The export converts them: USD = (x, z, −y), and `yawDegrees` is measured about +Y from −Z (90 = facing −X).
- `has_sky`: written to the sidecar as `hasSky`.
- `preview_views`: Blender coordinates, used for the verification renders.

## Notes / limits

- The lighting is fixed (one sun position). Speculars and reflections are not baked: floors look matte and mirrors are grey.
- Changing the exposure needs only `post` → `export` → `verify`. Changing the sun or lamps needs `bake` again with `--force`.
- Textures are baked at the lightmap resolution, about 5–7.5 mm per texel indoors. Fine detail in paintings and fabric is softer than in the original textures.
- Requirements: Blender 5.2 and an NVIDIA GPU (OptiX). An 8 GB card is enough when atlases are baked one at a time.
