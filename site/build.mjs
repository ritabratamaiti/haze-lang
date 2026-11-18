// Builds the Haze website into site/dist.
//
//   node build.mjs           build the site
//   node build.mjs --serve   build it and serve it at http://localhost:8080
//
// The WebAssembly engine must be built first, with `python wasm/build.py` from the repository root.
// Every example's output is precomputed here with the native `haze` binary when it exists (it's
// much faster for the slow examples), or with the WebAssembly build otherwise; the two give the
// same output.
import { build } from "esbuild";
import { marked } from "marked";
import { readFileSync, writeFileSync, mkdirSync, cpSync, existsSync, rmSync, readdirSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { deflateRawSync } from "node:zlib";
import { createServer } from "node:http";
import { join, dirname, relative, extname, posix } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const SITE = dirname(fileURLToPath(import.meta.url));
const REPO = join(SITE, "..");
const DIST = join(SITE, "dist");
const ENGINE = join(SITE, "public", "engine");
const GITHUB = "https://github.com/ritabratamaiti/haze-lang";
const read = (p) => readFileSync(p, "utf8").replace(/\r\n/g, "\n");
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);

// ---- checking examples -------------------------------------------------------------------
if (!existsSync(join(ENGINE, "haze.mjs"))) {
  console.error("site/public/engine/haze.mjs is missing; build it first with `python wasm/build.py`");
  process.exit(1);
}
const nativeBin = join(REPO, ".lake", "build", "bin", process.platform === "win32" ? "haze.exe" : "haze");
const { default: createHaze } = await import(pathToFileURL(join(ENGINE, "haze.mjs")).href);
const wasm = await createHaze();
if (wasm._haze_init() !== 0) throw new Error("the WebAssembly engine failed to start");

function checkWasm(src) {
  const p = wasm.stringToNewUTF8(src);
  const out = wasm._haze_json(p);
  wasm._free(p);
  const s = wasm.UTF8ToString(out);
  wasm._free(out);
  return s;
}

const tmp = join(SITE, ".tmp");
mkdirSync(tmp, { recursive: true });
function check(src, { native = false } = {}) {
  let json;
  if (native && existsSync(nativeBin)) {
    const f = join(tmp, "main.hz");
    writeFileSync(f, src);
    try { json = execFileSync(nativeBin, ["--json", f], { encoding: "utf8" }); } catch (e) { json = e.stdout; }
  } else json = checkWasm(src);
  // keep only what the pages render; the file name is the same everywhere
  return json.split("\n").filter((l) => l.trim()).map((l) => ({ ...JSON.parse(l), file: "main.hz" }));
}

// ---- content -----------------------------------------------------------------------------
const PRESETS = [
  ["retry-bug", "Retry bug: a double charge", "A payment client retries when a message is lost. Haze rejects \"never charged twice\" and shows the run where it happens."],
  ["rough-numbers", "Rough numbers", "The loss rate is only known roughly, so the model lists the values it might have. The answer is a range: how strongly what you know guarantees the property, and how strongly it allows it."],
  ["forever", "Runs of any length: craps", "The game can last any number of rolls, and Haze still gets the exact answer: 244/495."],
  ["tests", "Tests ranked by probability", "#tests lists the most likely runs as test cases, the rare failing runs, and a statistical test with a known false-alarm rate."],
  ["bayes", "Bayes: which component failed?", "observe records which alerts fired, and Haze gives the exact probability of each cause."],
  ["pins", "Real data: PIN lockouts", "How often a thief guesses a PIN before a card locks or a phone erases itself, using PIN frequencies from 3.4 million leaked passwords."],
].map(([id, title, blurb]) => {
  const code = read(join(SITE, "content", "presets", `${id}.hz`)).trimEnd() + "\n";
  return { id, title, blurb, code, records: check(code) };
});
const preset = (id) => PRESETS.find((p) => p.id === id);

const HERO = {};
const heroSrc = (await import(pathToFileURL(join(SITE, "src", "hero-model.mjs")).href)).heroModel;
for (let pct = 1; pct <= 30; pct++) {
  for (const idem of [false, true]) {
    const rec = check(heroSrc((pct / 100).toString(), idem)).find((r) => r.kind === "prob");
    HERO[`${pct}:${idem}`] = rec.belief;
  }
}

