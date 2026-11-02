#!/usr/bin/env node
// End-to-end test: boots synoterm, opens the UI in headless Chromium, types in
// the terminal and asserts the shell answered.
//
//   zig build && node tools/e2e.mjs
//
// Requires a Chromium/Chrome binary. Discovery order:
//   $SYNOTERM_CHROMIUM, playwright's cache, system chromium/chrome.
import { spawn } from "node:child_process";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..");
const PORT = process.env.SYNOTERM_E2E_PORT || "18099";

function findChromium() {
  if (process.env.SYNOTERM_CHROMIUM) return process.env.SYNOTERM_CHROMIUM;
  const cache = join(homedir(), ".cache", "ms-playwright");
  if (existsSync(cache)) {
    for (const entry of readdirSync(cache).sort().reverse()) {
      if (!entry.startsWith("chromium-")) continue;
      const candidate = join(cache, entry, "chrome-linux", "chrome");
      if (existsSync(candidate)) return candidate;
    }
  }
  for (const candidate of [
    "/usr/bin/chromium",
    "/usr/bin/chromium-browser",
    "/usr/bin/google-chrome",
    "/snap/bin/chromium",
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  ]) {
    if (existsSync(candidate)) return candidate;
  }
  return null;
}

function loadPlaywright() {
  for (const specifier of ["playwright-core", "playwright"]) {
    try {
      return import(specifier);
    } catch {
      /* try the next one */
    }
  }
  try {
    return import("/tmp/node_modules/playwright-core/index.mjs");
  } catch {
    return null;
  }
}

const chromiumPath = findChromium();
const playwright = await loadPlaywright();
if (!playwright) {
  console.error("e2e: skipped (need `npm i playwright-core` or `npm i playwright`)");
  process.exit(0);
}

const binary = join(root, "zig-out", "bin", "synoterm");
if (!existsSync(binary)) {
  console.error(`e2e: ${binary} missing — run \`zig build\` first`);
  process.exit(1);
}

// Guard against a leftover cross-compiled binary (e.g. after build-spk.sh for
// armv8): it cannot run here and the failure mode is a confusing "did not start".
const hostMachine = { x64: 62, arm64: 183, arm: 40 }[process.arch];
if (hostMachine) {
  const header = readFileSync(binary).subarray(0, 20);
  if (header[0] !== 0x7f || header[1] !== 0x45) {
    console.error("e2e: binary is not an ELF file");
    process.exit(1);
  }
  const machine = header.readUInt16LE(18);
  if (machine !== hostMachine) {
    console.error(
      `e2e: ${binary} is built for ELF machine ${machine}, this host needs ${hostMachine}.\n` +
        "     run `zig build` (native) before the e2e test.",
    );
    process.exit(1);
  }
}

const server = spawn(
  binary,
  ["--listen", PORT, "--auth", "dev", "--web-root", join(root, "frontend", "dist")],
  { stdio: ["ignore", "pipe", "pipe"] },
);
server.stderr.on("data", (chunk) => process.stderr.write(`[synoterm] ${chunk}`));

const ready = await new Promise((resolve) => {
  const timer = setTimeout(() => resolve(false), 5000);
  server.stderr.on("data", (chunk) => {
    if (String(chunk).includes("listening")) {
      clearTimeout(timer);
      resolve(true);
    }
  });
});
if (!ready) {
  console.error("e2e: server did not start");
  server.kill();
  process.exit(1);
}

const failures = [];
// `chromiumPath` may be null: playwright then uses its own browser cache
// (that is how CI runs it after `npx playwright install chromium`).
const browser = await playwright.chromium.launch({
  ...(chromiumPath ? { executablePath: chromiumPath } : {}),
  args: ["--no-sandbox"],
});

