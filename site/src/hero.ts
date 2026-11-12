// The home page's hero: payments flowing through a retry protocol as particles, in the logo's
// dissolving-particle style. Each particle is one simulated payment. Next to the noisy simulated
// rate, Haze's exact probability of a double charge is computed live, in the browser, from the
// same model, as the loss-rate slider and the idempotency switch change.
import { engine } from "./engine";
import { fmtRat, ratTitle } from "./rat";

import { heroModel as MODEL } from "./hero-model.mjs";

type Pt = [number, number];
interface Particle { pts: Pt[]; seg: number; t: number; speed: number; jitter: number; double: boolean; doubleAt: number; done: boolean; life: number; gen: number }

// positions in a 0..1 box: the attempt on the top row, timeouts and retries on the bottom row
const SEND: Pt = [0.1, 0.22], SERVER: Pt = [0.5, 0.22], DONE: Pt = [0.9, 0.22];
const RETRY: Pt = [0.1, 0.72], WAIT: Pt = [0.5, 0.72], GAVEUP: Pt = [0.9, 0.72];
const NODES: [Pt, string][] = [[SEND, "client sends"], [SERVER, "server charges"], [DONE, "paid"],
  [RETRY, "retry"], [WAIT, "timeout"], [GAVEUP, "gave up"]];
const EDGES: [Pt, Pt][] = [[SEND, DONE], [[0.3, 0.22], [0.3, 0.72]], [[0.7, 0.22], [0.7, 0.72]], [RETRY, GAVEUP], [RETRY, SEND]];

/** One payment: up to three attempts, each of whose two messages can be lost. */
function samplePath(loss: number, idempotent: boolean): { pts: Pt[]; double: boolean; doubleAt: number } {
  const pts: Pt[] = [SEND];
  let charges = 0, doubleAt = -1;
  for (let attempt = 1; attempt <= 3; attempt++) {
    if (Math.random() < loss) {
      pts.push([0.3, 0.22], [0.3, 0.72], WAIT);       // the request is lost
    } else {
      pts.push(SERVER);
      if (!idempotent || charges === 0) {
        charges++;
        if (charges === 2) doubleAt = pts.length - 1;
      }
      if (Math.random() < loss) {
        pts.push([0.7, 0.22], [0.7, 0.72], WAIT);     // the reply is lost
      } else {
        pts.push(DONE);
        return { pts, double: charges >= 2, doubleAt };
      }
    }
    if (attempt < 3) pts.push(RETRY, SEND);
  }
  pts.push(GAVEUP);
  return { pts, double: charges >= 2, doubleAt };
}

