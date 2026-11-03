"""
Generates the Haze logo: the letters H and A are solid, Z dissolves halfway into a LiDAR-style
point cloud, and E is a point cloud entirely. Letters are built from straight-line geometry, so
no font is involved.

    python scripts/make_logo.py

writes docs/images/logo-light.svg and docs/images/logo-dark.svg (for light and dark page
backgrounds) and PNG previews next to them.
"""
import math, pathlib, random

OUT = pathlib.Path(__file__).resolve().parent.parent / "docs" / "images"

H = 100.0          # cap height
S = 21.0           # stroke width
GAP = 15.0         # space between letters
PAD = 12.0         # margin around the wordmark

# ---- geometry ------------------------------------------------------------------------------
def rect(x0, y0, x1, y1):
    return [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]

def letter_H(x, w=78):
    return [rect(x, 0, x + S, H), rect(x + w - S, 0, x + w, H), rect(x, 40, x + w, 40 + S)], w

def letter_A(x, w=88):
    sw = S * 1.18                      # horizontal width of a slanted stroke
    xc = x + w / 2
    left = [(x, H), (x + sw, H), (xc + sw / 2, 0), (xc - sw / 2, 0)]
    right = [(x + w - sw, H), (x + w, H), (xc + sw / 2, 0), (xc - sw / 2, 0)]
    # crossbar between the centre lines of the legs
    yb0, yb1 = 60, 60 + S * 0.85
    def centre(y, side):
        t = y / H
        if side < 0:
            return (xc) * (1 - t) + (x + sw / 2) * t
        return (xc) * (1 - t) + (x + w - sw / 2) * t
    bar = [(centre(yb0, -1), yb0), (centre(yb0, 1), yb0), (centre(yb1, 1), yb1), (centre(yb1, -1), yb1)]
    return [left, right, bar], w

def letter_Z(x, w=76):
    sw = S * 1.25
    return [rect(x, 0, x + w, S), rect(x, H - S, x + w, H),
            [(x + w - sw, S), (x + w, S), (x + sw, H - S), (x, H - S)]], w

def letter_E(x, w=66):
    return [rect(x, 0, x + S, H), rect(x, 0, x + w, S), rect(x, 40, x + w * 0.86, 40 + S),
            rect(x, H - S, x + w, H)], w

def inside(poly, px, py):
    """Point in a convex polygon (vertices in either orientation)."""
    sign = 0
    n = len(poly)
    for i in range(n):
        (x0, y0), (x1, y1) = poly[i], poly[(i + 1) % n]
        c = (x1 - x0) * (py - y0) - (y1 - y0) * (px - x0)
        if c != 0:
            s = 1 if c > 0 else -1
            if sign == 0: sign = s
            elif s != sign: return False
    return True

def in_shape(parts, px, py):
    return any(inside(p, px, py) for p in parts)

# ---- layout ----------------------------------------------------------------------------------
x = PAD
glyphs = {}
for name, make in (("H", letter_H), ("A", letter_A), ("Z", letter_Z), ("E", letter_E)):
    parts, w = make(x)
    glyphs[name] = (parts, x, x + w)
    x += w + GAP
WIDTH = x - GAP + PAD + 34            # extra room on the right for drifting points
HEIGHT = H + 2 * PAD

z_parts, z0, z1 = glyphs["Z"]
Z_SPLIT = (z0 + z1) / 2               # Z is solid to the left of this line
e_parts, e0, e1 = glyphs["E"]

ROW_GAP, COL_GAP = 4.1, 2.45
ROWS = [1.4 + k * ROW_GAP for k in range(int((H - 1.4) / ROW_GAP) + 1)]
_edge_rng = random.Random(3)
# where the solid part of Z ends on each scan row: a ragged edge around the middle of the letter
EDGES = [Z_SPLIT + _edge_rng.uniform(-7, 4) for _ in ROWS]

# ---- point cloud ------------------------------------------------------------------------------
def point_cloud(seed=7):
    rng = random.Random(seed)
    pts = []
    row_gap, col_gap = ROW_GAP, COL_GAP
    for row, y in enumerate(ROWS):
        xx = EDGES[row] + 0.8
        while xx < e1 + 1:
            px = xx + rng.uniform(-0.35, 0.35)
            # scan rows bend slightly, like rings of a rotating LiDAR
            py = y + 0.55 * math.sin(px / 23 + row * 0.7) + rng.uniform(-0.18, 0.18)
            if px < z1 + 1 and in_shape(z_parts, px, py):
                # density falls slowly to the right
                t = max((px - Z_SPLIT) / (z1 - Z_SPLIT), 0)
                keep = 0.97 - 0.12 * t
                region = "Z"
            elif in_shape(e_parts, px, py):
                t = (px - e0) / (e1 - e0)
                keep = 0.86 - 0.3 * t
                region = "E"
            else:
                xx += col_gap; continue
            if rng.random() < keep:
                r = rng.uniform(0.82, 1.12)
                # some points drift away to the right, more of them further right
                drift = (0.03 if region == "Z" else 0.05 + 0.2 * t)
                if rng.random() < drift:
                    # a drifting copy leaves the glyph; the original point stays
                    dx = rng.expovariate(1 / (7 if region == "Z" else 13))
                    pts.append((px + dx, py + rng.gauss(0, 1.6) + PAD, r * 0.7))
                pts.append((px, py + PAD - 0, r))
            xx += col_gap
    return pts

