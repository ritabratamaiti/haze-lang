// Only a Haze block with a Markdown heading opens a spread. Ordinary comments belong to the code.
export function readEssay(code, file) {
  const lines = code.trimEnd().split(/\r?\n/);
  const cells = [];
  for (let i = 0; i < lines.length; i++) {
    if (lines[i] !== "/-" || !/^#{1,2} /.test(lines[i + 1] ?? "")) continue;
    const close = lines.indexOf("-/", i + 2);
    if (close === -1) throw new Error(`${file}:${i + 1}: unclosed story block`);
    cells.push({ heading: lines[i + 1], story: lines.slice(i + 2, close).join("\n").trim(), start: i, close });
    i = close;
  }
  const [header, ...scenes] = cells;
  if (!header || header.start !== 0 || !header.heading.startsWith("# ") || !header.story || !scenes.length)
    throw new Error(`${file}: expected a title, an introduction and at least one story spread`);
  if (lines.slice(header.close + 1, scenes[0].start).some((l) => l.trim()))
    throw new Error(`${file}: put executable lines in a spread, not before the first one`);
  const [summary, ...usage] = header.story.split(/\n\s*\n/);
  const entries = scenes.map((s, i) => {
    const end = scenes[i + 1]?.start ?? lines.length;
    let first = s.close + 1;
    while (first < end && !lines[first].trim()) first++;
    if (!s.heading.startsWith("## ") || !s.story || first === end)
      throw new Error(`${file}:${s.start + 1}: a spread needs a heading, story and executable source`);
    return { title: s.heading.slice(3).trim(), story: s.story, line: first + 1, endLine: end,
      source: lines.slice(first, end).join("\n").trimEnd() };
  });
  return { title: header.heading.slice(2).trim(), summary: summary.replace(/\n/g, " "),
    usage: usage.join("\n\n"), entries };
}

// Haze supplies exact fractions. Round only the printed percentage, even for very large denominators.
export function percent(q) {
  const [n, den = 1n] = q.split("/").map(BigInt);
  return `${Number((2n * n * 10000n + den) / (2n * den)) / 100}%`;
}
