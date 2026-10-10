"""Generates the Wong AutoGate launcher icon at every required density.

Design: a sliding gate leaf between two pillars with a radio wave leaving
the top-right, signalling "remote controlled". Colours follow the app theme
(navy #0F172A / #0B0F19, cyan #38BDF8, indigo #818CF8).

Every variant is rendered oversized, cropped to its alpha bounding box and
re-centred, so the whole composition (gate *and* waves) stays balanced and
inside the platform's safe zone rather than just the gate alone.
"""
import os

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "android", "app", "src", "main", "res")
IOS = os.path.join(ROOT, "ios", "Runner", "Assets.xcassets", "AppIcon.appiconset")

NAVY_TOP = (15, 23, 42)       # #0F172A
NAVY_BOTTOM = (11, 15, 25)    # #0B0F19
CYAN = (56, 189, 248)         # #38BDF8
CYAN_DEEP = (2, 132, 199)     # #0284C7
INDIGO = (129, 140, 248)      # #818CF8

SS = 4      # supersampling factor for smooth edges
FIT = 2.0   # render canvas multiple, then shrink into the target


def gradient(n):
    """Vertical linear gradient as an RGBA image."""
    strip = Image.new("RGB", (1, n))
    px = strip.load()
    for y in range(n):
        t = y / max(n - 1, 1)
        px[0, y] = tuple(
            int(NAVY_TOP[i] + (NAVY_BOTTOM[i] - NAVY_TOP[i]) * t) for i in range(3)
        )
    return strip.resize((n, n), Image.NEAREST).convert("RGBA")


def render_mark(n, background=True, silhouette=None):
    """Renders the artwork on an n x n canvas, no size constraint.

    `silhouette` forces every stroke to a single flat colour, which is what
    Android's themed (monochrome) icon layer needs.
    """
    img = gradient(n) if background else Image.new("RGBA", (n, n), (0, 0, 0, 0))
    layer = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)

    def tone(base, accent):
        return silhouette or accent

    cx = cy = n / 2
    half_w = n * 0.255
    gate_h = n * 0.44
    top, bottom = cy - gate_h / 2, cy + gate_h / 2
    pillar_w = n * 0.052
    rail_h = n * 0.048
    slat_h = n * 0.042
    left, right = cx - half_w, cx + half_w

    # Pillars.
    d.rounded_rectangle([left, top, left + pillar_w, bottom],
                        radius=pillar_w / 2, fill=tone(CYAN, CYAN))
    d.rounded_rectangle([right - pillar_w, top, right, bottom],
                        radius=pillar_w / 2, fill=tone(CYAN, CYAN))

    # Three slats, the middle one accented.
    gap = (bottom - top - rail_h * 2 - slat_h * 3) / 2
    for i in range(3):
        y0 = top + rail_h + i * (slat_h + gap)
        d.rounded_rectangle([left + pillar_w, y0, right - pillar_w, y0 + slat_h],
                            radius=slat_h / 2,
                            fill=tone(CYAN_DEEP, INDIGO if i == 1 else CYAN_DEEP))

    # Radio wave leaving the top-right of the gate.
    wx = cx + half_w * 0.80
    wy = top - n * 0.030
    for i, rad in enumerate((0.105, 0.165, 0.225)):
        r = n * rad
        d.arc([wx - r, wy - r, wx + r, wy + r], start=-72, end=72,
              fill=tone(INDIGO if i == 2 else CYAN, CYAN),
              width=max(int(n * 0.020), 2))
    dot = n * 0.020
    d.ellipse([wx - dot, wy - dot, wx + dot, wy + dot],
              fill=tone(CYAN, CYAN))

    img.alpha_composite(layer)
    return img


