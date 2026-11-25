"""Rebuild the two roulette figures with Python's standard library."""

from fractions import Fraction
from pathlib import Path
from xml.sax.saxutils import escape


OUT = Path(__file__).resolve().parents[1] / "site" / "content" / "blog" / "images"
P = Fraction(18, 38)


def bold(start, goal):
    # Along the one nonterminal branch: P(original win) = offset + weight * P(win from x).
    x, offset, weight = start, Fraction(0), Fraction(1)
    seen = {}
    while 0 < x < goal:
        if x in seen:
            a, b = seen[x]
            return a + b * (offset - a) / (b - weight)
        seen[x] = offset, weight
        x *= 2
        if x < goal:
            weight *= P
        else:
            offset += weight * P
            weight *= 1 - P
            x -= goal
    return offset + weight * (x == goal)


def plot(filename, title, ymax, yticks, curves, notes=()):
    left, right, top, bottom = 62, 597, 42, 290

    def x(v):
        return left + (right - left) * v / 100

    def y(v):
        return bottom - (bottom - top) * v / ymax

    def line(x1, y1, x2, y2, css):
        return f'<path class="{css}" d="M{x1:.2f} {y1:.2f} L{x2:.2f} {y2:.2f}"/>'

    def text(xx, yy, label, anchor="start", css=""):
        return f'<text class="{css}" x="{xx:.2f}" y="{yy:.2f}" text-anchor="{anchor}">{escape(label)}</text>'

    svg = [
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 624 356" width="624" height="356" role="img" aria-labelledby="title">',
        f'<title id="title">{escape(title)}</title>',
        """<style>
svg { --ink:#242d34; --blue:#245984; --muted:#54636f; --rule:#cdd3d7; }
@media (prefers-color-scheme: dark) { svg { --ink:#e1e7eb; --blue:#9bc6e6; --muted:#a9b5bf; --rule:#44515e; } }
text { font:15px system-ui,sans-serif; fill:var(--ink); }
.tick { font-size:14px; fill:var(--muted); } .title { font-weight:550; }
@media (max-width:460px) { text { font-size:23px; } .tick,.title { font-size:20px; } }
path,polyline { fill:none; } .grid { stroke:var(--rule); stroke-width:.8; }
.fair { stroke:var(--muted); stroke-width:1.6; stroke-dasharray:6 5; }
.bold { stroke:var(--ink); stroke-width:2.1; } .flat { stroke:var(--blue); stroke-width:2.2; }
.label-flat { fill:var(--blue); } .leader { stroke:var(--muted); stroke-width:1; }
.point { fill:var(--ink); } .point-flat { fill:var(--blue); }
</style>""",
        text(left, 21, title, css="title"),
    ]
    for v, label in yticks:
        svg += [line(left, y(v), right, y(v), "grid"), text(left - 8, y(v) + 5, label, "end", "tick")]
    for v in (0, 25, 50, 75, 100):
        svg += [line(x(v), bottom, x(v), bottom + 4, "grid"), text(x(v), bottom + 22, f"${v}", "middle", "tick")]
    svg.append(text((left + right) / 2, 341, "Starting balance", "middle"))
    for css, values in curves:
        points = " ".join(f"{x(xx):.2f},{y(yy):.2f}" for xx, yy in values)
        svg.append(f'<polyline class="{css}" points="{points}"/>')
    for label, css, xx, yy, tx, ty in notes:
        svg += [line(x(xx), y(yy), x(tx), y(ty) + 4, "leader"),
                f'<circle class="{"point-flat" if css == "flat" else "point"}" cx="{x(xx):.2f}" cy="{y(yy):.2f}" r="3"/>',
                text(x(tx), y(ty), label, css="label-flat" if css == "flat" else "")]
    (OUT / filename).write_text("\n".join([*svg, "</svg>"]) + "\n", encoding="utf-8", newline="\n")


def main():
    ratio = (1 - P) / P
    flat = [(s, float((ratio**s - 1) / (ratio**100 - 1)) * 100) for s in range(101)]
    curve = [(s, float(bold(s, 100)) * 100) for s in range(101)]
    plot("bold-play-curve.svg", "Chance of reaching $100", 100,
         [(n, f"{n}%") for n in (0, 25, 50, 75, 100)],
         [("fair", [(0, 0), (100, 100)]), ("bold", curve), ("flat", flat)],
         [("Fair game", "fair", 25, 25, 8, 39),
          ("Bold play: 47.4%", "bold", 50, curve[50][1], 55, 37),
          ("$1 bets: 0.51%", "flat", 50, flat[50][1], 30, 13)])
    gap = [(i * 100 / 4096, float(Fraction(i, 4096) - bold(i, 4096)) * 100) for i in range(4097)]
    plot("bold-play-shortfall.svg", "Shortfall from a fair game (percentage points)", 4,
         [(n, str(n)) for n in range(5)], [("bold", gap)])


if __name__ == "__main__":
    main()