try {
  // Clipboard permissions so the paste/copy shortcuts can be exercised.
  const context = await browser.newContext({ permissions: ["clipboard-read", "clipboard-write"] });
  const page = await context.newPage();
  page.on("pageerror", (error) => failures.push(`pageerror: ${error}`));

  await page.goto(`http://127.0.0.1:${PORT}/`, { waitUntil: "load" });
  await page.waitForFunction(() => document.querySelector('#status-text')?.textContent?.startsWith('connected'), {
    timeout: 8000,
  });

  const status = await page.textContent("#status-text");
  if (!/connected/.test(status)) failures.push(`status was "${status}"`);

  await page.keyboard.type("echo SYNOTERM_E2E_OK\n");
  await page.waitForTimeout(1200);

  const screen = await page.evaluate(
    () => document.querySelector(".terminal-pane.active .xterm-rows")?.innerText || "",
  );
  if (!screen.includes("SYNOTERM_E2E_OK")) failures.push("shell output did not reach xterm.js");

  // New tab (Ctrl+Shift+T) must produce a second, working session.
  await page.keyboard.press("Control+Shift+T");
  await page.waitForTimeout(900);
  const tabs = await page.evaluate(() => document.querySelectorAll("#tabs .tab").length);
  if (tabs !== 2) failures.push(`expected 2 tabs, saw ${tabs}`);

  // Regression guard: xterm.js's own stylesheet must be loaded, otherwise its
  // helper elements stay visible and paint stray rows of characters (the
  // "$$$$$$$$" / "----4444" artifact seen on a real NAS).
  const xtermStyles = await page.evaluate(() => {
    const pane = document.querySelector(".terminal-pane.active");
    const helper = pane.querySelector(".xterm-helper-textarea");
    const cache = pane.querySelector(".xterm-width-cache-measure-container");
    const cacheRect = cache ? cache.getBoundingClientRect() : null;
    return {
      helperOpacity: helper ? getComputedStyle(helper).opacity : "missing",
      cachePainted: !!(cacheRect && cacheRect.width > 0 && cacheRect.height > 0),
    };
  });
  if (xtermStyles.helperOpacity !== "0") {
    failures.push(`xterm.css missing? helper textarea opacity=${xtermStyles.helperOpacity} (expected 0)`);
  }
  if (xtermStyles.cachePainted) {
    failures.push("xterm width-cache measure container is painted over the screen (missing xterm.css)");
  }

  const size = await page.evaluate(() => {
    const s = window.synoterm.active;
    return { cols: s.term.cols, rows: s.term.rows };
  });
  if (size.cols < 20 || size.rows < 5) failures.push(`unexpected terminal size ${JSON.stringify(size)}`);

  // The control endpoint must exist and agree with the working session: the UI
  // depends on it to explain refusals (a stale token, no DSM session, …).
  const statusProbe = await page.evaluate(async () => {
    const response = await fetch("/status", { credentials: "same-origin" });
    let body;
    try {
      body = await response.json();
    } catch {
      body = undefined;
    }
    return { code: response.status, body };
  });
  if (statusProbe.code !== 200 || !statusProbe.body?.ok) {
    failures.push(`/status returned ${statusProbe.code} ${JSON.stringify(statusProbe.body)}`);
  }
  if (!statusProbe.body?.version) failures.push("/status did not report a server version");

  // Appearance settings: font size must apply live (re-measuring the terminal)
  // and survive a reload.
  await page.click("#settings");
  await page.fill("#set-font-size", "18");
  await page.dispatchEvent("#set-font-size", "change");
  await page.waitForTimeout(500);
  const fontState = await page.evaluate(() => ({
    fontSize: window.synoterm.active.term.options.fontSize,
    stored: JSON.parse(window.localStorage.getItem("synoterm.settings.v1") || "{}"),
  }));
  if (fontState.fontSize !== 18) failures.push(`font size not applied: ${fontState.fontSize}`);
  if (fontState.stored.fontSize !== 18) failures.push("font size was not persisted");

  await page.reload({ waitUntil: "load" });
  await page.waitForFunction(
    () => document.querySelector("#status-text")?.textContent?.startsWith("connected"),
    { timeout: 8000 },
  );
  const fontSizeAfterReload = await page.evaluate(() => window.synoterm.active.term.options.fontSize);
  if (fontSizeAfterReload !== 18) failures.push(`font size not restored after reload: ${fontSizeAfterReload}`);
  // Leave the profile at defaults for the next run.
  await page.evaluate(() => window.localStorage.removeItem("synoterm.settings.v1"));

  // Header layout: the appearance button sits on the right, after the status.
  const header = await page.evaluate(() => {
    const settings = document.querySelector("#header-right #settings");
    const status = document.querySelector("#status");
    if (!settings || !status) return { ok: false };
    return {
      ok: true,
      settingsRightOfStatus: settings.getBoundingClientRect().left >= status.getBoundingClientRect().left,
    };
  });
  if (!header.ok) failures.push("#settings is not inside #header-right");
  else if (!header.settingsRightOfStatus) failures.push("#settings is not to the right of #status");

  // Clipboard: paste (Ctrl+V and Ctrl+Shift+V) must reach the shell, and
  // Ctrl+C must copy the selection instead of sending ^C.
  await page.click(".terminal-pane.active");
  await page.evaluate(() => navigator.clipboard.writeText("echo E2E_PASTE_CTRL_V"));
  await page.keyboard.press("Control+V");
  await page.waitForTimeout(300);
  await page.keyboard.press("Enter");
  await page.waitForTimeout(700);
  let clipScreen = await page.evaluate(() => document.querySelector(".terminal-pane.active .xterm-rows")?.innerText || "");
  if (!clipScreen.includes("E2E_PASTE_CTRL_V")) failures.push("Ctrl+V did not paste into the shell");

  await page.evaluate(() => navigator.clipboard.writeText("echo E2E_PASTE_CTRL_SHIFT_V"));
  await page.keyboard.press("Control+Shift+V");
  await page.waitForTimeout(300);
  await page.keyboard.press("Enter");
  await page.waitForTimeout(700);
  clipScreen = await page.evaluate(() => document.querySelector(".terminal-pane.active .xterm-rows")?.innerText || "");
  if (!clipScreen.includes("E2E_PASTE_CTRL_SHIFT_V")) failures.push("Ctrl+Shift+V did not paste into the shell");

  await page.evaluate(() => {
    navigator.clipboard.writeText("");
    window.synoterm.active.term.selectAll();
  });
  await page.keyboard.press("Control+C");
  await page.waitForTimeout(300);
  const copied = await page.evaluate(() => navigator.clipboard.readText());
  if (!copied || copied.length === 0) failures.push("Ctrl+C with a selection did not copy it");
  if (await page.evaluate(() => window.synoterm.active.term.hasSelection())) {
    failures.push("Ctrl+C did not clear the selection after copying");
  }

  // Optional slow check (SYNOTERM_E2E_SLOW=1): a session must survive idling
  // longer than the HTTP header timeout (30s).
  if (process.env.SYNOTERM_E2E_SLOW === "1") {
    await page.waitForTimeout(35000);
    const idleStatus = await page.textContent("#status-text");
    if (!/connected/.test(idleStatus)) failures.push(`session dropped while idle: "${idleStatus}"`);
  }
} catch (error) {
  failures.push(String(error));
} finally {
  await browser.close();
  server.kill("SIGTERM");
}

if (failures.length > 0) {
  console.error("e2e: FAILED");
  for (const failure of failures) console.error(` - ${failure}`);
  process.exit(1);
}
console.log("e2e: ok");