def place(mark, canvas, safe_fraction):
    """Crops to the artwork, then centres and scales it into `canvas`.

    The bounding box is circumscribed with a circle so nothing grazes the
    edge no matter how the platform masks the icon.
    """
    bbox = mark.split()[3].getbbox()
    if bbox is None:
        return mark.resize((canvas, canvas), Image.LANCZOS)
    art = mark.crop(bbox)
    w, h = art.size
    radius = (w * w + h * h) ** 0.5 / 2
    scale = min(1.0, (canvas * safe_fraction / 2) / radius)
    art = art.resize((max(round(w * scale), 1), max(round(h * scale), 1)),
                     Image.LANCZOS)
    out = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    out.alpha_composite(art, ((canvas - art.size[0]) // 2,
                              (canvas - art.size[1]) // 2))
    return out


def build(px, *, background, safe_fraction, silhouette=None, round_corners=False):
    """Renders one finished icon at px x px."""
    big = px * SS * (2 if px * SS * 2 <= 4096 else 1)
    art = place(render_mark(big, background, silhouette), big, safe_fraction * FIT)
    art = art.resize((px, px), Image.LANCZOS)
    if round_corners:
        mask = Image.new("L", (px * SS, px * SS), 0)
        ImageDraw.Draw(mask).rounded_rectangle(
            [0, 0, px * SS - 1, px * SS - 1], radius=int(px * SS * 0.22), fill=255)
        out = Image.new("RGBA", (px, px), (0, 0, 0, 0))
        out.paste(art, (0, 0), mask.resize((px, px), Image.LANCZOS))
        return out
    return art


def write(path, img):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path, "PNG", optimize=True)
    print(f"  {os.path.relpath(path, ROOT)}  {img.size[0]}x{img.size[1]}")


ANDROID = (("mipmap-mdpi", 48), ("mipmap-hdpi", 72), ("mipmap-xhdpi", 96),
           ("mipmap-xxhdpi", 144), ("mipmap-xxxhdpi", 192))
ADAPTIVE = (("mipmap-mdpi", 108), ("mipmap-hdpi", 162), ("mipmap-xhdpi", 216),
            ("mipmap-xxhdpi", 324), ("mipmap-xxxhdpi", 432))
IOS_SET = (("Icon-App-20x20@1x.png", 20), ("Icon-App-20x20@2x.png", 40),
           ("Icon-App-20x20@3x.png", 60), ("Icon-App-29x29@1x.png", 29),
           ("Icon-App-29x29@2x.png", 58), ("Icon-App-29x29@3x.png", 87),
           ("Icon-App-40x40@1x.png", 40), ("Icon-App-40x40@2x.png", 80),
           ("Icon-App-40x40@3x.png", 120), ("Icon-App-60x60@2x.png", 120),
           ("Icon-App-60x60@3x.png", 180), ("Icon-App-76x76@1x.png", 76),
           ("Icon-App-76x76@2x.png", 152), ("Icon-App-83.5x83.5@2x.png", 167),
           ("Icon-App-1024x1024@1x.png", 1024))


def main():
    # Legacy Android icons: the launcher masks these, so round them ourselves.
    # 0.86 keeps the artwork clear of every OEM mask.
    print("Android legacy icons:")
    for folder, px in ANDROID:
        write(os.path.join(RES, folder, "ic_launcher.png"),
              build(px, background=True, safe_fraction=0.86, round_corners=True))

    # Adaptive foreground: transparent, must fit the 66dp (61%) safe circle.
    print("Android adaptive foregrounds:")
    for folder, px in ADAPTIVE:
        write(os.path.join(RES, folder, "ic_launcher_foreground.png"),
              build(px, background=False, safe_fraction=0.60))

    # Themed icon layer for Android 13+, tinted by the system.
    print("Android monochrome layers:")
    for folder, px in ADAPTIVE:
        write(os.path.join(RES, folder, "ic_launcher_monochrome.png"),
              build(px, background=False, safe_fraction=0.60, silhouette=(0, 0, 0, 255)))

    # iOS masks with its own squircle, so ship full-bleed squares.
    print("iOS icons:")
    for name, px in IOS_SET:
        write(os.path.join(IOS, name),
              build(px, background=True, safe_fraction=0.86).convert("RGB"))

    write(os.path.join(ROOT, "assets", "icon_master.png"),
          build(1024, background=True, safe_fraction=0.86).convert("RGB"))


if __name__ == "__main__":
    main()
