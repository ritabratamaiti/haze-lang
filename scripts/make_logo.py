"""
Generates the Haze logo and icon.

The emblem is a disc that dissolves from left to right into a lattice of shrinking particles, like
a planet resolving into a point cloud. The wordmark spells HAZE as HΛZΞ in thin, widely spaced
capitals, and the bars of the Ξ dissolve the same way as the emblem. On dark backgrounds the
particles glow.

    python scripts/make_logo.py

writes to docs/images:
  logo-light.svg, logo-dark.svg   the emblem with the wordmark, for light and dark pages
  icon-light.svg, icon-dark.svg   the emblem alone, for avatars and favicons
and PNG versions of each.
"""
import math, pathlib, random

OUT = pathlib.Path(__file__).resolve().parent.parent / "docs" / "images"

THEMES = {
    "light": dict(bg=None, ink=(15, 23, 42), accent=(13, 148, 136), glow=0.0),
    "dark": dict(bg=None, ink=(226, 232, 240), accent=(94, 234, 212), glow=0.38),
}
PREVIEW_BG = {"light": (255, 255, 255), "dark": (9, 12, 18)}

def mix(a, b, t):
    t = max(0.0, min(1.0, t))
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))

def smooth(u):
    u = max(0.0, min(1.0, u))
    return u * u * (3 - 2 * u)

# ---- emblem -----------------------------------------------------------------------------------------
def emblem(cx, cy, R, seed=4):
    """Returns the lattice particles inside the disc and the few that drift outside it.
    Each particle is (x, y, radius, u), where u runs from 0 (merged into the solid disc) to 1."""
    rng = random.Random(seed)
    s = R * 0.105                                   # spacing of the hexagonal lattice
    inside, drift = [], []
    rows = int(2 * R / (s * 0.866)) + 2
    for j in range(-rows, rows + 1):
        y = cy + j * s * 0.866
        off = s / 2 if j % 2 else 0
        for i in range(-60, 61):
            x = cx + i * s + off
            if (x - cx) ** 2 + (y - cy) ** 2 > (R + s) ** 2:
                continue
            t = (x - (cx - R)) / (2 * R)
            u = smooth((t - 0.22) / 0.78 + rng.uniform(-0.035, 0.035))
            r = s * 0.64 * (1 - u) + s * 0.09 * u
            if u > 0.7 and rng.random() < (u - 0.7) * 1.2:
                continue
            inside.append((x, y, r, u))
    for _ in range(11):
        a = rng.uniform(-1.0, 1.0)
        d = R * rng.uniform(1.06, 1.5)
        drift.append((cx + d * math.cos(a), cy + d * math.sin(a), s * rng.uniform(0.07, 0.15), 1.0))
    return inside, drift

# ---- wordmark: H Λ Z Ξ ------------------------------------------------------------------------------
def wordmark(x0, y0, h=56.0, w=8.0, lw=44.0, track=30.0):
    """Returns the solid polygons, and the bars of the Ξ (which dissolve) as (x0, y0, x1, y1)."""
    polys, x = [], x0
    R = lambda a, b, c, d: [(a, b), (c, b), (c, d), (a, d)]
    polys += [R(x, y0, x + w, y0 + h), R(x + lw - w, y0, x + lw, y0 + h),
              R(x, y0 + h / 2 - w / 2, x + lw, y0 + h / 2 + w / 2)]
    x += lw + track
    W = lw * 1.1                                    # Λ, an A without its crossbar
    ws = w / math.sin(math.atan2(h, W / 2))
    a = ws / 2
    yin = y0 + h * (1 - (W / 2 - ws) / (W / 2 - a))
    polys.append([(x, y0 + h), (x + ws, y0 + h), (x + W / 2, yin), (x + W - ws, y0 + h), (x + W, y0 + h),
                  (x + W / 2 + a, y0), (x + W / 2 - a, y0)])
    x += W + track
    zs = w * 1.25
    polys += [R(x, y0, x + lw, y0 + w), R(x, y0 + h - w, x + lw, y0 + h),
              [(x + lw - zs, y0 + w), (x + lw, y0 + w), (x + zs, y0 + h - w), (x, y0 + h - w)]]
    x += lw + track
    bars = [(x, y0, x + lw, y0 + w), (x, y0 + h / 2 - w / 2, x + lw * 0.78, y0 + h / 2 + w / 2),
            (x, y0 + h - w, x + lw, y0 + h)]
    return polys, bars, x + lw

