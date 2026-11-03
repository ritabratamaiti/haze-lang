"""
Draws the Haze logo, in which the word dissolves from left to right into a LiDAR-style point
cloud. The H is solid, the A begins to melt into scan lines, the Z is mostly points and the E is
entirely point cloud. Right at a letter's melt line the points are large enough to merge into
the solid shape and share its color; further right they shrink, separate into scan rows and
take on a depth color ramp. The letters are built from straight-line geometry, so no font is
involved.

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
    yb0, yb1 = 60, 60 + S * 0.85       # crossbar between the center lines of the legs
    def centre(y, side):
        t = y / H
        return xc * (1 - t) + ((x + sw / 2) if side < 0 else (x + w - sw / 2)) * t
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
WIDTH = x - GAP + PAD + 30            # room on the right for drifting points
HEIGHT = H + 2 * PAD

# The fraction of each letter's width that stays solid. The rest melts into points.
SOLID = {"H": 1.0, "A": 0.62, "Z": 0.28, "E": 0.0}
MELT = {n: glyphs[n][1] + f * (glyphs[n][2] - glyphs[n][1]) for n, f in SOLID.items() if f < 1}

ROW_GAP, COL_GAP = 4.0, 2.3
ROWS = [ROW_GAP / 2 + k * ROW_GAP for k in range(int(H / ROW_GAP))]
R_MERGED = ROW_GAP * 0.63             # radius at which neighboring points overlap into a solid
HAZE_START = min(MELT.values())
HAZE_END = glyphs["E"][2]

def smoothstep(u):
    u = min(max(u, 0.0), 1.0)
    return u * u * (3 - 2 * u)

# ---- point cloud ------------------------------------------------------------------------------
def point_cloud(seed=11):
    """Returns a list of (x, y, radius, melt, drifting) tuples. melt is 0 where a point merges into
    the solid letter and 1 where it is a fully separate, fully colored point; drifting marks the
    stray points that float off to the right."""
    rng = random.Random(seed)
    pts = []
    for name, edge in MELT.items():
        parts, x0, x1 = glyphs[name]
        for row, y in enumerate(ROWS):
            melting = SOLID[name] > 0
            melt_len = rng.uniform(14, 22)
            xx = edge if melting else edge + COL_GAP / 2
            while xx < x1 + 2:
                d = xx - edge                                   # distance from the melt line
                u = smoothstep(d / melt_len) if melting else 1.0
                px = xx + rng.uniform(-0.3, 0.3) * u
                py = y + (0.5 * math.sin(px / 21 + row * 0.6) + rng.uniform(-0.15, 0.15)) * u
                xx += COL_GAP
                if not in_shape(parts, px, py):
                    continue
                t = (px - HAZE_START) / (HAZE_END - HAZE_START)   # progress across the haze
                r_far = 1.25 - 0.55 * t
                r = R_MERGED * (1 - u) + r_far * rng.uniform(0.85, 1.1) * u
                if u > 0.5 and rng.random() > 1 - 0.32 * t ** 1.4:
                    continue                                    # thin the points out toward the right
                pts.append((px, py + PAD, r, u, False))
                if name == "E" and u > 0.9 and rng.random() < 0.01 + 0.14 * t ** 2:
                    pts.append((px + rng.expovariate(1 / (4 + 10 * t)), py + PAD + rng.gauss(0, 1.4),
                                r * 0.6, 1.0, True))
    return pts

POINTS = point_cloud()

# depth coloring along x, like a LiDAR intensity ramp
RAMP = [(0.0, (16, 185, 129)), (0.45, (34, 211, 238)), (1.0, (99, 102, 241))]
def ramp(t):
    t = min(max(t, 0), 1)
    for (t0, c0), (t1, c1) in zip(RAMP, RAMP[1:]):
        if t <= t1:
            v = (t - t0) / (t1 - t0)
            return tuple(a + (b - a) * v for a, b in zip(c0, c1))
    return RAMP[-1][1]

def point_colour(px, melt, solid_rgb):
    c = ramp((px - HAZE_START) / (WIDTH - PAD - HAZE_START))
    m = smoothstep(melt)
    return tuple(round(s * (1 - m) + v * m) for s, v in zip(solid_rgb, c))

def opacity(px):
    return 1.0 if px <= HAZE_END else max(0.25, 1 - (px - HAZE_END) / 26)

def hex_rgb(h):
    return tuple(int(h[i:i + 2], 16) for i in (1, 3, 5))

# ---- SVG ------------------------------------------------------------------------------------------
def svg(solid_fill):
    f = lambda v: f"{v:.2f}".rstrip("0").rstrip(".")
    solid_rgb = hex_rgb(solid_fill)
    def path(parts):
        return "".join("M" + "L".join(f"{f(px)},{f(py + PAD)}" for px, py in p) + "Z" for p in parts)
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {f(WIDTH)} {f(HEIGHT)}" '
           f'width="{f(WIDTH * 4)}" height="{f(HEIGHT * 4)}" role="img" aria-label="Haze">',
           '<title>Haze</title><defs>']
    for n in MELT:
        if SOLID[n] > 0:
            out.append(f'<clipPath id="solid{n}"><rect x="0" y="0" width="{f(MELT[n])}" height="{f(HEIGHT)}"/></clipPath>')
        out.append(f'<clipPath id="shape{n}"><path d="{path(glyphs[n][0])}"/></clipPath>')
    out.append(f'</defs><g fill="{solid_fill}">')
    for n, frac in SOLID.items():
        if frac == 1:
            out.append(f'<path d="{path(glyphs[n][0])}"/>')
        elif frac > 0:
            out.append(f'<path clip-path="url(#solid{n})" d="{path(glyphs[n][0])}"/>')
    out.append('</g>')
    def circle(px, py, r, melt):
        c = point_colour(px, melt, solid_rgb)
        o = opacity(px)
        op = "" if o >= 0.999 else f' fill-opacity="{f(o)}"'
        return f'<circle cx="{f(px)}" cy="{f(py)}" r="{f(r)}" fill="#{c[0]:02x}{c[1]:02x}{c[2]:02x}"{op}/>'
    for n in MELT:
        x0, x1 = glyphs[n][1], glyphs[n][2]
        out.append(f'<g clip-path="url(#shape{n})">')
        out += [circle(px, py, r, m) for px, py, r, m, dr in POINTS if not dr and x0 - 3 <= px <= x1 + 3
                and in_shape(glyphs[n][0], px, py - PAD)]
        out.append('</g>')
    out.append('<g>')
    out += [circle(px, py, r, m) for px, py, r, m, dr in POINTS if dr]
    out.append('</g></svg>')
    return "\n".join(out) + "\n"

# ---- PNG preview (PIL, supersampled) -------------------------------------------------------------
def png(path, solid_fill, background, scale=4):
    from PIL import Image, ImageDraw
    k = scale * 4                                    # supersampling factor
    W, Hh = int(WIDTH * k), int(HEIGHT * k)
    solid_rgb = hex_rgb(solid_fill)
    img = Image.new("RGBA", (W, Hh), background)
    def poly(draw, parts, fill):
        for p in parts:
            draw.polygon([(px * k, (py + PAD) * k) for px, py in p], fill=fill)
    for n, frac in SOLID.items():
        if frac == 0:
            continue
        layer = Image.new("RGBA", (W, Hh), (0, 0, 0, 0))
        poly(ImageDraw.Draw(layer), glyphs[n][0], solid_rgb)
        if frac < 1:
            layer = layer.crop((0, 0, int(MELT[n] * k), Hh))
        img.alpha_composite(layer, (0, 0))
    for n in MELT:
        x0, x1 = glyphs[n][1], glyphs[n][2]
        dots = Image.new("RGBA", (W, Hh), (0, 0, 0, 0))
        dd = ImageDraw.Draw(dots)
        for px, py, r, m, dr in POINTS:
            if dr or not (x0 - 3 <= px <= x1 + 3 and in_shape(glyphs[n][0], px, py - PAD)):
                continue
            c = point_colour(px, m, solid_rgb)
            dd.ellipse([(px - r) * k, (py - r) * k, (px + r) * k, (py + r) * k], fill=c + (255,))
        mask = Image.new("L", (W, Hh), 0)
        poly(ImageDraw.Draw(mask), glyphs[n][0], 255)
        clipped = Image.new("RGBA", (W, Hh), (0, 0, 0, 0))
        clipped.paste(dots, (0, 0), mask)
        img.alpha_composite(clipped)
    drift = Image.new("RGBA", (W, Hh), (0, 0, 0, 0))
    dd = ImageDraw.Draw(drift)
    for px, py, r, m, dr in POINTS:
        if dr:
            c = point_colour(px, m, solid_rgb)
            dd.ellipse([(px - r) * k, (py - r) * k, (px + r) * k, (py + r) * k],
                       fill=c + (round(255 * opacity(px)),))
    img.alpha_composite(drift)
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