export function mountHero(opts: { canvas: HTMLCanvasElement; slider: HTMLInputElement; toggle: HTMLInputElement; readout: HTMLElement; sim: HTMLElement; lossLabel: HTMLElement; root: string; precomputed: Record<string, string>; playLink?: HTMLAnchorElement }) {
  const { canvas, slider, toggle, readout, sim, lossLabel } = opts;
  const ctx = canvas.getContext("2d")!;
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const parts: Particle[] = [];
  let gen = 0;  // payments started before the last control change don't count
  let total = 0, doubles = 0, last = performance.now(), spawn = 0, visible = true;

  const loss = () => Number(slider.value) / 100;
  const idem = () => toggle.checked;

  function colors() {
    const cs = getComputedStyle(document.documentElement);
    return { accent: cs.getPropertyValue("--accent").trim() || "#5eead4", bad: cs.getPropertyValue("--bad").trim() || "#fb7185",
      text: cs.getPropertyValue("--muted").trim() || "#94a3b8", line: cs.getPropertyValue("--line").trim() || "#334155" };
  }

  function resize() {
    const r = canvas.getBoundingClientRect(), dpr = Math.min(2, devicePixelRatio || 1);
    canvas.width = Math.max(1, r.width * dpr);
    canvas.height = Math.max(1, r.height * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  }
  new ResizeObserver(resize).observe(canvas);
  resize();

  function P(p: Pt): Pt {
    const r = canvas.getBoundingClientRect();
    return [p[0] * r.width, p[1] * r.height];
  }

  function frame(now: number) {
    const dt = Math.min(0.05, (now - last) / 1000);
    last = now;
    const c = colors();
    const r = canvas.getBoundingClientRect();
    ctx.clearRect(0, 0, r.width, r.height);
    // edges
    ctx.strokeStyle = c.line; ctx.lineWidth = 1; ctx.setLineDash([3, 5]);
    for (const [a, b] of EDGES) {
      const [x1, y1] = P(a), [x2, y2] = P(b);
      ctx.beginPath(); ctx.moveTo(x1, y1); ctx.lineTo(x2, y2); ctx.stroke();
    }
    ctx.setLineDash([]);
    // nodes
    ctx.font = "12px var(--sans, system-ui)"; ctx.textAlign = "center";
    for (const [p, label] of NODES) {
      const [x, y] = P(p);
      ctx.fillStyle = c.line; ctx.beginPath(); ctx.arc(x, y, 7, 0, Math.PI * 2); ctx.fill();
      ctx.fillStyle = c.text; ctx.fillText(label, x, y + (p[1] < 0.5 ? -16 : 24));
    }
    // particles
    if (!reduce && visible) {
      spawn += dt * 26;
      while (spawn >= 1 && parts.length < 450) {
        spawn--;
        const s = samplePath(loss(), idem());
        parts.push({ pts: s.pts, seg: 0, t: 0, speed: 0.9 + Math.random() * 0.5, jitter: (Math.random() - 0.5) * 10, double: s.double, doubleAt: s.doubleAt, done: false, life: 1, gen });
      }
    }
    ctx.globalCompositeOperation = "lighter";
    for (const p of parts) {
      if (!p.done) {
        const a = P(p.pts[p.seg]), b = P(p.pts[p.seg + 1]);
        const len = Math.hypot(b[0] - a[0], b[1] - a[1]) || 1;
        p.t += (dt * 180 * p.speed) / len;
        while (p.t >= 1 && !p.done) {
          p.t -= 1; p.seg++;
          if (p.seg >= p.pts.length - 1) { p.done = true; p.t = 1; p.seg = p.pts.length - 2; if (p.gen === gen) { total++; if (p.double) doubles++; } }
        }
      } else p.life -= dt * 0.8;
      const a = P(p.pts[p.seg]), b = P(p.pts[p.seg + 1]);
      const t = Math.min(1, p.t);
      const x = a[0] + (b[0] - a[0]) * t, y = a[1] + (b[1] - a[1]) * t;
      const dx = b[0] - a[0], dy = b[1] - a[1], l = Math.hypot(dx, dy) || 1;
      const red = p.double && p.seg >= p.doubleAt;
      ctx.globalAlpha = Math.max(0, p.life) * (red ? 0.95 : 0.7);
      ctx.fillStyle = red ? c.bad : c.accent;
      ctx.beginPath(); ctx.arc(x - (dy / l) * p.jitter, y + (dx / l) * p.jitter, red ? 2.6 : 1.8, 0, Math.PI * 2); ctx.fill();
    }
    ctx.globalAlpha = 1; ctx.globalCompositeOperation = "source-over";
    for (let i = parts.length - 1; i >= 0; i--) if (parts[i].life <= 0) parts.splice(i, 1);
    if (total > 0) sim.textContent = `Simulated: ${((doubles / total) * 100).toFixed(2)}% of ${total.toLocaleString()} payments`;
    if (!reduce) requestAnimationFrame(frame);
  }
  new IntersectionObserver(([e]) => { visible = e.isIntersecting; }).observe(canvas);
  requestAnimationFrame(frame);

  let req = 0;
  async function update() {
    const l = loss(), key = `${slider.value}:${idem()}`, mine = ++req;
    lossLabel.textContent = `${slider.value}%`;
    gen++; total = 0; doubles = 0; sim.textContent = "Simulated: starting…";
    const show = (q: string) => {
      if (mine !== req) return;
      readout.replaceChildren(
        Object.assign(document.createElement("span"), { className: "exact", textContent: q === "0" ? "0" : fmtRat(q), title: ratTitle(q) }),
        document.createTextNode(q === "0" ? " exactly. Haze proves no customer is ever charged twice." : " exactly, computed by Haze in your browser"));
      (readout.closest(".readout") ?? readout).classList.toggle("safe", q === "0");
    };
    if (opts.precomputed[key]) show(opts.precomputed[key]);
    const src = MODEL(l.toString(), idem());
    if (opts.playLink) opts.playLink.dataset.code = src;
    try {
      const r = await engine(opts.root).check(src);
      const rec = r.records.find((x) => x.kind === "prob");
      if (rec) show(rec.belief);
    } catch { /* the precomputed value, if any, stays */ }
  }
  slider.addEventListener("input", update);
  toggle.addEventListener("change", update);
  update();
  if (reduce) requestAnimationFrame(frame);
}
