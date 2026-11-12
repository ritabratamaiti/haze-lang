// The playground: the full editor, opened with a preset or with code from a share link.
import { common, root, pageData } from "../common";
import { mountWidget, Preset } from "../widget";
import { codeFromHash } from "../share";

common();
const data = pageData<{ presets: Preset[] }>();
const host = document.getElementById("playground")!;
const params = new URLSearchParams(location.search);

(async () => {
  const shared = await codeFromHash();
  const presetId = params.get("example") ?? undefined;
  mountWidget(host, {
    presets: data.presets,
    root: root(),
    live: true,
    initial: shared ? { code: shared } : presetId ? { code: "", presetId } : undefined,
  });
})();