const slug = (s) => s.toLowerCase().replace(/<[^>]+>/g, "").replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
const TOUR = read(join(SITE, "content", "tour.md")).split(/^## /m).filter((s) => s.trim()).map((part) => {
  const [title, ...rest] = part.split("\n");
  const body = rest.join("\n");
  const code = (body.match(/```haze\n([\s\S]*?)```/) ?? [, ""])[1];
  const prose = body.replace(/```haze\n[\s\S]*?```/, "");
  return { id: slug(title), title, html: `<h2>${esc(title)}</h2>` + marked.parse(prose), code, records: check(code) };
});

const EXAMPLES = [
  ["examples/payments_retry.hz", "Software", "Payment retries", "Retries after a lost reply charge the customer twice, and idempotency keys prevent it."],
  ["examples/quorum_replication.hz", "Software", "Quorum replication", "Reads see the latest write when R + W > N, and can be stale when R = 1."],
  ["examples/circuit_breaker.hz", "Software", "Circuit breaker", "A circuit breaker's invariants, how fast it trips, and how much load it sheds."],
  ["examples/canary_rollout.hz", "Software", "Canary rollout", "Whether a defective build can reach all traffic during a staged rollout."],
  ["examples/incident_triage.hz", "Operations", "Incident triage", "The likely root cause of an incident, given which alerts fired."],
  ["examples/Conformance/payments/payments.hz", "Testing", "A specification for real code", "The model a Python client is tested against, with tests ranked by probability."],
  ["examples/Tutorial/JobWorker.hz", "Tutorial", "Tutorial: a job worker", "The language step by step, from one random value to a full system."],
  ["examples/probability_classics.hz", "Probability", "Probability classics", "The birthday problem, gambler's ruin, the boy-or-girl paradox and more, with known answers."],
  ["examples/Gallery/games.hz", "Games", "Craps, tennis and Penney's game", "The odds in craps (244/495), winning a game of tennis from deuce, and Penney's coin game."],
  ["examples/Gallery/security.hz", "Security", "PIN guessing and intrusion alarms", "Leaked PIN frequencies against lockout limits, and why most intrusion alarms are false."],
  ["examples/Gallery/production_test.hz", "Electronics test", "Guard bands in production test", "How often a noisy meter ships out-of-spec parts, why retesting makes it worse, and the guard band that fixes it."],
  ["examples/Gallery/chip_design.hz", "Chip design", "Why big GPUs disable cores", "The yield of NVIDIA's 814 mm² GH100 die at TSMC's reported defect density, with and without spare SMs."],
  ["examples/Gallery/reliability.hz", "Reliability", "Voting and redundancy", "A proof that a three-way voter masks any single failure, plus redundant pumps and availability."],
  ["examples/Gallery/queueing.hz", "Networking", "Network buffers", "How full a buffer gets and how many packets it drops when the arrival rate is uncertain."],
  ["examples/Gallery/genetics.hz", "Genetics", "Genetic drift", "How often drift fixes a new allele, and Hardy–Weinberg with a roughly known allele frequency."],
  ["examples/Gallery/epidemic.hz", "Epidemiology", "Household epidemics", "How many people in a household catch an infection (Reed–Frost), with and without vaccination."],
  ["examples/Gallery/finance.hz", "Finance", "Options and ruin", "Binomial option prices, put–call parity, uncertain volatility, and an insurer's risk of ruin."],
  ["examples/Gallery/physics.hz", "Physics", "Decay and diffusion", "Radioactive decay, diffusion between two chambers, and random-walk returns."],
  ["examples/Gallery/game_physics.hz", "Video games", "Game physics", "Tunneling through walls, energy drift in integrators, and frame-rate dependent jumps."],
  ["examples/Law/sally_clark.hz", "Law", "R v Clark", "The \"1 in 73 million\" statistic from a real court case, and the question the jury should have asked."],
];
const SLOW = new Set(["examples/Gallery/chip_design.hz", "examples/Gallery/production_test.hz"]);
const GALLERY = EXAMPLES.map(([path, field, title, desc]) => {
  const code = read(join(REPO, path));
  return { id: slug(path), path, field, title, desc, code, records: check(code, { native: true }), slow: SLOW.has(path) };
});

