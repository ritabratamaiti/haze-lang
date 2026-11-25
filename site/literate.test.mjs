import assert from "node:assert/strict";
import test from "node:test";
import { percent, readEssay } from "./literate.mjs";

test("pairs each scene with its code and original diagnostic lines", () => {
  const src = [
    "/-", "# A ledger", "An introduction on", "two lines.", "", "Run: `haze test.hz`.", "-/",
    "", "/-", "## The first entry", "Read this before the declaration.", "-/", "", "system Game {",
    "  -- Part of the code", "}", "", "#prob true -- also code", "",
    "/-", "## The second entry", "Read this before the query.", "-/", "#prob false", "",
  ].join("\r\n");
  const post = readEssay(src, "test.hz");
  assert.equal(post.title, "A ledger");
  assert.equal(post.summary, "An introduction on two lines.");
  assert.equal(post.usage, "Run: `haze test.hz`.");
  const [a, b] = post.entries;
  assert.equal(a.story, "Read this before the declaration.");
  assert.equal(a.source, "system Game {\n  -- Part of the code\n}\n\n#prob true -- also code");
  assert.deepEqual([a.line, a.endLine, b.line], [14, 19, 24]);
});

test("doesn't silently discard executable code in a comment header", () => {
  assert.throws(() => readEssay("/-\n# Report\nIntro\n-/\n#prob true\n/-\n## End\nStory\n-/\n#prob false\n", "a.hz"),
    /a\.hz: put executable lines in a spread/);
  assert.throws(() => readEssay("/-\n# Report\nIntro\n-/\n/-\n## Open\n", "a.hz"), /a\.hz:5: unclosed story block/);
});

test("prints slip percentages from exact fractions without floating-point overflow", () => {
  assert.equal(percent("9/19"), "47.37%");
  assert.equal(percent("1"), "100%");
  const k = 10n ** 400n;
  assert.equal(percent(`${k}/${8n * k}`), "12.5%");
});
