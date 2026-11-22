#!/usr/bin/env node
// End-to-end test: boots synoterm, opens the UI in headless Chromium, types in
// the terminal and asserts the shell answered.
//
//   zig build && node tools/e2e.mjs
//
// Requires a Chromium/Chrome binary. Discovery order:
//   $SYNOTERM_CHROMIUM, playwright's cache, system chromium/chrome.
import { spawn } from "node:child_process";
import { connect } from "node:net";
import { createServer } from "node:http";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
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

/** Status line of a raw HTTP/1.1 request (fetch() refuses Upgrade headers). */
function rawStatus(port, path, headers = []) {
  return new Promise((resolve) => {
    const socket = connect(Number(port), "127.0.0.1", () => {
      const request = [
        `GET ${path} HTTP/1.1`,
        `Host: 127.0.0.1:${port}`,
        ...headers.map(([name, value]) => `${name}: ${value}`),
        "",
        "",
      ].join("\r\n");
      socket.write(request);
    });
    let data = "";
    const finish = () => {
      socket.destroy();
      const match = /^HTTP\/1\.1 (\d{3})/.exec(data);
      resolve(match ? Number(match[1]) : 0);
    };
    socket.setTimeout(2000, finish);
    socket.on("data", (chunk) => {
      data += chunk;
      if (data.includes("\r\n")) finish();
    });
    socket.on("error", () => resolve(0));
  });
}