// ---- docs --------------------------------------------------------------------------------
const SITE_URL = "https://haze-lang.pages.dev/";
const DOC_SECTIONS = [
  ["Get started", [
    ["installation", "Installation", "docs/Installation.md", "Prebuilt binaries, building from source, Docker, and running Haze without installing it."],
    ["first-model", "Your first model", "docs/Getting-Started.md", "Write a small model, check a claim and a theorem, add a rough rate, and generate tests."],
    ["results", "Reading results", "docs/Reading-Results.md", "What each number, word and note in Haze's output means, including counterexamples."]]],
  ["Guides", [
    ["fuzzy", "Fuzzy parameters", "docs/Fuzzy-Parameters.md", "Rates you only roughly know: choosing possibilities, and how belief and plausibility are computed."],
    ["testing", "Testing real code", "examples/Conformance/README.md", "A model as the specification of a Python client, with tests ranked by probability."],
    ["ci", "Haze in CI and scripts", "docs/CI.md", "Exit status, the GitHub Action, Docker, and reading JSON results from a program."]]],
  ["Reference", [
    ["reference", "Language reference", "docs/Language-Reference.md", "Every declaration, statement, expression, type and query in the language."],
    ["cli", "Command line and JSON", "docs/Command-Line.md", "The haze command's options and exit status, and the fields of its JSON records."]]],
  ["Background", [
    ["design", "Design and semantics", "docs/Design.md", "How Haze follows Lean's design, and the precise meaning of its results."],
    ["comparison", "How Haze compares", "docs/Comparison.md", "PRISM, Storm, Lean, probabilistic programming and testing tools, and when to use each."],
    ["prism", "Checking against PRISM and Storm", "docs/Benchmarks.md", "PRISM's example models checked with Haze, PRISM and Storm, and how the answers compare."],
    ["faq", "FAQ", "docs/FAQ.md", "Status, exact numbers, model size, licensing and other common questions."]]],
];
const DOCS = DOC_SECTIONS.flatMap(([section, pages]) => pages.map(([id, label, path, summary]) => ({ id, label, path, summary, section })));

const KEYWORDS = new Set(("logic enum param input def observe system var step claim theorem with prob if then else let in " +
  "forall exists match and or not implies is very assert skip always eventually after given explore steps until").split(" "));
const ATOMS = new Set(["true", "false", "crashed"]);
const TYPES = new Set(["Num", "Bool", "Deg"]);
const BUILTINS = new Set("flip bernoulli uniform binomial tri trap ramp_up ramp_down abs floor min max deg num".split(" "));
/** Static highlighting for Haze code on the docs pages, with the editor's colors. */
function highlightHaze(code) {
  const re = /(\/-[\s\S]*?-\/|--[^\n]*)|(#[a-z]+)|(\b\d+(?:\.\d+)?\b)|([A-Za-z_][\w']*)|([\s\S])/g;
  let out = "";
  for (const m of code.matchAll(re)) {
    const [t, com, dir, num, word] = m;
    const cls = com ? "com" : dir ? "kw" : num ? "num" : word ? (KEYWORDS.has(word) ? "kw" : TYPES.has(word) ? "ty" : ATOMS.has(word) ? "num" : BUILTINS.has(word) ? "fn" : "") : "";
    out += cls ? `<span class="t-${cls}">${esc(t)}</span>` : esc(t);
  }
  return out;
}
/** A playground link with the code in its hash, in the same format as src/share.ts. */
const playHash = (code) => "z" + deflateRawSync(Buffer.from(code, "utf8")).toString("base64url");
const unescapeHtml = (s) => s.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, "&");

