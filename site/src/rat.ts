// Exact rational numbers from Haze's JSON output ("a/b" strings), formatted for people.

export interface Rat { n: bigint; d: bigint }

export function parseRat(s: string | null | undefined): Rat | null {
  if (s === null || s === undefined) return null;
  const [a, b] = String(s).split("/");
  try {
    const n = BigInt(a), d = b === undefined ? 1n : BigInt(b);
    return d === 0n ? null : { n, d };
  } catch {
    return null;
  }
}

/** An approximate float, good enough for drawing. */
export function toFloat(r: Rat | null): number {
  if (!r) return NaN;
  // scale down huge numerators and denominators together to keep precision
  const len = Math.max(r.n.toString().length, r.d.toString().length);
  if (len < 300) return Number(r.n) / Number(r.d);
  const k = BigInt(len - 300);
  const s = 10n ** k;
  return Number(r.n / s) / Number(r.d / s);
}

const SUP: Record<string, string> = { "-": "⁻", "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹" };

/** A short decimal: up to 6 significant digits, scientific notation below 0.001. */
export function fmtNum(x: number): string {
  if (!isFinite(x)) return String(x);
  if (x === 0) return "0";
  const a = Math.abs(x);
  if (a < 1e-3) {
    const [m, e] = x.toExponential(3).split("e");
    return `${m.replace(/\.?0+$/, "")}×10${e.replace("+", "").split("").map((c) => SUP[c] ?? c).join("")}`;
  }
  if (Number.isInteger(x) && a < 1e15) return String(x);
  const s = x.toPrecision(6);
  return s.includes("e") ? s : s.replace(/\.?0+$/, "");
}

/** The exact fraction, when it's short enough to read. */
export function exactText(r: Rat | null): string | null {
  if (!r) return null;
  if (r.d === 1n) return r.n.toString();
  const s = `${r.n}/${r.d}`;
  return s.length <= 24 ? s : null;
}

/** Formats a rational as a decimal, marking it approximate when it isn't exact. */
export function fmtRat(s: string | null | undefined): string {
  const r = parseRat(s);
  if (!r) return "–";
  const x = toFloat(r);
  const dec = fmtNum(x);
  // exact when the decimal shown equals the fraction
  const exact = r.d === 1n || (Number.isFinite(x) && Number(dec) === x && /^[\d.\-]+$/.test(dec) && dec.length < 12);
  return exact ? dec : `≈${dec}`;
}

/** A `title` for hover text: the exact value. */
export function ratTitle(s: string | null | undefined): string {
  const r = parseRat(s);
  if (!r) return "";
  const e = exactText(r);
  return e ? `exactly ${e}` : `exactly ${r.n}/${r.d}`.slice(0, 400);
}
