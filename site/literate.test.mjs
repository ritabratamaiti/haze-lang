import assert from "node:assert/strict";
import test from "node:test";
import { assembleEssay, blockOutput, isSourceExcerpt, readEssay, readSigns, signEquation } from "./literate.mjs";

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

test("accepts a dedented quotation, but not changed, partial or spliced lines", () => {
  const source = "    let stake := min(money, 100 - money)\n    let before := money\n    money := money + stake";
  assert.ok(isSourceExcerpt("let stake := min(money, 100 - money)\nlet before := money", source));
  assert.equal(isSourceExcerpt("let stake := money", source), false);
  assert.equal(isSourceExcerpt("let before", source), false);
  assert.equal(isSourceExcerpt("let stake := min(money, 100 - money)\nmoney := money + stake", source), false);
});

test("the matrix example distinguishes flipping a sign from squaring each product", () => {
  const entries = readSigns("+1 +1\n+1 +1\n");
  assert.equal(signEquation(entries), "det² = (1 − 1)² = 0");
  entries[3] = -1;
  assert.equal(signEquation(entries), "det² = ((−1) − 1)² = 4");
  assert.throws(() => readSigns("1 1 1 1"), /two rows/);
  assert.throws(() => readSigns("1 1\n1 0"), /entries/);
});

test("editing one block preserves prose and moves the next block's diagnostic lines", () => {
  const original = "-- story\n#eval 1\n\n-- more story\n#eval 2\n";
  const { code, ranges } = assembleEssay(original, [
    { line: 2, originalLength: 1, value: "def n : Num := 3\n#eval n" },
    { line: 5, originalLength: 1, value: "#eval n + 2" },
  ]);
  assert.equal(code, "-- story\ndef n : Num := 3\n#eval n\n\n-- more story\n#eval n + 2\n");
  assert.deepEqual(ranges, [{ first: 2, last: 3 }, { first: 6, last: 6 }]);
  assert.equal(blockOutput([
    { line: 2, severity: "error", message: "missing definition" },
    { line: 3, severity: "info", message: "old query" },
    { line: 6, severity: "error", message: "unknown name" },
  ], ranges[1].first), "Earlier block, file line 2: missing definition\n\nLine 1: unknown name");
});