const failures = [];
// Servers started by individual checks, killed in finally.
const extraServers = [];
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
  // ---- packaged layout: one prefix for every endpoint ---------------------
  // The package starts the binary with --base-path /synoterm and ships
  // ui/web/config.js = { proxy: "/synoterm", port: … }. The UI must then use
  // /synoterm/{healthz,status,ws} on whichever origin it ends up talking to,
  // and the server must refuse the unprefixed paths. This is the layout that
  // broke on a real NAS (probe 404 → silent fallback to another port), so it
  // gets its own check with the same binary flags and the same config.
  const pkgPort = String(Number(PORT) + 1);
  const pkgRoot = mkdtempSync(join(tmpdir(), "synoterm-e2e-"));
  cpSync(join(root, "frontend", "dist"), pkgRoot, { recursive: true });
  writeFileSync(
    join(pkgRoot, "config.js"),
    `window.SYNOTERM_CONFIG = { proxy: "/synoterm", port: ${pkgPort} };\n`,
  );
  const pkgServer = spawn(
    binary,
    ["--listen", pkgPort, "--auth", "dev", "--web-root", pkgRoot, "--base-path", "/synoterm"],
    { stdio: ["ignore", "pipe", "pipe"] },
  );
  extraServers.push(pkgServer);
  const pkgUp = await new Promise((resolve) => {
    const timer = setTimeout(() => resolve(false), 5000);
    pkgServer.stderr.on("data", (chunk) => {
      if (String(chunk).includes("listening")) {
        clearTimeout(timer);
        resolve(true);
      }
    });
  });
  if (!pkgUp) failures.push("prefixed server did not start");

  const pkgBase = `http://127.0.0.1:${pkgPort}`;
  const probe = async (path) => {
    const response = await fetch(`${pkgBase}${path}`);
    return { code: response.status, body: await response.text() };
  };
  const healthzPrefixed = await probe("/synoterm/healthz");
  if (healthzPrefixed.code !== 200) failures.push(`/synoterm/healthz returned ${healthzPrefixed.code}`);
  const healthzBare = await probe("/healthz");
  if (healthzBare.code !== 404) failures.push(`/healthz outside the prefix returned ${healthzBare.code} (expected 404)`);
  const statusPrefixed = await probe("/synoterm/status");
  if (statusPrefixed.code !== 200) failures.push(`/synoterm/status returned ${statusPrefixed.code}`);
  // The status probe is what a cross-port browser fetch needs: an allowed
  // origin asks, gets the preflight, and may then send X-Syno-Token.
  const preflight = await fetch(`${pkgBase}/synoterm/status`, {
    method: "OPTIONS",
    headers: { Origin: pkgBase, "Access-Control-Request-Headers": "x-syno-token" },
  });
  if (preflight.status !== 204) failures.push(`CORS preflight returned ${preflight.status} (expected 204)`);
  if (!/x-syno-token/i.test(preflight.headers.get("access-control-allow-headers") || "")) {
    failures.push("CORS preflight does not allow X-Syno-Token");
  }

  const pkgContext = await browser.newContext();
  const pkgPage = await pkgContext.newPage();
  pkgPage.on("pageerror", (error) => failures.push(`pageerror (prefixed): ${error}`));
  await pkgPage.goto(`${pkgBase}/synoterm/`, { waitUntil: "load" });
  await pkgPage.waitForFunction(
    () => document.querySelector("#status-text")?.textContent?.startsWith("connected"),
    { timeout: 8000 },
  );
  const chosen = await pkgPage.evaluate(() => window.synotermBackend);
  if (chosen?.prefix !== "/synoterm") failures.push(`prefixed UI used prefix ${JSON.stringify(chosen)}`);
  if (chosen?.mode !== "direct") failures.push(`prefixed UI chose mode ${chosen?.mode} (expected direct)`);
  const pkgStatus = await pkgPage.evaluate(async () => {
    const response = await fetch("/synoterm/status", { credentials: "same-origin" });
    return { code: response.status, body: await response.json().catch(() => undefined) };
  });
  if (pkgStatus.code !== 200 || !pkgStatus.body?.ok) {
    failures.push(`prefixed UI could not read /synoterm/status: ${JSON.stringify(pkgStatus)}`);
  }
  await pkgContext.close();
  rmSync(pkgRoot, { recursive: true, force: true });

  // ---- ssh mode at the proxy root: the terminal is the login prompt --------
  // No DSM cookie or token is involved: the UI asks for an account name, the
  // server runs `ssh -l <user> <host>`, and ssh asks for the password in the
  // terminal. A stub ssh binary stands in for DSM's sshd here. No --base-path:
  // this is the https://nas:7171/ reverse-proxy deployment, where every
  // endpoint sits at the origin root.
  const sshPort = String(Number(PORT) + 2);
  const sshRoot = mkdtempSync(join(tmpdir(), "synoterm-e2e-ssh-"));
  cpSync(join(root, "frontend", "dist"), sshRoot, { recursive: true });
  const fakeSsh = join(sshRoot, "fake-ssh");
  writeFileSync(
    fakeSsh,
    // One argument per line: a long single line would be wrapped by the pty
    // and split mid-token, which makes matching the argv in xterm unreliable.
    '#!/bin/sh\necho "FAKE-SSH"\nfor a in "$@"; do echo "ARG $a"; done\necho "shell up"\nsleep 2\nexit 0\n',
    { mode: 0o755 },
  );
  const sshHome = join(sshRoot, "home");
  mkdirSync(join(sshHome, ".ssh"), { recursive: true });
  const sshBase = `http://127.0.0.1:${sshPort}`;
  const sshServer = spawn(
    binary,
    ["--listen", sshPort, "--auth", "ssh", "--ssh-bin", fakeSsh, "--home", sshHome,
     "--web-root", sshRoot],
    { stdio: ["ignore", "pipe", "pipe"] },
  );
  extraServers.push(sshServer);
  const sshUp = await new Promise((resolve) => {
    const timer = setTimeout(() => resolve(false), 5000);
    sshServer.stderr.on("data", (chunk) => {
      if (String(chunk).includes("listening")) {
        clearTimeout(timer);
        resolve(true);
      }
    });
  });
  if (!sshUp) failures.push("ssh-mode server did not start");

  const health = await (await fetch(`${sshBase}/healthz`)).json().catch(() => ({}));
  if (health.auth !== "ssh") failures.push(`healthz reported auth ${JSON.stringify(health.auth)}`);
  // The binary generates config.js from its own flags, so the bundle never needs
  // a rebuild for a different prefix/port.
  const configJs = await (await fetch(`${sshBase}/config.js`)).text();
  if (!configJs.includes('proxy: ""') || !configJs.includes('auth: "ssh"')) {
    failures.push(`generated config.js is wrong: ${configJs.trim()}`);
  }

  // A name that ssh would read as an option must be refused before a process
  // is spawned.
  const upgradeHeaders = [
    ["Connection", "Upgrade"],
    ["Upgrade", "websocket"],
    ["Sec-WebSocket-Version", "13"],
    ["Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ=="],
    ["Origin", sshBase],
  ];
  const rejected = await rawStatus(sshPort, "/ws?user=-oProxyCommand=x", upgradeHeaders);
  if (rejected !== 400) failures.push(`ssh mode accepted an invalid account (${rejected})`);
  const noUser = await rawStatus(sshPort, "/ws", upgradeHeaders);
  if (noUser !== 400) failures.push(`ssh mode accepted an upgrade without an account (${noUser})`);
  const accepted = await rawStatus(sshPort, "/ws?user=alice", upgradeHeaders);
  if (accepted !== 101) failures.push(`ssh mode refused a valid account (${accepted})`);

  const sshContext = await browser.newContext();
  const sshPage = await sshContext.newPage();
  sshPage.on("pageerror", (error) => failures.push(`pageerror (ssh): ${error}`));
  await sshPage.goto(`${sshBase}/`, { waitUntil: "load" });
  await sshPage.waitForSelector("#login:not([hidden])", { timeout: 5000 });
  await sshPage.fill("#login-user", "alice");
  await sshPage.click("#login-form button[type=submit]");
  await sshPage.waitForFunction(
    () => document.querySelector("#status-text")?.textContent?.startsWith("connected"),
    { timeout: 8000 },
  );
  await sshPage.waitForTimeout(600);
  const sshScreen = await sshPage.evaluate(
    () => document.querySelector(".terminal-pane.active .xterm-rows")?.innerText || "",
  );
  const sshArgv = sshScreen.replace(/\s+/g, " ");
  if (!sshArgv.includes("FAKE-SSH")) failures.push("ssh mode did not run the ssh binary");
  if (!sshArgv.includes("ARG -l ARG alice")) failures.push(`ssh argv lacked the account: ${sshArgv.slice(0, 200)}`);
  if (!/ARG \S*known_hosts/.test(sshArgv)) failures.push("ssh argv has no UserKnownHostsFile");
  if (!sshArgv.includes("ARG IdentityFile=none")) failures.push("ssh argv still probes identity files");
  // At the root the UI must stay on its own origin (the reverse proxy), not
  // fall back to the package's :7381 port — that fallback is in another
  // security context and would be refused by the same-origin check there.
  const sshBackend = await sshPage.evaluate(() => window.synotermBackend);
  if (sshBackend?.origin !== sshBase || sshBackend?.prefix !== "") {
    failures.push(`ssh root UI chose ${JSON.stringify(sshBackend)}`);
  }
  // The account is remembered, so a reload does not ask again.
  await sshPage.reload({ waitUntil: "load" });
  const prompted = await sshPage.evaluate(() => document.getElementById("login")?.hidden === false);
  if (prompted) failures.push("ssh mode asked for the account again after it was remembered");
  // The stub exits 0 after 2s: a deliberate logout must settle on "closed" and
  // not reconnect (a reconnect would ask for the password again).
  await sshPage.waitForFunction(
    () => document.querySelector("#status-text")?.textContent?.startsWith("closed"),
    { timeout: 12000 },
  );
  await sshPage.waitForTimeout(1500);
  const settled = await sshPage.textContent("#status-text");
  if (!settled.startsWith("closed")) failures.push(`exited ssh session did not stay closed: "${settled}"`);
  await sshContext.close();
  rmSync(sshRoot, { recursive: true, force: true });

  // ---- DSM-served page with no mount: it must use the reverse proxy ---------
  // The DSM desktop window is an iframe on :5001/webman/3rdparty/synoterm/web/,
  // and the hand-applied /synoterm mount there is wiped whenever DSM rebuilds
  // /etc/nginx (every package install/upgrade). A page with no ingress of its
  // own must then follow `proxyOrigin`/`proxyPort` from config.js instead of
  // falling back to the package port and failing.
  const dsmPort = Number(PORT) + 3;
  const dsmTargetPort = String(Number(PORT) + 4);
  const dsmRoot = mkdtempSync(join(tmpdir(), "synoterm-e2e-dsm-"));
  cpSync(join(root, "frontend", "dist"), dsmRoot, { recursive: true });
  writeFileSync(
    join(dsmRoot, "config.js"),
    `window.SYNOTERM_CONFIG = { proxy: "/synoterm", port: 0, httpsPort: 0, proxyPort: 0, ` +
      `proxyOrigin: "http://127.0.0.1:${dsmTargetPort}" };\n`,
  );
  // The "reverse proxy": a separate prefixed server, started for this check.
  const dsmTargetRoot = mkdtempSync(join(tmpdir(), "synoterm-e2e-proxy-"));
  cpSync(join(root, "frontend", "dist"), dsmTargetRoot, { recursive: true });
  const dsmTarget = spawn(
    binary,
    ["--listen", dsmTargetPort, "--auth", "dev", "--web-root", dsmTargetRoot, "--base-path", "/synoterm"],
    { stdio: ["ignore", "pipe", "pipe"] },
  );
  extraServers.push(dsmTarget);
  const dsmTargetUp = await new Promise((resolve) => {
    const timer = setTimeout(() => resolve(false), 5000);
    dsmTarget.stderr.on("data", (chunk) => {
      if (String(chunk).includes("listening")) {
        clearTimeout(timer);
        resolve(true);
      }
    });
  });
  if (!dsmTargetUp) failures.push("the simulated reverse-proxy backend did not start");
  const staticServer = createServer((req, res) => {
    const name = (req.url || "/").split("?")[0];
    const file = join(dsmRoot, name === "/" ? "index.html" : name);
    try {
      const body = readFileSync(file);
      res.writeHead(200, { "Content-Type": name.endsWith(".js") ? "text/javascript" : "text/html" });
      res.end(body);
    } catch {
      res.writeHead(404, { "Content-Type": "text/plain" });
      res.end("Not found\n"); // a DSM vhost without the mount
    }
  });
  await new Promise((resolve) => staticServer.listen(dsmPort, "127.0.0.1", resolve));

  const dsmContext = await browser.newContext();
  const dsmPage = await dsmContext.newPage();
  dsmPage.on("pageerror", (error) => failures.push(`pageerror (dsm page): ${error}`));
  await dsmPage.goto(`http://127.0.0.1:${dsmPort}/`, { waitUntil: "load" });
  await dsmPage.waitForFunction(
    () => document.querySelector("#status-text")?.textContent?.startsWith("connected"),
    null,
    { timeout: 8000 },
  );
  const followed = await dsmPage.evaluate(() => window.synotermBackend);
  if (followed?.origin !== `http://127.0.0.1:${dsmTargetPort}` || followed?.mode !== "proxy-rule") {
    failures.push(`page without an ingress did not follow proxyOrigin: ${JSON.stringify(followed)}`);
  }
  await dsmPage.keyboard.type("echo NO_MOUNT_OK\n");
  await dsmPage.waitForTimeout(900);
  const dsmScreen = await dsmPage.evaluate(
    () => document.querySelector(".terminal-pane.active .xterm-rows")?.innerText || "",
  );
  if (!dsmScreen.includes("NO_MOUNT_OK")) failures.push("the proxied backend did not answer on the DSM-like page");
  await dsmContext.close();
  await new Promise((resolve) => staticServer.close(resolve));
  dsmTarget.kill();
  rmSync(dsmRoot, { recursive: true, force: true });
  rmSync(dsmTargetRoot, { recursive: true, force: true });
} catch (error) {
  failures.push(String(error));
} finally {
  await browser.close();
  server.kill("SIGTERM");
  for (const extra of extraServers) extra.kill("SIGTERM");
}

if (failures.length > 0) {
  console.error("e2e: FAILED");
  for (const failure of failures) console.error(` - ${failure}`);
  process.exit(1);
}
console.log("e2e: ok");
