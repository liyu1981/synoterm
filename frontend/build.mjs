#!/usr/bin/env node
// Bundles the xterm.js UI into frontend/dist (no framework, no CDN, works
// offline — important for a NAS that may never reach the internet).
import { build, context } from "esbuild";
import { cpSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const outdir = join(here, "dist");
const watch = process.argv.includes("--watch");

rmSync(outdir, { recursive: true, force: true });
mkdirSync(outdir, { recursive: true });

const options = {
  entryPoints: [join(here, "src/main.js")],
  bundle: true,
  outfile: join(outdir, "app.js"),
  format: "iife",
  platform: "browser",
  target: ["chrome100", "firefox100", "safari15"],
  minify: !watch,
  sourcemap: watch ? "inline" : false,
  legalComments: "none",
  loader: { ".css": "text" },
};

if (watch) {
  const ctx = await context(options);
  await ctx.watch();
  console.log("watching frontend/src →", outdir);
} else {
  await build(options);
}

cpSync(join(here, "src/index.html"), join(outdir, "index.html"));
// Runtime configuration. The DSM packaging step overwrites this with the
// nginx mount path (e.g. "/synoterm/ws"); empty means "derive from the URL".
writeFileSync(
  join(outdir, "config.js"),
  'window.SYNOTERM_CONFIG = {};\n',
);
cpSync(join(here, "..", "assets", "icon.svg"), join(outdir, "icon.svg"));
// style.css is bundled into app.js as text and injected at boot, so DSM's
// upgrade path cannot leave a stale <link> pointing at an old stylesheet.
console.log("built", outdir);
