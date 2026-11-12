// Share links: the editor's code, compressed into the URL hash, so an experiment can be shared
// with a single link and no server.

function toBase64Url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function fromBase64Url(s: string): Uint8Array {
  const b = atob(s.replace(/-/g, "+").replace(/_/g, "/"));
  return Uint8Array.from(b, (c) => c.charCodeAt(0));
}

async function pipe(bytes: Uint8Array, stream: CompressionStream | DecompressionStream): Promise<Uint8Array> {
  const out = new Blob([bytes]).stream().pipeThrough(stream);
  return new Uint8Array(await new Response(out).arrayBuffer());
}

/** Encodes code for a URL hash: `z` + deflate-raw + base64url, or `u` + plain base64url. */
export async function encode(code: string): Promise<string> {
  const bytes = new TextEncoder().encode(code);
  if (typeof CompressionStream !== "undefined") {
    return "z" + toBase64Url(await pipe(bytes, new CompressionStream("deflate-raw")));
  }
  return "u" + toBase64Url(bytes);
}

export async function decode(s: string): Promise<string | null> {
  try {
    if (s[0] === "z") return new TextDecoder().decode(await pipe(fromBase64Url(s.slice(1)), new DecompressionStream("deflate-raw")));
    if (s[0] === "u") return new TextDecoder().decode(fromBase64Url(s.slice(1)));
  } catch {
    /* a damaged link */
  }
  return null;
}

/** The code in the current URL's hash (`#code=...`), if there is any. */
export async function codeFromHash(): Promise<string | null> {
  const m = location.hash.match(/(?:^#|&)code=([^&]+)/);
  return m ? decode(m[1]) : null;
}

/** A link to `page` with `code` in its hash. */
export async function linkTo(page: URL, code: string): Promise<string> {
  const u = new URL(page);
  u.hash = `code=${await encode(code)}`;
  return u.toString();
}
