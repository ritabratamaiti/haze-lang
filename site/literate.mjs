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

// Quoted Haze in the prose must be real, consecutive lines from the executable part of that section.
export function isSourceExcerpt(quote, source) {
  const lines = (s) => s.trim().split(/\r?\n/).map((l) => l.trim());
  const want = lines(quote), have = lines(source);
  return quote.trim() !== "" && have.some((_, i) => want.every((line, j) => line === have[i + j]));
}