POINTS = point_cloud()

# depth colouring along x, like a LiDAR intensity ramp
RAMP = [(0.0, (20, 184, 166)), (0.5, (34, 211, 238)), (1.0, (99, 102, 241))]
def ramp(t):
    t = min(max(t, 0), 1)
    for (t0, c0), (t1, c1) in zip(RAMP, RAMP[1:]):
        if t <= t1:
            u = (t - t0) / (t1 - t0)
            return tuple(round(a + (b - a) * u) for a, b in zip(c0, c1))
    return RAMP[-1][1]

X_MIN, X_MAX = Z_SPLIT - 8, WIDTH - PAD
def colour(px):
    return ramp((px - X_MIN) / (X_MAX - X_MIN))

def opacity(px):
    return 1.0 if px <= e1 else max(0.35, 1 - (px - e1) / 30)

# ---- SVG ------------------------------------------------------------------------------------------
def svg(solid_fill):
    f = lambda v: f"{v:.2f}".rstrip("0").rstrip(".")
    def path(parts, dy):
        return "".join("M" + "L".join(f"{f(px)},{f(py + dy)}" for px, py in p) + "Z" for p in parts)
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {f(WIDTH)} {f(HEIGHT)}" '
           f'width="{f(WIDTH * 4)}" height="{f(HEIGHT * 4)}" role="img" aria-label="Haze">',
           '<title>Haze</title>',
           '<defs><clipPath id="zsolid">' + ''.join(
               f'<rect x="0" y="{f(PAD + y - ROW_GAP / 2)}" width="{f(e)}" height="{f(ROW_GAP + 0.02)}"/>'
               for y, e in zip(ROWS, EDGES)) + '</clipPath></defs>',
           f'<g fill="{solid_fill}">',
           f'<path d="{path(glyphs["H"][0], PAD)}{path(glyphs["A"][0], PAD)}"/>',
           f'<path clip-path="url(#zsolid)" d="{path(z_parts, PAD)}"/>',
           '</g><g>']
    for px, py, r in POINTS:
        c = colour(px)
        o = opacity(px)
        op = "" if o >= 0.999 else f' fill-opacity="{f(o)}"'
        out.append(f'<circle cx="{f(px)}" cy="{f(py)}" r="{f(r)}" fill="#{c[0]:02x}{c[1]:02x}{c[2]:02x}"{op}/>')
    out.append("</g></svg>")
    return "\n".join(out) + "\n"

# ---- PNG preview (PIL, supersampled) -------------------------------------------------------------
def png(path, solid_fill, background, scale=4):
    from PIL import Image, ImageDraw
    k = scale * 4                                    # supersampling factor
    W, Hh = int(WIDTH * k), int(HEIGHT * k)
    img = Image.new("RGBA", (W, Hh), background)
    rgb = tuple(int(solid_fill[i:i + 2], 16) for i in (1, 3, 5))
    d = ImageDraw.Draw(img)
    for name in ("H", "A"):
        for p in glyphs[name][0]:
            d.polygon([(px * k, (py + PAD) * k) for px, py in p], fill=rgb)
    layer = Image.new("RGBA", (W, Hh), (0, 0, 0, 0))
    dl = ImageDraw.Draw(layer)
    for p in z_parts:
        dl.polygon([(px * k, (py + PAD) * k) for px, py in p], fill=rgb)
    mask = Image.new("L", (W, Hh), 0)
    dm = ImageDraw.Draw(mask)
    for y, e in zip(ROWS, EDGES):
        dm.rectangle([0, (PAD + y - ROW_GAP / 2) * k, e * k, (PAD + y + ROW_GAP / 2) * k], fill=255)
    clipped = Image.new("RGBA", (W, Hh), (0, 0, 0, 0))
    clipped.paste(layer, (0, 0), mask)
    img.alpha_composite(clipped)
    dots = Image.new("RGBA", (W, Hh), (0, 0, 0, 0))
    dd = ImageDraw.Draw(dots)
    for px, py, r in POINTS:
        c = colour(px)
        dd.ellipse([(px - r) * k, (py - r) * k, (px + r) * k, (py + r) * k],
                   fill=c + (round(255 * opacity(px)),))
    img.alpha_composite(dots)
    img = img.resize((int(WIDTH * scale), int(HEIGHT * scale)), Image.LANCZOS)
    img.save(path)

if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    LIGHT, DARK = "#1b2638", "#e6edf7"
    (OUT / "logo-light.svg").write_text(svg(LIGHT), encoding="utf-8", newline="\n")
    (OUT / "logo-dark.svg").write_text(svg(DARK), encoding="utf-8", newline="\n")
    png(OUT / "logo-light.png", LIGHT, (255, 255, 255, 255))
    png(OUT / "logo-dark.png", DARK, (13, 17, 23, 255))
    print(f"{len(POINTS)} points, {WIDTH:.0f} x {HEIGHT:.0f} units, written to {OUT}")
