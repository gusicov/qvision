#!/usr/bin/env python3
"""Generates the baked textures for QVision's immersive environments.

Run from the repository root:

    python -I tools/make_environments.py            # everything
    python -I tools/make_environments.py sky_night  # only some outputs

Outputs (App/Resources/Environments/, copied flat into the app bundle):

  qv_env_sky_{studio,daylight,sunset,night}.jpg   4096x2048 equirectangular skies
  qv_env_pavers_{albedo.jpg,normal.png,roughness.png}     polished concrete slabs
  qv_env_pavers_wet_{albedo.jpg,roughness.png}            night variant (shares normal)
  qv_env_epoxy_{albedo.jpg,normal.png,roughness.png}      studio epoxy floor
  qv_env_ground_fade.png                                  radial opacity for the far ground

Conventions (must match EnvironmentBuilder.swift):
  * Equirect: u = 0..1 left to right, v = 0 at the top (zenith) row.
    Azimuth a = 2*pi*u - pi, i.e. the image centre (u = 0.5) is the "front".
    The sun / moon is always painted at u = 0.5; the Swift code yaws the dome so
    that it lands where the directional light comes from. Elevation per preset
    is listed in SUN_ELEVATION_DEG below (mirrored in the Swift palette).
  * Floor tiles: 2048 px = 4 m, 4 x 4 slabs of 1 m, joints centred on the tile
    edges, so every texture tiles seamlessly. Normal maps are tangent space,
    OpenGL (+Y / green up) convention.

Only numpy + Pillow are used; all randomness is seeded, so output is reproducible.
"""

import os
import sys
import time

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "App", "Resources", "Environments")

SKY_W, SKY_H = 4096, 2048
FLOOR_N = 2048
TILE_METERS = 4.0
SLABS = 4

SUN_ELEVATION_DEG = {
    "studio": 55.0,  # soft key glow only, no disk
    "daylight": 45.0,
    "sunset": 5.0,
    "night": 32.0,  # moon
}

F32 = np.float32


# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

def srgb_to_linear(c):
    c = np.asarray(c, dtype=F32)
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4).astype(F32)


def linear_to_srgb(c):
    c = np.clip(c, 0.0, 1.0)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * np.power(c, 1.0 / 2.4) - 0.055).astype(F32)


def col(r, g, b):
    """sRGB triple -> linear float32 vector."""
    return srgb_to_linear([r, g, b])


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def mix(a, b, t):
    return a + (b - a) * t


def spectral_noise(n, power=1.0, fmin=1.0, fmax=None, seed=0, aniso=(1.0, 1.0)):
    """Gaussian random field, periodic on an n x n tile, unit std, zero mean.

    Amplitude spectrum ~ f^-power, band-limited (soft) to [fmin, fmax] cycles per tile.
    aniso scales the frequency axes (x, y): a small x factor stretches features along x.
    """
    rng = np.random.default_rng(seed)
    fx = np.fft.fftfreq(n, d=1.0 / n).astype(F32) * aniso[0]
    fy = np.fft.fftfreq(n, d=1.0 / n).astype(F32) * aniso[1]
    f = np.sqrt(fx[None, :] ** 2 + fy[:, None] ** 2)
    f[0, 0] = 1.0
    amp = f ** (-power)
    amp *= 1.0 - np.exp(-(f / fmin) ** 2)
    if fmax is not None:
        amp *= np.exp(-(f / fmax) ** 2)
    amp[0, 0] = 0.0
    spec = amp * (rng.standard_normal((n, n)) + 1j * rng.standard_normal((n, n)))
    field = np.real(np.fft.ifft2(spec)).astype(F32)
    field -= field.mean()
    field /= field.std() + 1e-12
    return field


def sample_wrap(tex, x, y):
    """Bilinear sample of a periodic 2D texture at float texel coords (x = column, y = row)."""
    h, w = tex.shape
    x0f = np.floor(x)
    y0f = np.floor(y)
    fx = (x - x0f).astype(F32)
    fy = (y - y0f).astype(F32)
    x0 = np.mod(x0f.astype(np.int64), w)
    y0 = np.mod(y0f.astype(np.int64), h)
    x1 = (x0 + 1) % w
    y1 = (y0 + 1) % h
    a = tex[y0, x0] * (1 - fx) + tex[y0, x1] * fx
    b = tex[y1, x0] * (1 - fx) + tex[y1, x1] * fx
    return a * (1 - fy) + b * fy


def save_rgb_jpg(lin_rgb, name, quality=88, seed=1, subsampling=2):
    """Linear RGB float -> dithered sRGB JPG."""
    rng = np.random.default_rng(seed)
    s = linear_to_srgb(lin_rgb) * 255.0
    # Triangular dither (+-1 LSB) against banding in the very smooth gradients.
    s += (rng.random(s.shape, dtype=F32) - rng.random(s.shape, dtype=F32))
    img = Image.fromarray(np.clip(np.rint(s), 0, 255).astype(np.uint8), "RGB")
    path = os.path.join(OUT, name)
    img.save(path, "JPEG", quality=quality, subsampling=subsampling, optimize=True, progressive=False)
    report(path)