let blockId = 0;
function renderDoc(src, path) {
  const title = src.match(/^# (.*)$/m)?.[1] ?? "";
  const body = src.replace(/^# .*\n/, "");
  const firstPara = body.trim().split(/\n\s*\n/)[0].replace(/\n/g, " ");
  const blurb = firstPara.replace(/\[([^\]]+)\]\([^)]*\)/g, "$1").replace(/[`*_]/g, "");
  let html = marked.parse(body);
  html = html.replace(/<h([23])>(.*?)<\/h\1>/g, (_, n, t) => `<h${n} id="${slug(t)}">${t}</h${n}>`);
  // links to the website become relative; links between documents stay on the site; the rest go to GitHub
  html = html.replace(/(href|src)="https:\/\/haze-lang\.pages\.dev\/([^"]*)"/g, (m, attr, rest) => `${attr}="@ROOT@${rest}"`);
  html = html.replace(/(href|src)="([^"#:@]+)(#[^"]*)?"/g, (m, attr, target, hash = "") => {
    const resolved = posix.normalize(posix.join(posix.dirname(path), target));
    const doc = DOCS.find((d) => d.path === resolved);
    if (doc) return `${attr}="@ROOT@docs/${doc.id}/${hash}"`;
    const kind = attr === "src" ? "raw" : "blob";
    return `${attr}="${GITHUB}/${kind}/main/${resolved}${hash}"`;
  });
  html = html.replace(/<pre><code class="language-haze">([\s\S]*?)<\/code><\/pre>/g, (_, escaped) => {
    const code = unescapeHtml(escaped);
    const id = `code-${++blockId}`;
    // complete examples, the ones that check without errors, get a link to the playground
    const runs = !check(code).some((r) => r.severity === "error");
    const actions = `<div class="code-actions"><button class="btn small copy" data-copy="${id}">Copy</button>` +
      (runs ? `<a class="btn small" href="@ROOT@play/#code=${playHash(code)}">Open in the playground</a>` : "") + "</div>";
    return `<div class="code-block"><pre class="code" id="${id}"><code>${highlightHaze(code)}</code></pre>${actions}</div>`;
  });
  const headings = [...html.matchAll(/<h2 id="([^"]+)">(.*?)<\/h2>/g)].map(([, id, t]) => [id, t.replace(/<[^>]+>/g, "")]);
  return { title, html, headings, blurb };
}

// ---- pages -------------------------------------------------------------------------------
const NAV = [["play/", "Playground"], ["tour/", "Tour"], ["gallery/", "Gallery"], ["docs/", "Docs"]];
function layout({ root, path, title, description, body, script, data, wide, canonical }) {
  const nav = NAV.map(([href, label]) => `<a href="${root}${href}"${path.startsWith(href) ? ' class="active" aria-current="page"' : ""}>${label}</a>`).join("");
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="root" content="${root}">
<title>${esc(title)}</title>
<meta name="description" content="${esc(description)}">
${canonical !== undefined ? `<link rel="canonical" href="${SITE_URL}${canonical}">\n<meta property="og:url" content="${SITE_URL}${canonical}">\n` : ""}<meta property="og:title" content="${esc(title)}">
<meta property="og:description" content="${esc(description)}">
<meta property="og:image" content="${SITE_URL}images/social-preview.png">
<meta name="twitter:card" content="summary_large_image">
<link rel="icon" href="${root}images/icon-dark.svg" type="image/svg+xml">
<link rel="stylesheet" href="${root}assets/styles.css">
</head>
<body class="${wide ? "play-page" : ""}">
<header class="nav"><div class="wrap">
  <a class="brand" href="${root}"><img src="${root}images/icon-dark.svg" alt="" width="30" height="30"><span>HAZE</span></a>
  <button class="nav-toggle" aria-expanded="false" aria-label="Menu">Menu</button>
  <nav class="nav-links" aria-label="Main">${nav}<a href="${GITHUB}">GitHub</a></nav>
</div></header>
<main>${body}</main>
${wide ? "" : footer(root)}
${data ? `<script type="application/json" id="page-data">${JSON.stringify(data).replace(/</g, "\\u003c")}</script>` : ""}
<script type="module" src="${root}assets/${script}.js"></script>
</body>
</html>
`;
}

function footer(root) {
  return `<footer><div class="wrap">
  <div>
    <a class="brand" href="${root}"><img src="${root}images/icon-dark.svg" alt="" width="26" height="26"><span>HAZE</span></a>
    <p>Haze is source-available under the <a href="${GITHUB}/blob/main/LICENSE.md">Functional Source License</a> (FSL-1.1-ALv2):
    free to use for anything, including at work, except offering it as a competing product or service.
    Each release becomes Apache-2.0 two years after it ships.</p>
    <p>v0.1, experimental: the language may still change. © 2026 Ritabrata Maiti</p>
  </div>
  <div><h4>Learn</h4><ul>
    <li><a href="${root}tour/">Tour</a></li><li><a href="${root}play/">Playground</a></li>
    <li><a href="${root}gallery/">Gallery</a></li><li><a href="${root}docs/">Documentation</a></li>
    <li><a href="${root}docs/reference/">Language reference</a></li><li><a href="${root}docs/faq/">FAQ</a></li></ul></div>
  <div><h4>Project</h4><ul>
    <li><a href="${GITHUB}">GitHub</a></li><li><a href="${GITHUB}/releases">Releases</a></li>
    <li><a href="${GITHUB}/blob/main/CONTRIBUTING.md">Contributing</a></li><li><a href="${GITHUB}/issues">Issues</a></li></ul></div>
</div></footer>`;
}

const codeBlock = (id, code) => `<pre class="code" id="${id}">${esc(code)}</pre>`;
function feature(id, title, text, presetId) {
  const p = preset(presetId);
  return `<article class="feature">
  <h3>${title}</h3>
  <p>${text}</p>
  ${codeBlock(`code-${id}`, p.code)}
  <div class="results" data-feature="${id}"></div>
  <div><a class="btn" href="play/?example=${presetId}" data-open="code-${id}">Open in the playground →</a></div>
</article>`;
}

const INSTALL = [
  ["macos", "macOS · Linux", "curl -sSfL https://raw.githubusercontent.com/ritabratamaiti/haze-lang/main/install.sh | sh"],
  ["windows", "Windows", "irm https://raw.githubusercontent.com/ritabratamaiti/haze-lang/main/install.ps1 | iex"],
  ["docker", "Docker", 'docker run --rm -v "$PWD:/work" ghcr.io/ritabratamaiti/haze-lang model.hz'],
  ["action", "GitHub Action", "- uses: ritabratamaiti/haze-lang@v0.1.0\n  with:\n    files: models/*.hz"],
  ["source", "From source", "git clone https://github.com/ritabratamaiti/haze-lang\ncd haze-lang && lake build\nlake exe haze examples/payments_retry.hz"],
];

const fields = [...new Set(GALLERY.map((e) => e.field))];
const home = `
<section class="hero"><div class="wrap hero-grid">
  <div>
    <picture>
      <source media="(prefers-color-scheme: light)" srcset="images/logo-light.svg">
      <img class="hero-logo" src="images/logo-dark.svg" alt="Haze">
    </picture>
    <h1>Check software that <span class="glow">fails some of the time</span>.</h1>
    <p class="lede">Haze is a small language for modeling systems that can fail, like a client that
    retries when a message is lost. You describe the system and what it should guarantee, and Haze
    computes how likely each guarantee is to hold, with exact fractions rather than simulation. When
    one can fail, Haze shows you a run where it does.</p>
    <div class="cta">
      <a class="btn primary big" href="#try-it">Try it in your browser</a>
      <a class="btn big" href="tour/">Take the tour</a>
      <a class="btn big" href="#install">Install</a>
    </div>
    <p class="muted small">Version 0.1. Haze is experimental, and the language may still change.</p>
  </div>
  <div class="hero-card">
    <canvas id="hero-canvas" aria-label="Payments flowing through a retry protocol. Red particles are customers charged twice."></canvas>
    <div class="hero-controls">
      <label for="hero-loss">Messages lost: <strong id="hero-loss-value">10%</strong></label>
      <label class="switch"><input type="checkbox" id="hero-idem"> idempotency key</label>
      <input type="range" id="hero-loss" min="1" max="30" value="10" step="1">
    </div>
    <div class="readout">
      <div class="q">Chance a customer is charged twice, with up to three attempts:</div>
      <div id="hero-exact"><span class="exact">${esc(HERO["10:false"])}</span></div>
      <div class="sim" id="hero-sim"></div>
    </div>
    <p class="small"><a id="hero-play" href="play/?example=retry-bug">Open this model in the playground →</a></p>
  </div>
</div></section>

<section id="try-it"><div class="wrap">
  <h2>Try Haze</h2>
  <p class="lede">This editor runs Haze in your browser. It's the command-line tool's Lean code
  compiled to WebAssembly, so your code isn't sent anywhere. Pick an example, edit it and press Run.</p>
  <div class="widget" id="try">
    <noscript><div class="noscript">The playground needs JavaScript. This is the first example:</div>${codeBlock("noscript-code", PRESETS[0].code)}</noscript>
  </div>
</div></section>

<section><div class="wrap">
  <h2>What Haze does</h2>
  <div class="features">
    ${feature("exact", "Exact answers", "Probabilities are computed as fractions, not estimated by simulation. That includes runs with no length limit: a game of craps can go on for any number of rolls, and the shooter wins with probability exactly 244/495.", "forever")}
    ${feature("rough", "Rates you only roughly know", "If you only know that the loss rate is around 2% and might be 10%, you can write that. The answer is then a range: how strongly what you know guarantees the property, and how strongly it allows it.", "rough-numbers")}
    ${feature("cex", "Counterexamples", "A theorem has to hold on every run that can happen. When it doesn't, Haze shows the parameter values, the state and the step where it breaks.", "retry-bug")}
    ${feature("tests", "Tests from a model", "<code>#tests</code> lists a model's most likely runs as test cases and says how much of the probability they cover. For behavior that fails by design some of the time, it sizes a statistical test with a known false-alarm rate.", "tests")}
  </div>
</div></section>

<section><div class="wrap">
  <h2>How it works</h2>
  <p class="lede">Haze is written in Lean 4 and follows Lean's design. An elaborator turns what you
  write into a small core language, and a separate kernel checks every declaration again before
  Haze accepts it.</p>
  <div class="pipeline">
    <div class="stage"><h3>Parser</h3><p>Reads models, claims and queries.</p></div>
    <div class="stage"><h3>Elaborator</h3><p>Infers types and translates to the core language. Its output is checked, so it doesn't need to be trusted.</p></div>
    <div class="stage trusted"><span class="tag">TRUSTED</span><h3>Kernel</h3><p>Checks every declaration again. Besides its type, each term gets a grade that says what it depends on:</p>
      <div class="grades"><code>crisp</code><code>prob</code><code>fuzzy</code><code>partial</code></div></div>
    <div class="stage"><h3>Checker</h3><p>Computes results with exact fractions. Large state spaces are solved in floating point, and the bounds are then checked exactly.</p></div>
  </div>
</div></section>

<section><div class="wrap">
  <h2>How Haze compares</h2>
  <p class="lede">Haze is new and small. For large models or nondeterminism, use PRISM or Storm, and
  for properties that must hold at every size, use Lean. Haze is for small models of real software
  when you want exact answers, rough rates or generated tests.</p>
  <div class="table-scroll"><table class="compare">
    <thead><tr><th></th><th class="haze">Haze</th><th>PRISM, Storm</th><th>Lean</th><th>Probabilistic programming (Stan, PyMC)</th></tr></thead>
    <tbody>
      <tr><td>Answers</td><td class="haze">Exact probabilities and expectations (certified bounds for large unbounded problems), proofs over every run of a finite model, counterexamples, generated tests</td><td>Probabilities, expectations and rewards for temporal logics (PCTL, CSL)</td><td>Proofs that hold for every input and size</td><td>Posterior distributions by inference</td></tr>
      <tr><td>Rates you only roughly know</td><td class="haze">Fuzzy parameters give a belief–plausibility range</td><td>Parametric and interval models</td><td>Whatever you formalize and prove yourself</td><td>Priors over parameters</td></tr>
      <tr><td>Arithmetic</td><td class="haze">Exact fractions; floating point only proposes bounds that are then checked exactly</td><td>Floating point by default, with exact modes</td><td>Exact</td><td>Sampling or approximation</td></tr>
      <tr><td>Models</td><td class="haze">Discrete-time Markov chains; no nondeterminism or continuous time yet</td><td>DTMCs, MDPs, CTMCs, games and more</td><td>Any mathematics</td><td>Statistical models, often continuous</td></tr>
      <tr><td>Scale</td><td class="haze">Explicit states: up to 2 million configurations per step, and 100,000 states by default for unbounded properties</td><td>Much larger, with symbolic engines</td><td>Unbounded, with effort</td><td>Large data sets</td></tr>
      <tr><td>Effort</td><td class="haze">Write a model; checking is automatic</td><td>Write a model; checking is automatic</td><td>Write the proofs</td><td>Write a model; tune inference</td></tr>
    </tbody>
  </table></div>
</div></section>

<section id="install"><div class="wrap">
  <h2>Install</h2>
  <p class="lede">There are prebuilt binaries for Linux (x86-64), macOS (Apple silicon) and Windows
  (x86-64), and the install scripts
  check each download against the published checksums. You can also use Docker or GitHub Actions,
  or <a href="docs/installation/#building-from-source">build Haze from source</a> with Lean's toolchain.</p>
  <div class="install-tabs" data-tabs role="tablist">
    ${INSTALL.map(([id, label], i) => `<button class="chip-btn ${i ? "" : "active"}" role="tab" aria-selected="${!i}" aria-controls="install-${id}">${label}</button>`).join("")}
  </div>
  ${INSTALL.map(([id, , cmd], i) => `<div class="install-panel" id="install-${id}" ${i ? "hidden" : ""}><pre id="cmd-${id}">${esc(cmd)}</pre><button class="btn copy" data-copy="cmd-${id}">Copy</button></div>`).join("")}
</div></section>

<section><div class="wrap">
  <h2>Examples from other fields</h2>
  <p class="lede">The gallery has models from chip design, security, genetics, finance, law and more.
  The science and engineering models are checked against closed-form results or independent
  calculations by <code>scripts/verify_gallery.py</code>.</p>
  <div class="fields">
    ${fields.map((f) => { const n = GALLERY.filter((e) => e.field === f); return `<a class="field-card" href="gallery/#${slug(f)}"><strong>${esc(f)}</strong><span>${esc(n.map((e) => e.title).join(", "))}</span></a>`; }).join("")}
  </div>
</div></section>`;

const features = { exact: preset("forever").records, rough: preset("rough-numbers").records, cex: preset("retry-bug").records, tests: preset("tests").records };

// ---- write -------------------------------------------------------------------------------
rmSync(DIST, { recursive: true, force: true });
mkdirSync(join(DIST, "assets"), { recursive: true });
const page = (dir, html) => { mkdirSync(join(DIST, dir), { recursive: true }); writeFileSync(join(DIST, dir, "index.html"), html); };

page("", layout({ root: "./", path: "", canonical: "", title: "Haze: check software that fails some of the time", script: "home",
  description: "Haze is a small language for checking software that fails some of the time. It computes exact probabilities, shows counterexamples and generates tests, and you can try it in your browser.",
  body: home, data: { presets: PRESETS, hero: HERO, features } }));
page("play", layout({ root: "../", path: "play/", canonical: "play/", title: "Playground · Haze", script: "play", wide: true,
  description: "Write and check Haze models in your browser.",
  body: `<h1 class="sr-only" style="position:absolute;left:-9999px">Haze playground</h1><div class="widget" id="playground"><noscript><div class="noscript wrap">The playground needs JavaScript.</div></noscript></div>`,
  data: { presets: PRESETS } }));
page("tour", layout({ root: "../", path: "tour/", canonical: "tour/", title: "Tour · Haze", script: "tour",
  description: "A short interactive tour of the Haze language.",
  body: `<div class="wrap tour"><nav id="tour-nav" aria-label="Chapters"></nav><div>
    <div id="tour-prose">${TOUR[0].html}</div>
    <div class="widget" id="tour-widget"><noscript>${codeBlock("tour-noscript", TOUR[0].code)}</noscript></div>
    <div class="tour-foot"><button class="btn" id="tour-prev">← Previous</button><span class="muted" id="tour-count"></span><button class="btn primary" id="tour-next">Next →</button></div>
  </div></div>`, data: { chapters: TOUR } }));
page("gallery", layout({ root: "../", path: "gallery/", canonical: "gallery/", title: "Gallery · Haze", script: "gallery",
  description: "Haze examples from software, chip design, security, genetics, finance, law and more.",
  body: `<div class="wrap" style="padding-top:40px"><div class="eyebrow">Gallery</div><h2>Examples</h2>
    <p class="lede">Every example in the repository with its output. Open one to see the model and the results, or edit it in the playground.</p>
    <div id="gallery-filters"></div><div id="gallery"></div></div>`, data: { examples: GALLERY } }));

const rendered = DOCS.map((d) => ({ ...d, ...renderDoc(read(join(REPO, d.path)), d.path) }));
function docsNav(root, current) {
  return DOC_SECTIONS.map(([section, pages]) => `<div class="docs-section"><h4>${section}</h4>` +
    pages.map(([id, label]) => `<a href="${root}docs/${id}/"${id === current ? ' class="active" aria-current="page"' : ""}>${esc(label)}</a>`).join("") + "</div>").join("") +
    `<div class="docs-section"><h4>Learn by doing</h4><a href="${root}tour/">Tour</a><a href="${root}play/">Playground</a><a href="${root}gallery/">Gallery</a></div>`;
}
for (const [i, d] of rendered.entries()) {
  const root = "../../";
  const prev = rendered[i - 1], next = rendered[i + 1];
  const toc = d.headings.length > 1 ? `<aside class="doc-toc" aria-label="On this page"><h4>On this page</h4>${d.headings.map(([hid, t]) => `<a href="#${hid}">${esc(t)}</a>`).join("")}</aside>` : "<aside class=\"doc-toc\"></aside>";
  const foot = `<nav class="doc-pager" aria-label="Previous and next">
    ${prev ? `<a href="${root}docs/${prev.id}/"><span>Previous</span>${esc(prev.label)}</a>` : "<span></span>"}
    ${next ? `<a class="next" href="${root}docs/${next.id}/"><span>Next</span>${esc(next.label)}</a>` : "<span></span>"}</nav>
    <p class="doc-meta">These docs describe Haze 0.1. <a href="${GITHUB}/edit/main/${d.path}">Edit this page on GitHub</a></p>`;
  page(`docs/${d.id}`, layout({ root, path: "docs/", canonical: `docs/${d.id}/`, title: `${d.label} · Haze`, script: "docs", description: d.summary,
    body: `<div class="wrap docs"><nav class="docs-nav" aria-label="Documentation">${docsNav(root, d.id)}</nav>
<article class="prose"><div class="eyebrow">${esc(d.section)}</div><h1>${esc(d.title)}</h1>${d.html.replaceAll("@ROOT@", root)}${foot}</article>${toc}</div>` }));
}
page("docs", layout({ root: "../", path: "docs/", canonical: "docs/", title: "Documentation · Haze", script: "docs",
  description: "Documentation for Haze: installation, a first model, guides, the language reference and how Haze compares with other tools.",
  body: `<div class="wrap docs-home"><h1>Documentation</h1>
  <p class="lede">These pages describe Haze 0.1. If you're new, install Haze and write <a href="first-model/">your first model</a>, or take the <a href="../tour/">tour</a> in your browser.</p>
  ${DOC_SECTIONS.map(([section, pages]) => `<section><h2>${section}</h2><div class="doc-cards">${pages.map(([id]) => { const d = rendered.find((x) => x.id === id); return `<a class="doc-card" href="${id}/"><strong>${esc(d.label)}</strong><span>${esc(d.summary)}</span></a>`; }).join("")}</div></section>`).join("")}
  </div>` }));

cpSync(join(SITE, "styles.css"), join(DIST, "assets", "styles.css"));
mkdirSync(join(DIST, "images"), { recursive: true });
for (const f of ["icon-dark.svg", "icon-light.svg", "logo-dark.svg", "logo-light.svg", "logo-dark.png", "social-preview.png"]) cpSync(join(REPO, "docs", "images", f), join(DIST, "images", f));
mkdirSync(join(DIST, "engine"), { recursive: true });
for (const f of ["haze.mjs", "haze.wasm"]) cpSync(join(ENGINE, f), join(DIST, "engine", f));
writeFileSync(join(DIST, ".nojekyll"), "");
// the 404 page is served at any depth, so its links are absolute
writeFileSync(join(DIST, "404.html"), layout({ root: "/", path: "", title: "Page not found · Haze", script: "docs",
  description: "This page doesn't exist.",
  body: `<div class="wrap" style="padding:80px 0"><h1>Page not found</h1><p class="lede">There's no page at this address. Try the <a href="/">home page</a>, the <a href="/docs/">documentation</a> or the <a href="/play/">playground</a>.</p></div>` }));
const pages = ["", "play/", "tour/", "gallery/", "docs/", ...DOCS.map((d) => `docs/${d.id}/`)];
writeFileSync(join(DIST, "sitemap.xml"), `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${pages.map((u) => `  <url><loc>${SITE_URL}${u}</loc></url>`).join("\n")}\n</urlset>\n`);
writeFileSync(join(DIST, "robots.txt"), `User-agent: *\nAllow: /\nSitemap: ${SITE_URL}sitemap.xml\n`);

await build({
  entryPoints: Object.fromEntries(["home", "play", "tour", "gallery", "docs"].map((n) => [n, join(SITE, "src", "pages", `${n}.ts`)])),
  outdir: join(DIST, "assets"), bundle: true, format: "esm", splitting: true, minify: true, sourcemap: false, target: "es2022",
  logLevel: "warning",
});
await build({
  entryPoints: [join(SITE, "src", "worker.ts")], outfile: join(DIST, "engine", "worker.js"), bundle: true, format: "esm",
  minify: true, target: "es2022", external: ["./haze.mjs"], logLevel: "warning",
});
rmSync(tmp, { recursive: true, force: true });
const size = (d) => readdirSync(d, { withFileTypes: true }).reduce((n, e) => n + (e.isDirectory() ? size(join(d, e.name)) : readFileSync(join(d, e.name)).length), 0);
console.log(`built site/dist (${(size(DIST) / 1e6).toFixed(1)} MB): ${PRESETS.length} presets, ${TOUR.length} tour chapters, ${GALLERY.length} examples, ${DOCS.length} docs`);

// ---- serve -------------------------------------------------------------------------------
if (process.argv.includes("--serve")) {
  const TYPES = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript", ".css": "text/css", ".svg": "image/svg+xml", ".png": "image/png", ".wasm": "application/wasm", ".json": "application/json" };
  createServer((req, res) => {
    let p = decodeURIComponent(new URL(req.url, "http://x").pathname);
    let f = join(DIST, p);
    if (existsSync(f) && !extname(f)) f = join(f, "index.html");
    if (!existsSync(f)) { res.writeHead(404); res.end("not found"); return; }
    res.writeHead(200, { "content-type": TYPES[extname(f)] ?? "application/octet-stream" });
    res.end(readFileSync(f));
  }).listen(8080, () => console.log("serving at http://localhost:8080/"));
}
