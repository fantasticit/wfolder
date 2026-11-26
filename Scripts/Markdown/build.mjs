import { build } from "esbuild";
import { readFile, readdir, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const outdir = fileURLToPath(new URL("../../Sources/PerchFiles/Resources/Markdown/", import.meta.url));
const result = await build({
  entryPoints: ["preview.mjs", "diagrams.mjs"],
  outdir,
  bundle: true,
  minify: true,
  format: "iife",
  target: "safari17",
  legalComments: "eof",
  metafile: true,
});

// Preserve the notices of the dependencies actually incorporated into the app.
const notices = new Set();
const packages = new Set();
for (const file of Object.keys(result.metafile.inputs)) {
  const packageRoot = file.match(/^(.*node_modules\/(?:@[^/]+\/)?[^/]+)\//)?.[1];
  if (packageRoot) packages.add(resolve(packageRoot));
}
for (const packageRoot of [...packages].sort()) {
  const { name, version, license } = JSON.parse(await readFile(join(packageRoot, "package.json"), "utf8"));
  const licenses = (await readdir(packageRoot)).filter(file => /^(license|licence|copying|notice)([-.][\w.-]+)?$/i.test(file));
  if (!licenses.length) throw new Error(`Missing license text for ${name} (${license}) in ${dirname(packageRoot)}`);
  const contents = await Promise.all(licenses.map(file => readFile(join(packageRoot, file), "utf8")));
  notices.add(`${name} ${version}\n${contents.join("\n\n").trim()}`);
}
await writeFile(join(outdir, "ThirdPartyNotices.txt"), [...notices].join("\n\n---\n\n") + "\n");