def half(img):
    """2x2 box downsample (keeps periodic tiling exact)."""
    return 0.25 * (img[0::2, 0::2] + img[1::2, 0::2] + img[0::2, 1::2] + img[1::2, 1::2])


def save_gray_png(values01, name):
    img = Image.fromarray(np.clip(np.rint(values01 * 255.0), 0, 255).astype(np.uint8), "L")
    path = os.path.join(OUT, name)
    img.save(path, "PNG", optimize=True)
    report(path)


def save_rgb_png(values01, name):
    img = Image.fromarray(np.clip(np.rint(values01 * 255.0), 0, 255).astype(np.uint8), "RGB")
    path = os.path.join(OUT, name)
    img.save(path, "PNG", optimize=True)
    report(path)


def report(path):
    print(f"  wrote {os.path.basename(path):34s} {os.path.getsize(path) / 1e6:6.2f} MB")


def mean_albedo_srgb(lin_rgb):
    m = lin_rgb.reshape(-1, 3).mean(axis=0)
    s = linear_to_srgb(m)
    return tuple(round(float(v), 3) for v in s)


# ----------------------------------------------------------------------------
# Sky
# ----------------------------------------------------------------------------

def sky_directions(rows):
    """Unit view directions for the given image rows (all columns)."""
    v = (rows.astype(F32) + 0.5) / SKY_H
    u = (np.arange(SKY_W, dtype=F32) + 0.5) / SKY_W
    elev = (0.5 - v) * np.pi  # +pi/2 at the top row
    azim = 2.0 * np.pi * u - np.pi  # 0 at the image centre ("front", -Z)
    ce = np.cos(elev)[:, None]
    dx = np.sin(azim)[None, :] * ce
    dy = np.broadcast_to(np.sin(elev)[:, None], dx.shape)
    dz = -np.cos(azim)[None, :] * ce
    return dx.astype(F32), np.ascontiguousarray(dy, dtype=F32), dz.astype(F32)


def sun_vector(elev_deg):
    e = np.radians(elev_deg)
    return np.array([0.0, np.sin(e), -np.cos(e)], dtype=F32)  # azimuth 0 = image centre


def angle_to(dx, dy, dz, s):
    c = np.clip(dx * s[0] + dy * s[1] + dz * s[2], -1.0, 1.0)
    return np.arccos(c).astype(F32)


def render_sky(shade_fn, band=128):
    out = np.zeros((SKY_H, SKY_W, 3), dtype=F32)
    for r0 in range(0, SKY_H, band):
        rows = np.arange(r0, min(r0 + band, SKY_H))
        dx, dy, dz = sky_directions(rows)
        out[r0:r0 + len(rows)] = shade_fn(dx, dy, dz)
    return out


def elevation_profile(e, stops, soften_deg=4.0):
    """Smooth colour profile over elevation (radians). stops: [(elev_deg, lin_rgb)] ascending.

    Piecewise-linear between stops, then blurred along elevation so there are no Mach bands
    at the stops (smoothstep segments leave visible flat bands on a 4K dome)."""
    table_e = np.linspace(-10.0, 90.0, 2001, dtype=F32)  # 0.05 deg steps
    xs = [st[0] for st in stops]
    table = np.stack([np.interp(table_e, xs, [st[1][c] for st in stops]) for c in range(3)], -1).astype(F32)
    if soften_deg > 0:
        sig = soften_deg / 0.05
        r = int(3 * sig)
        k = np.exp(-0.5 * (np.arange(-r, r + 1) / sig) ** 2)
        k /= k.sum()
        padded = np.concatenate([np.repeat(table[:1], r, 0), table, np.repeat(table[-1:], r, 0)])
        table = np.stack([np.convolve(padded[:, c], k, mode="valid") for c in range(3)], -1).astype(F32)
    ed = np.clip(np.degrees(e), -10.0, 90.0)
    idx = (ed + 10.0) / 0.05
    i0 = np.clip(np.floor(idx).astype(np.int64), 0, len(table_e) - 2)
    t = (idx - i0)[..., None].astype(F32)
    return table[i0] * (1 - t) + table[i0 + 1] * t


def below_horizon(dy, horizon_lin, ground_lin, nadir_lin, haze_deg=2.5):
    """Hazy distant ground under the horizon (only seen past the floor fade or when flying up)."""
    e = -np.degrees(np.arcsin(np.clip(dy, -1, 1)))  # positive below the horizon
    g = np.exp(-np.maximum(e, 0) / haze_deg)[..., None]
    base = mix(ground_lin, nadir_lin, smoothstep(10.0, 90.0, e)[..., None])
    return mix(base, horizon_lin, g)


