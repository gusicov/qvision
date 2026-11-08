"""Generates the layered visionOS app icon (Back / Middle / Front, 1024x1024)
and the asset-catalog JSON for App/Assets.xcassets.

    python tools/make_icon.py

Replace the PNGs in App/Assets.xcassets/AppIcon.solidimagestack/*/Content.imageset/
with your own art any time (Back must be opaque, Middle/Front may be transparent).
"""
import json
import pathlib

from PIL import Image, ImageDraw

ROOT = pathlib.Path(__file__).resolve().parents[1]
CAT = ROOT / "App" / "Assets.xcassets"
S = 1024
INFO = {"author": "xcode", "version": 1}


def back() -> Image.Image:
    img = Image.new("RGB", (S, S))
    d = ImageDraw.Draw(img)
    top, bottom = (14, 22, 38), (18, 92, 110)
    for y in range(S):
        t = y / (S - 1)
        d.line([(0, y), (S, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)))
    return img


def middle() -> Image.Image:
    """A stage floor: elliptical platform with a perspective grid."""
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    box = (150, 610, 874, 860)
    d.ellipse(box, fill=(255, 255, 255, 38), outline=(255, 255, 255, 150), width=6)
    cx, cy = 512, 735
    for i in range(-4, 5):
        d.line([(cx + i * 30, cy - 120), (cx + i * 85, cy + 120)], fill=(255, 255, 255, 60), width=3)
    for j in range(1, 4):
        w = 260 + j * 75
        y = cy - 120 + j * 60
        d.line([(cx - w, y), (cx + w, y)], fill=(255, 255, 255, 50), width=3)
    return img


def front() -> Image.Image:
    """An isometric cube standing on the stage."""
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    cx, top, a, h = 512, 220, 230, 300
    t = (cx, top)
    r = (cx + a, top + a * 0.58)
    l = (cx - a, top + a * 0.58)
    c = (cx, top + a * 1.16)
    d.polygon([t, r, c, l], fill=(232, 250, 252, 255))                                   # top
    d.polygon([l, c, (c[0], c[1] + h), (l[0], l[1] + h)], fill=(38, 170, 190, 255))      # left
    d.polygon([c, r, (r[0], r[1] + h), (c[0], c[1] + h)], fill=(20, 120, 140, 255))      # right
    return img


def write_layer(name: str, image: Image.Image) -> str:
    folder = CAT / "AppIcon.solidimagestack" / f"{name}.solidimagestacklayer"
    imageset = folder / "Content.imageset"
    imageset.mkdir(parents=True, exist_ok=True)
    png = f"{name.lower()}.png"
    image.save(imageset / png)
    (folder / "Contents.json").write_text(json.dumps({"info": INFO}, indent=2))
    (imageset / "Contents.json").write_text(json.dumps(
        {"images": [{"filename": png, "idiom": "vision", "scale": "2x"}], "info": INFO}, indent=2))
    return f"{name}.solidimagestacklayer"


def main() -> None:
    CAT.mkdir(parents=True, exist_ok=True)
    (CAT / "Contents.json").write_text(json.dumps({"info": INFO}, indent=2))
    layers = [write_layer("Front", front()), write_layer("Middle", middle()), write_layer("Back", back())]
    (CAT / "AppIcon.solidimagestack" / "Contents.json").write_text(json.dumps(
        {"info": INFO, "layers": [{"filename": f} for f in layers]}, indent=2))

    accent = CAT / "AccentColor.colorset"
    accent.mkdir(exist_ok=True)
    (accent / "Contents.json").write_text(json.dumps({
        "colors": [{"idiom": "universal", "color": {"color-space": "srgb", "components": {
            "red": "0.150", "green": "0.670", "blue": "0.750", "alpha": "1.000"}}}],
        "info": INFO}, indent=2))

    preview = back().convert("RGBA")
    preview.alpha_composite(middle())
    preview.alpha_composite(front())
    preview.save(ROOT / "tools" / "icon-preview.png")
    print("Icon written to", CAT)


if __name__ == "__main__":
    main()