def dissolving_bar(bx0, by0, bx1, by1):
    """A bar that is solid for its first 30% and then turns into shrinking particles."""
    bh = by1 - by0
    split = bx0 + (bx1 - bx0) * 0.3
    dots, x = [], split + bh * 0.5
    while x < bx1 + 4:
        u = (x - split) / (bx1 - split)
        dots.append((x, (by0 + by1) / 2, bh * 0.5 * (1 - 0.55 * u), min(1.0, 0.25 + u)))
        x += bh * 1.05
    return (bx0, by0, split, by1), dots

# ---- layout -------------------------------------------------------------------------------------------
def layout(icon):
    if icon:
        W, H, R = 240.0, 240.0, 88.0
        cx, cy = W / 2 - 14, H / 2
        return dict(W=W, H=H, cx=cx, cy=cy, R=R, polys=[], bars=[])
    W, H, R = 560.0, 180.0, 70.0
    cx, cy = 20 + R, H / 2
    polys, bars, x_end = wordmark(cx + R + 56, cy - 28)
    return dict(W=x_end + 24, H=H, cx=cx, cy=cy, R=R, polys=polys, bars=bars)

# ---- SVG ------------------------------------------------------------------------------------------------
def svg(theme, icon=False):
    th, L = THEMES[theme], layout(icon)
    f = lambda v: f"{v:.2f}".rstrip("0").rstrip(".")
    hexc = lambda c: "#%02x%02x%02x" % c
    inside, drift = emblem(L["cx"], L["cy"], L["R"])
    label = "Haze" if not icon else "Haze icon"
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {f(L["W"])} {f(L["H"])}" '
           f'width="{f(L["W"] * 2)}" height="{f(L["H"] * 2)}" role="img" aria-label="{label}">',
           f'<title>{label}</title><defs>',
           f'<clipPath id="disc"><circle cx="{f(L["cx"])}" cy="{f(L["cy"])}" r="{f(L["R"])}"/></clipPath>']
    if th["glow"]:
        out.append('<filter id="glow" x="-50%" y="-50%" width="200%" height="200%">'
                   '<feGaussianBlur stdDeviation="3.2" result="b"/>'
                   f'<feComponentTransfer in="b" result="g"><feFuncA type="linear" slope="{th["glow"] * 2.2:.2f}"/></feComponentTransfer>'
                   '<feMerge><feMergeNode in="g"/><feMergeNode in="SourceGraphic"/></feMerge></filter>')
    out.append('</defs>')
    def circles(pts):
        return "".join(f'<circle cx="{f(x)}" cy="{f(y)}" r="{f(r)}" fill="{hexc(mix(th["ink"], th["accent"], u * 1.3))}"/>'
                       for x, y, r, u in pts)
    glow = ' filter="url(#glow)"' if th["glow"] else ""
    # particles that are still part of the solid are drawn without glow
    out.append(f'<g clip-path="url(#disc)">{circles([p for p in inside if p[3] <= 0.35])}</g>')
    out.append(f'<g{glow}><g clip-path="url(#disc)">{circles([p for p in inside if p[3] > 0.35])}</g></g>')
    out.append(f'<g fill="{hexc(th["accent"])}"{glow}>' +
               "".join(f'<circle cx="{f(x)}" cy="{f(y)}" r="{f(r)}"/>' for x, y, r, _ in drift) + '</g>')
    if not icon:
        path = "".join("M" + "L".join(f"{f(x)},{f(y)}" for x, y in p) + "Z" for p in L["polys"])
        out.append(f'<path fill="{hexc(th["ink"])}" d="{path}"/>')
        bar_dots = []
        for b in L["bars"]:
            (x0, y0, x1, y1), dots = dissolving_bar(*b)
            out.append(f'<rect x="{f(x0)}" y="{f(y0)}" width="{f(x1 - x0)}" height="{f(y1 - y0)}" fill="{hexc(th["ink"])}"/>')
            bar_dots += dots
        out.append(f'<g{glow}>' + "".join(
            f'<circle cx="{f(x)}" cy="{f(y)}" r="{f(r)}" fill="{hexc(mix(th["ink"], th["accent"], u))}"/>'
            for x, y, r, u in bar_dots) + '</g>')
    out.append('</svg>')
    return "\n".join(out) + "\n"