class CloudField:
    """Clouds on a flat layer above the viewer; periodic noise sampled in layer coordinates,
    so there is no seam at u = 0/1 and no pinching at the zenith."""

    def __init__(self, seed, n=1024, power=1.4, fmin=1.5, fmax=160, aniso=(1.0, 1.0),
                 detail_power=0.9, detail_band=(28, 420), detail_amp=0.30,
                 warp_fmax=6.0, warp_amp=18.0):
        self.n = n
        self.base = spectral_noise(n, power=power, fmin=fmin, fmax=fmax, seed=seed, aniso=aniso)
        self.detail = spectral_noise(n, power=detail_power, fmin=detail_band[0], fmax=detail_band[1],
                                     seed=seed + 1, aniso=aniso)
        self.wx = spectral_noise(n, power=1.2, fmin=1.0, fmax=warp_fmax, seed=seed + 2)
        self.wy = spectral_noise(n, power=1.2, fmin=1.0, fmax=warp_fmax, seed=seed + 3)
        self.warp_amp = warp_amp
        self.detail_amp = detail_amp

    def density(self, qx, qz, scale, footprint):
        """footprint: texels per pixel, to drop detail where it would alias."""
        x = qx * scale
        y = qz * scale
        x = x + sample_wrap(self.wx, x, y) * self.warp_amp
        y = y + sample_wrap(self.wy, x, y) * self.warp_amp
        d = sample_wrap(self.base, x, y)
        lod = np.clip(1.0 - (footprint * 2.0 - 0.5) / 2.5, 0.0, 1.0)
        d = d + self.detail_amp * lod * sample_wrap(self.detail, x * 1.3, y * 1.3)
        return d


def layer_coords(dx, dy, dz, min_elev_deg=0.6):
    s = np.maximum(dy, np.sin(np.radians(min_elev_deg)))
    return dx / s, dz / s, s


def sky_daylight():
    sun = sun_vector(SUN_ELEVATION_DEG["daylight"])
    zen = col(0.11, 0.35, 0.78)
    mid = col(0.30, 0.54, 0.88)
    low = col(0.60, 0.76, 0.93)
    hor = col(0.84, 0.89, 0.95)
    ground = col(0.50, 0.51, 0.52)
    nadir = col(0.32, 0.33, 0.34)
    sun_col = col(1.0, 0.97, 0.90)
    direct = col(1.0, 0.98, 0.95)
    ambient = col(0.58, 0.64, 0.76)
    clouds = CloudField(seed=11, power=1.45, fmin=1.2, fmax=140, detail_amp=0.32, warp_fmax=5.0, warp_amp=22.0)
    scale = 46.0  # texels per layer unit (layer height = 1)
    sun_h = np.array([sun[0], sun[2]], dtype=F32)
    sun_h /= np.linalg.norm(sun_h) + 1e-9
    cover = 0.45

    def shade(dx, dy, dz):
        e = np.arcsin(np.clip(dy, -1, 1))
        ed = np.degrees(e)
        sky = elevation_profile(e, [(0.0, hor), (6.0, low), (24.0, mid), (75.0, zen)])
        g = angle_to(dx, dy, dz, sun)
        glow = (0.55 * np.exp(-g / 0.05) + 0.22 * np.exp(-g / 0.30) + 0.06 * np.exp(-g / 1.0))[..., None]
        sky = sky + glow * sun_col * 0.9

        # Clouds: soft-thresholded density, crude light march towards the sun through the layer.
        qx, qz, s = layer_coords(dx, dy, dz)
        footprint = scale * (np.pi / SKY_H) / np.maximum(s, 0.01) ** 2
        dens = clouds.density(qx, qz, scale, footprint)
        alpha = smoothstep(cover, cover + 0.75, dens)
        tau = np.zeros_like(dens)
        for step in (0.025, 0.06, 0.11, 0.18):
            d2 = clouds.density(qx + sun_h[0] * step, qz + sun_h[1] * step, scale, footprint)
            tau += np.maximum(d2 - cover, 0.0)
        # "Tops": density falls off towards the zenith point -> the upper rim of each cloud is lit.
        d_up = clouds.density(qx * 0.96, qz * 0.96, scale, footprint)
        rim = np.clip((dens - d_up) * 2.5, 0.0, 1.0)
        shadow = np.exp(-tau * 0.55)
        thick = smoothstep(cover, cover + 2.0, dens)
        lum_direct = np.clip(shadow * (0.85 + 0.35 * rim) * (1.0 - 0.35 * thick), 0, 1.2)
        ccol = ambient[None, None, :] * (0.78 - 0.18 * thick)[..., None] + direct * (0.80 * lum_direct)[..., None]
        # Forward scattering: thin edges near the sun glow.
        ccol = ccol + (np.exp(-g / 0.30) * (1.0 - alpha) * 0.9)[..., None] * sun_col
        # Aerial perspective: distant clouds dissolve into the horizon haze.
        haze = smoothstep(1.5, 20.0, ed)
        ccol = mix(hor * 0.97, ccol, (0.15 + 0.85 * haze)[..., None])
        fade = smoothstep(0.8, 8.0, ed) * (1.0 - smoothstep(60.0, 80.0, ed))
        a = (alpha * fade)[..., None]
        sky = mix(sky, ccol, a)

        disk = (1.0 - smoothstep(0.0045, 0.0065, g))[..., None]
        sky = mix(sky, np.array([1.0, 1.0, 1.0], F32), disk)

        under = below_horizon(dy, hor, ground, nadir)
        return np.where((dy < 0)[..., None], under, sky)

    return render_sky(shade)


