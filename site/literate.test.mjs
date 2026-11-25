import assert from "node:assert/strict";
import test from "node:test";
import { isSourceExcerpt, readEssay } from "./literate.mjs";

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