# ---- PNG (PIL, supersampled) --------------------------------------------------------------------------------
def png(path, theme, icon=False, scale=3, background=True):
    from PIL import Image, ImageDraw, ImageFilter, ImageChops
    th, L = THEMES[theme], layout(icon)
    k = scale * 4
    W, H = int(L["W"] * k), int(L["H"] * k)
    base = Image.new("RGBA", (W, H), PREVIEW_BG[theme] + (255,) if background else (0, 0, 0, 0))
    art = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    da, dg = ImageDraw.Draw(art), ImageDraw.Draw(glow)
    def disc(draw, x, y, r, col):
        draw.ellipse([(x - r) * k, (y - r) * k, (x + r) * k, (y + r) * k], fill=col + (255,))
    inside, drift = emblem(L["cx"], L["cy"], L["R"])
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    dl = ImageDraw.Draw(layer)
    glowing = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    dgl = ImageDraw.Draw(glowing)
    for x, y, r, u in inside:
        c = mix(th["ink"], th["accent"], u * 1.3)
        disc(dl, x, y, r, c)
        if u > 0.35: disc(dgl, x, y, r, c)
    mask = Image.new("L", (W, H), 0)
    ImageDraw.Draw(mask).ellipse([(L["cx"] - L["R"]) * k, (L["cy"] - L["R"]) * k,
                                  (L["cx"] + L["R"]) * k, (L["cy"] + L["R"]) * k], fill=255)
    empty = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    art.alpha_composite(Image.composite(layer, empty, mask))
    glow.alpha_composite(Image.composite(glowing, empty, mask))
    for x, y, r, _ in drift:
        disc(da, x, y, r, th["accent"]); disc(dg, x, y, r, th["accent"])
    for p in L["polys"]:
        da.polygon([(x * k, y * k) for x, y in p], fill=th["ink"] + (255,))
    for b in L["bars"]:
        (x0, y0, x1, y1), dots = dissolving_bar(*b)
        da.rectangle([x0 * k, y0 * k, x1 * k, y1 * k], fill=th["ink"] + (255,))
        for x, y, r, u in dots:
            c = mix(th["ink"], th["accent"], u)
            disc(da, x, y, r, c); disc(dg, x, y, r, c)
    if th["glow"]:
        g = glow.filter(ImageFilter.GaussianBlur(3.2 * k))
        a = g.split()[3].point(lambda v: int(min(255, v * th["glow"] * 2.2)))
        g.putalpha(a)
        base.alpha_composite(g)
    base.alpha_composite(art)
    base.resize((int(L["W"] * scale), int(L["H"] * scale)), Image.LANCZOS).save(path)

if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    for theme in THEMES:
        (OUT / f"logo-{theme}.svg").write_text(svg(theme), encoding="utf-8", newline="\n")
        (OUT / f"icon-{theme}.svg").write_text(svg(theme, icon=True), encoding="utf-8", newline="\n")
        png(OUT / f"logo-{theme}.png", theme)
        png(OUT / f"icon-{theme}.png", theme, icon=True)
    print("written to", OUT)