def sky_sunset():
    sun = sun_vector(SUN_ELEVATION_DEG["sunset"])
    zen = col(0.09, 0.10, 0.30)
    upper = col(0.24, 0.20, 0.46)
    mid_far = col(0.62, 0.42, 0.60)
    low_far = col(0.86, 0.56, 0.56)
    hor_far = col(0.88, 0.62, 0.52)
    mid_near = col(0.78, 0.46, 0.46)
    low_near = col(1.00, 0.58, 0.32)
    hor_near = col(1.00, 0.72, 0.38)
    ground = col(0.30, 0.22, 0.22)
    nadir = col(0.14, 0.11, 0.12)
    sun_col = col(1.0, 0.80, 0.48)
    cirrus = CloudField(seed=23, power=1.0, fmin=2.0, fmax=400, aniso=(0.12, 1.0), detail_band=(40, 500), detail_amp=0.35, warp_fmax=4.0, warp_amp=10.0)
    scale = 42.0

    def shade(dx, dy, dz):
        e = np.arcsin(np.clip(dy, -1, 1))
        ed = np.degrees(e)
        # Azimuthal proximity to the sun (1 towards it, 0 opposite).
        hlen = np.sqrt(dx * dx + dz * dz) + 1e-6
        caz = (dx * sun[0] + dz * sun[2]) / (hlen * np.hypot(sun[0], sun[2]))
        near = ((caz + 1.0) * 0.5) ** 2.2
        far_prof = elevation_profile(e, [(0.0, hor_far), (5.0, low_far), (18.0, mid_far), (40.0, upper), (85.0, zen)])
        near_prof = elevation_profile(e, [(0.0, hor_near), (6.0, low_near), (20.0, mid_near), (42.0, upper), (85.0, zen)])
        sky = mix(far_prof, near_prof, near[..., None])

        g = angle_to(dx, dy, dz, sun)
        glow = (0.9 * np.exp(-g / 0.04) + 0.45 * np.exp(-g / 0.18) + 0.18 * np.exp(-g / 0.6))[..., None]
        sky = sky + glow * sun_col

        qx, qz, s = layer_coords(dx, dy, dz)
        footprint = scale * (np.pi / SKY_H) / np.maximum(s, 0.01) ** 2
        dens = cirrus.density(qx, qz, scale, footprint)
        alpha = smoothstep(0.55, 2.3, dens) ** 1.4
        thick = smoothstep(1.4, 2.8, dens)
        lit_near = col(1.0, 0.70, 0.42)
        lit_far = col(0.98, 0.55, 0.62)
        shadowed = col(0.42, 0.28, 0.45)
        ccol = mix(lit_far, lit_near, near[..., None])
        # High clouds overhead get the last pink light; thick parts go violet-grey.
        ccol = mix(ccol, shadowed, (0.55 * thick + 0.35 * smoothstep(35.0, 80.0, ed))[..., None])
        ccol = ccol + (np.exp(-g / 0.12) * 0.8)[..., None] * sun_col
        fade = smoothstep(1.0, 7.0, ed) * (1.0 - smoothstep(45.0, 75.0, ed))
        a = (alpha * fade * 0.80)[..., None]
        sky = mix(sky, ccol, a)

        disk = (1.0 - smoothstep(0.0095, 0.0125, g))[..., None]
        sky = mix(sky, col(1.0, 0.93, 0.72) * 1.0, disk)

        under = below_horizon(dy, mix(hor_far, hor_near, near[..., None]) * 0.9, ground, nadir, haze_deg=2.0)
        return np.where((dy < 0)[..., None], under, sky)

    return render_sky(shade)


def sky_studio():
    key = sun_vector(SUN_ELEVATION_DEG["studio"])
    hor = col(0.90, 0.90, 0.905)
    low = col(0.86, 0.862, 0.87)
    top = col(0.75, 0.755, 0.765)
    zen = col(0.69, 0.695, 0.705)
    floor_far = col(0.78, 0.78, 0.785)
    nadir = col(0.58, 0.58, 0.585)

    def shade(dx, dy, dz):
        e = np.arcsin(np.clip(dy, -1, 1))
        sky = elevation_profile(e, [(0.0, hor), (12.0, low), (45.0, top), (88.0, zen)])
        # Very broad, gentle key "softbox" and a subtle azimuthal vignette (back a touch darker).
        g = angle_to(dx, dy, dz, key)
        sky = sky * (1.0 + 0.10 * np.exp(-(g / 0.9) ** 2))[..., None]
        back = (1.0 - dz) * 0.5  # 0 front (-Z) .. 1 back
        sky = sky * (1.0 - 0.06 * back * smoothstep(0.0, 40.0, np.degrees(e)))[..., None]
        under = below_horizon(dy, hor, floor_far, nadir, haze_deg=4.0)
        return np.where((dy < 0)[..., None], under, sky)

    return render_sky(shade)


def sky_night():
    moon = sun_vector(SUN_ELEVATION_DEG["night"])
    zen = col(0.010, 0.016, 0.045)
    mid = col(0.020, 0.032, 0.080)
    hor = col(0.075, 0.095, 0.165)
    glow_col = col(0.20, 0.20, 0.24)
    ground = col(0.045, 0.048, 0.060)
    nadir = col(0.02, 0.02, 0.025)

    # Milky way frame: a tilted great circle that arcs across the sky behind the viewer, away from the moon.
    n_mw = np.array([0.42, 0.50, -0.76], F32)
    n_mw /= np.linalg.norm(n_mw)
    t1 = np.cross(n_mw, np.array([0, 1, 0], F32))
    t1 /= np.linalg.norm(t1)
    t2 = np.cross(n_mw, t1)
    mw_noise = spectral_noise(1024, power=1.0, fmin=2.0, fmax=300, seed=41)
    mw_dust = spectral_noise(1024, power=1.2, fmin=3.0, fmax=200, seed=42)
    moon_tex = spectral_noise(256, power=1.3, fmin=2.0, fmax=90, seed=43)

    def shade(dx, dy, dz):
        e = np.arcsin(np.clip(dy, -1, 1))
        ed = np.degrees(e)
        sky = elevation_profile(e, [(0.0, hor), (10.0, mid), (60.0, zen)])
        sky = sky + (np.exp(-np.maximum(ed, 0) / 4.0) * 0.35)[..., None] * glow_col

        # Milky way
        b = np.arcsin(np.clip(dx * n_mw[0] + dy * n_mw[1] + dz * n_mw[2], -1, 1))
        l = np.arctan2(dx * t2[0] + dy * t2[1] + dz * t2[2], dx * t1[0] + dy * t1[1] + dz * t1[2])
        lx = (l / (2 * np.pi)) * 1024.0
        by = (b / (2 * np.pi)) * 1024.0 * 2.0
        band = np.exp(-(b / 0.17) ** 2) * (0.55 + 0.45 * np.exp(-((np.mod(l - 0.9 + np.pi, 2 * np.pi) - np.pi) / 1.1) ** 2))
        clump = np.clip(0.7 + 0.45 * sample_wrap(mw_noise, lx * 2, by * 2), 0, 2)
        dust = smoothstep(0.2, 1.3, sample_wrap(mw_dust, lx * 1.4 + 77, by * 1.4)) * np.exp(-(b / 0.07) ** 2)
        mw = band * clump * (1.0 - 0.75 * dust)
        ext = smoothstep(0.0, 18.0, ed)
        sky = sky + (mw * ext * 0.045)[..., None] * col(0.78, 0.81, 0.92)

        # Moon halo + disk
        g = angle_to(dx, dy, dz, moon)
        halo = 0.30 * np.exp(-g / 0.025) + 0.07 * np.exp(-g / 0.14) + 0.02 * np.exp(-g / 0.6)
        sky = sky + halo[..., None] * col(0.75, 0.80, 0.95)
        r_moon = 0.0125
        disk = 1.0 - smoothstep(r_moon - 0.0012, r_moon + 0.0004, g)
        # Moon surface: local disk coordinates -> maria texture, gentle limb darkening.
        ux = np.cross([0, 1, 0], moon)
        ux = ux / np.linalg.norm(ux)
        uy = np.cross(moon, ux)
        mx = (dx * ux[0] + dy * ux[1] + dz * ux[2]) / r_moon
        my = (dx * uy[0] + dy * uy[1] + dz * uy[2]) / r_moon
        maria = sample_wrap(moon_tex, mx * 70 + 128, my * 70 + 128)
        rr = np.clip(mx * mx + my * my, 0, 1)
        surf = (0.92 - 0.20 * smoothstep(0.1, 1.0, maria)) * (1.0 - 0.18 * rr)
        moon_c = col(0.96, 0.95, 0.90) * surf[..., None]
        sky = mix(sky, moon_c, disk[..., None])

        under = below_horizon(dy, hor * 0.8, ground, nadir, haze_deg=2.0)
        return np.where((dy < 0)[..., None], under, sky)

    img = render_sky(shade)
    add_stars(img, moon, (n_mw, t1, t2))
    return img


def add_stars(img, moon, mw_frame, count=36000, seed=7):
    rng = np.random.default_rng(seed)
    n_mw = mw_frame[0]
    # Uniform on the sphere, plus extra stars concentrated along the milky way band.
    z = rng.uniform(-0.05, 1.0, count)
    phi = rng.uniform(-np.pi, np.pi, count)
    r = np.sqrt(1 - z * z)
    dirs = np.stack([r * np.sin(phi), z, -r * np.cos(phi)], axis=1)
    extra = rng.standard_normal((count // 2, 3))
    extra -= np.outer(extra @ n_mw, n_mw) * (1.0 - 0.12)
    extra /= np.linalg.norm(extra, axis=1, keepdims=True)
    extra = extra[extra[:, 1] > -0.05]
    dirs = np.concatenate([dirs, extra])
    n = len(dirs)
    u = rng.random(n)
    bright = 0.012 + 0.10 * u ** 5 + 0.55 * u ** 40 + 0.4 * (u > 0.9992)  # few bright stars, many faint ones
    temp = rng.random(n)
    tints = np.where(temp[:, None] < 0.20, [0.82, 0.88, 1.0],
                     np.where(temp[:, None] > 0.90, [1.0, 0.86, 0.70], [1.0, 1.0, 1.0])).astype(F32)

    elev = np.arcsin(np.clip(dirs[:, 1], -1, 1))
    azim = np.arctan2(dirs[:, 0], -dirs[:, 2])
    px = (azim + np.pi) / (2 * np.pi) * SKY_W - 0.5
    py = (0.5 - elev / np.pi) * SKY_H - 0.5
    # Atmospheric extinction near the horizon, and no stars inside the moon glare.
    ext = np.clip((np.degrees(elev) - 0.5) / 12.0, 0, 1) ** 1.5
    g = np.arccos(np.clip(dirs @ moon, -1, 1))
    ext *= np.clip((g - 0.02) / 0.15, 0, 1)
    bright = bright * ext
    keep = bright > 0.0012
    px, py, bright, tints, elev = px[keep], py[keep], bright[keep], tints[keep], elev[keep]

    H, W = img.shape[:2]
    for i in range(len(px)):
        b = bright[i]
        sig = 0.42 + 0.75 * min(1.0, b / 0.6) ** 0.7
        stretch = 1.0 / max(np.cos(elev[i]), 0.03)
        sx = sig * stretch
        rx = int(np.ceil(3 * sx))
        ry = int(np.ceil(3 * sig))
        cx, cy = px[i], py[i]
        xs = np.arange(int(np.floor(cx)) - rx, int(np.floor(cx)) + rx + 2)
        ys = np.arange(int(np.floor(cy)) - ry, int(np.floor(cy)) + ry + 2)
        ys = ys[(ys >= 0) & (ys < H)]
        if len(ys) == 0:
            continue
        kx = np.exp(-0.5 * ((xs - cx) / sx) ** 2)
        ky = np.exp(-0.5 * ((ys - cy) / sig) ** 2)
        k = np.outer(ky, kx)
        k *= b / max(k.sum(), 1e-6) * (2 * np.pi * sig * sig)  # peak ~ b regardless of stretch
        img[ys[:, None], np.mod(xs, W)[None, :]] += k[..., None] * tints[i]


# ----------------------------------------------------------------------------
# Floors
# ----------------------------------------------------------------------------

def joint_distance(n=FLOOR_N, slabs=SLABS):
    """Distance in px from each pixel centre to the nearest joint line (joints on the tile edges)."""
    p = n // slabs
    c = (np.arange(n, dtype=F32) + 0.5) % p
    d1 = np.minimum(c, p - c)
    return np.minimum(d1[None, :], d1[:, None]), d1


def slab_index(n=FLOOR_N, slabs=SLABS):
    idx = np.arange(n) // (n // slabs)
    return idx[:, None] * slabs + idx[None, :]  # row-major slab id


def normal_from_height(h_px, strength=1.0):
    """Tangent-space normal (OpenGL / +Y up) from a periodic height field in pixel units."""
    hp = np.pad(h_px, 1, mode="wrap")
    # Sobel (normalised by 8 so it is a per-pixel slope).
    gx = ((hp[:-2, 2:] + 2 * hp[1:-1, 2:] + hp[2:, 2:]) - (hp[:-2, :-2] + 2 * hp[1:-1, :-2] + hp[2:, :-2])) / 8.0
    gy = ((hp[2:, :-2] + 2 * hp[2:, 1:-1] + hp[2:, 2:]) - (hp[:-2, :-2] + 2 * hp[:-2, 1:-1] + hp[:-2, 2:])) / 8.0
    # gy = dh/d(row); image rows go down while +V / green points up.
    nx = -gx * strength
    ny = gy * strength
    nz = np.ones_like(nx)
    inv = 1.0 / np.sqrt(nx * nx + ny * ny + nz * nz)
    return np.stack([nx * inv, ny * inv, nz * inv], axis=-1) * 0.5 + 0.5


def pavers():
    n = FLOOR_N
    mm_per_px = TILE_METERS * 1000.0 / n
    rng = np.random.default_rng(101)
    sid = slab_index()
    dist, _ = joint_distance()

    tone = rng.normal(0.0, 0.035, SLABS * SLABS).astype(F32)
    warmth = rng.normal(0.0, 0.010, SLABS * SLABS).astype(F32)
    offx = rng.integers(0, n, SLABS * SLABS)
    offy = rng.integers(0, n, SLABS * SLABS)
    tilt_x = rng.normal(0, 0.25, SLABS * SLABS).astype(F32)  # mm across a slab
    tilt_y = rng.normal(0, 0.25, SLABS * SLABS).astype(F32)
    lift = rng.normal(0, 0.25, SLABS * SLABS).astype(F32)

    mottle_src = spectral_noise(n, power=1.15, fmin=3.0, fmax=400, seed=102)
    cloud_src = spectral_noise(n, power=1.6, fmin=1.5, fmax=60, seed=103)
    # Per-slab shifted copies so the pattern breaks at the joints (each slab is a separate pour).
    yy, xx = np.mgrid[0:n, 0:n]
    sx = (xx + offx[sid]) % n
    sy = (yy + offy[sid]) % n
    mottle = mottle_src[sy, sx]
    clouds = cloud_src[sy, sx]
    del mottle_src, cloud_src

    speck_src = spectral_noise(n, power=0.0, fmin=200, fmax=700, seed=104)
    speck_light = smoothstep(1.7, 2.6, speck_src)
    speck_dark = smoothstep(1.9, 2.8, -speck_src)
    micro = spectral_noise(n, power=0.2, fmin=300, fmax=None, seed=105)
    stain_src = spectral_noise(n, power=1.7, fmin=2.0, fmax=90, seed=106)
    stains = smoothstep(1.1, 2.4, stain_src)
    puddle_src = spectral_noise(n, power=1.8, fmin=1.5, fmax=50, seed=107)

    base = col(0.64, 0.62, 0.585)
    k = (1.0 + tone[sid] + 0.045 * mottle + 0.035 * clouds + 0.030 * micro)[..., None]
    alb = base * k
    alb = alb * (1.0 + np.stack([warmth[sid], 0 * warmth[sid], -warmth[sid]], -1))
    alb = mix(alb, alb * 1.30, speck_light[..., None] * 0.75)
    alb = mix(alb, alb * 0.60, speck_dark[..., None] * 0.75)
    alb = mix(alb, alb * col(0.80, 0.76, 0.70) / col(0.80, 0.80, 0.80), stains[..., None] * 0.55)
    # Grime collecting along the joints.
    edge = np.exp(-dist / 14.0)[..., None]
    alb = alb * (1.0 - 0.10 * edge)
    joint_w = 1.6  # half width in px (~6 mm joints)
    joint = (1.0 - smoothstep(joint_w - 0.7, joint_w + 0.7, dist))[..., None]
    alb = mix(alb, col(0.20, 0.195, 0.19), joint)

    # Height (mm): lippage per slab, 2 mm chamfer, 3 mm deep joint, faint surface relief.
    p = n // SLABS
    lx = ((xx % p) / p - 0.5).astype(F32)
    ly = ((yy % p) / p - 0.5).astype(F32)
    h = lift[sid] + tilt_x[sid] * lx + tilt_y[sid] * ly
    h = h + 0.035 * clouds + 0.010 * micro + 0.015 * mottle
    chamfer_px = 2.0 / mm_per_px
    h = h - 1.2 * (1.0 - smoothstep(joint_w, joint_w + chamfer_px, dist))
    h = h - 2.0 * joint[..., 0]
    normal = normal_from_height(h / mm_per_px, strength=1.0)

    rough = 0.40 + 0.025 * mottle + 0.035 * clouds + 0.015 * micro + 0.10 * stains
    rough = rough + 0.06 * speck_dark
    rough = mix(rough, 0.95, joint[..., 0])

    # Night: same slabs, wet. Darker albedo, water films in low spots, low roughness.
    wet = smoothstep(-0.2, 1.2, puddle_src)
    alb_wet = alb * (0.62 - 0.12 * wet[..., None]) * col(0.93, 0.95, 1.0) / col(0.95, 0.95, 0.95)
    rough_wet = 0.30 - 0.22 * wet + 0.015 * micro + 0.05 * stains * (1 - wet)
    rough_wet = mix(rough_wet, 0.45, joint[..., 0])

    return alb, normal, np.clip(rough, 0.03, 1.0), alb_wet, np.clip(rough_wet, 0.03, 1.0)


def epoxy():
    n = FLOOR_N
    px_per_m = n / TILE_METERS
    dist, d1 = joint_distance()  # grid lines at the 1 m slab edges
    mottle = spectral_noise(n, power=1.5, fmin=1.5, fmax=200, seed=201)
    fine = spectral_noise(n, power=0.4, fmin=150, fmax=None, seed=202)
    peel = spectral_noise(n, power=0.6, fmin=60, fmax=500, seed=203)

    base = col(0.70, 0.70, 0.705)
    alb = base * (1.0 + 0.020 * mottle + 0.008 * fine)[..., None]
    line_w = 1.1
    line = 1.0 - smoothstep(line_w - 0.6, line_w + 0.6, dist)
    # 10 cm ticks along each line (short marks either side), slightly stronger at the 50 cm mark.
    yy, xx = np.mgrid[0:n, 0:n]
    step = px_per_m / 10.0
    p = n // SLABS

    def ticks(along, across_d):
        t = (along + 0.5) % step
        tdist = np.minimum(t, step - t)
        half = (along + 0.5) % p
        is_half = np.abs(np.minimum(half, p - half) - p / 2) < step / 2
        length = np.where(is_half, 14.0, 7.0)  # px (~2.7 cm / 1.4 cm)
        return (1.0 - smoothstep(0.5, 1.3, tdist)) * (1.0 - smoothstep(length - 1, length + 1, across_d))

    tick = np.maximum(ticks(yy, d1[None, :]), ticks(xx, d1[:, None]))
    mark = np.maximum(line, 0.8 * tick)
    alb = mix(alb, alb * 0.88, mark[..., None])
    h = 0.006 * peel + 0.01 * mottle  # mm, orange-peel only
    normal = normal_from_height(h / (TILE_METERS * 1000.0 / n), strength=1.0)
    rough = 0.58 + 0.04 * mottle + 0.02 * fine
    rough = mix(rough, 0.66, mark)
    return alb, normal, np.clip(rough, 0.03, 1.0)


def ground_fade(n=1024):
    c = (np.arange(n, dtype=F32) + 0.5) / n * 2.0 - 1.0
    r = np.sqrt(c[None, :] ** 2 + c[:, None] ** 2)
    a = 1.0 - smoothstep(0.22, 0.985, r)
    a = a ** 1.3
    return a


# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

def main(argv):
    os.makedirs(OUT, exist_ok=True)
    want = set(argv) if argv else None

    def on(name):
        return want is None or name in want

    t0 = time.time()
    for preset, fn in (("studio", sky_studio), ("daylight", sky_daylight), ("sunset", sky_sunset), ("night", sky_night)):
        if on("sky_" + preset):
            print(f"sky {preset} ...")
            img = fn()
            save_rgb_jpg(img, f"qv_env_sky_{preset}.jpg", quality=95 if preset == "studio" else 88,
                         seed=len(preset) * 7919, subsampling=0 if preset == "studio" else 2)
            del img
    if on("pavers"):
        print("pavers ...")
        alb, nrm, rough, alb_wet, rough_wet = pavers()
        save_rgb_jpg(alb, "qv_env_pavers_albedo.jpg", quality=88, seed=3)
        save_rgb_png(nrm, "qv_env_pavers_normal.png")
        save_gray_png(half(rough), "qv_env_pavers_roughness.png")  # 1024^2 is plenty for roughness
        save_rgb_jpg(alb_wet, "qv_env_pavers_wet_albedo.jpg", quality=88, seed=4)
        save_gray_png(half(rough_wet), "qv_env_pavers_wet_roughness.png")
        print("  mean albedo (sRGB) dry", mean_albedo_srgb(alb), "wet", mean_albedo_srgb(alb_wet))
        print("  mean roughness dry %.3f wet %.3f" % (rough.mean(), rough_wet.mean()))
    if on("epoxy"):
        print("epoxy ...")
        alb, nrm, rough = epoxy()
        save_rgb_jpg(alb, "qv_env_epoxy_albedo.jpg", quality=88, seed=5)
        save_rgb_png(nrm, "qv_env_epoxy_normal.png")
        save_gray_png(half(rough), "qv_env_epoxy_roughness.png")
        print("  mean albedo (sRGB)", mean_albedo_srgb(alb), "mean roughness %.3f" % rough.mean())
    if on("fade"):
        print("ground fade ...")
        # Grey AND alpha carry the same fade, so it works whichever channel is read as opacity.
        a = np.clip(np.rint(ground_fade() * 255.0), 0, 255).astype(np.uint8)
        path = os.path.join(OUT, "qv_env_ground_fade.png")
        Image.fromarray(np.stack([a, a], -1), "LA").save(path, "PNG", optimize=True)
        report(path)

    total = sum(os.path.getsize(os.path.join(OUT, f)) for f in os.listdir(OUT) if f.startswith("qv_env_"))
    print(f"total {total / 1e6:.2f} MB in {time.time() - t0:.1f} s")


if __name__ == "__main__":
    main(sys.argv[1:])
