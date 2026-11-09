import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebLinksAddon } from "@xterm/addon-web-links";
// xterm.js ships layout styles that are *required*: without them its helper
// elements (font-width measurement container, textarea, accessibility layer)
// stay visible and paint stray rows of characters over the screen.
import xtermCss from "@xterm/xterm/css/xterm.css";
import cssText from "./style.css";
import {
  DEFAULTS as FONT_DEFAULTS,
  FONT_CHOICES,
  LIMITS as FONT_LIMITS,
  cssFontFamily,
  loadSettings,
  resetSettings,
  sanitizeFontFamily,
  sanitizeFontSize,
  sanitizeLineHeight,
  saveSettings,
} from "./settings.js";

/**
 * synoterm frontend: one xterm.js terminal per tab, each backed by its own
 * WebSocket + PTY on the NAS.
 *
 * Wire protocol (see docs/protocol.md):
 *   browser -> server : binary frame = raw keystrokes, text frame = JSON control
 *   server -> browser : binary frame = raw terminal output, text frame = JSON control
 */

const THEME = {
  // Tuned for a dark terminal: every colour keeps at least ~5:1 contrast on the
  // background, because many tools (ls --color, git, vim themes) print "bold
  // blue" or 256-colour codes that are unreadable on a near-black surface.
  background: "#0f1720",
  foreground: "#d7e0ea",
  cursor: "#7ee0ff",
  cursorAccent: "#0f1720",
  selectionBackground: "rgba(126, 224, 255, 0.28)",
  black: "#22303f",
  red: "#ff7a85",
  green: "#8ce99a",
  yellow: "#ffd479",
  blue: "#82b7ff",
  magenta: "#d8a8ff",
  cyan: "#79e0d3",
  white: "#cbd6e2",
  brightBlack: "#7b8b9e",
  brightRed: "#ffa2aa",
  brightGreen: "#b2f2bb",
  brightYellow: "#ffe3a3",
  brightBlue: "#aecfff",
  brightMagenta: "#e9c9ff",
  brightCyan: "#a9f2e6",
  brightWhite: "#f4f8fc",
};

/** Current font settings; changed from the settings panel or ?font…= params. */
let fontSettings = loadSettings();

function termOptions() {
  return {
    fontFamily: cssFontFamily(fontSettings.fontFamily),
    fontSize: fontSettings.fontSize,
    lineHeight: fontSettings.lineHeight,
    cursorBlink: true,
    // Lets xterm.js raise the contrast of any colour a program emits (including
    // the 256-colour cube) instead of drawing low-contrast text.
    minimumContrastRatio: 4.5,
    allowTransparency: false,
    scrollback: 10000,
    allowProposedApi: true,
    theme: THEME,
  };
}

/** Applies the current font settings to a live terminal and re-fits it. */
function applyFont(term, fit) {
  const options = termOptions();
  term.options.fontFamily = options.fontFamily;
  term.options.fontSize = options.fontSize;
  term.options.lineHeight = options.lineHeight;
  // Re-measure after the renderer picked up the new metrics: fit() computes the
  // column count from the character cell, and a resize is what the PTY needs.
  fit();
  requestAnimationFrame(() => fit());
}

/**
 * Where the terminal backend lives.
 *
 * With the DSM package the UI is served by DSM (same origin, so the DSM session
 * cookie is available and the SynoToken can be read from the desktop), while the
 * backend listens on its own port. Cookies are host-scoped rather than
 * port-scoped, so the browser adds the DSM session cookie to the cross-port
 * request — no reverse proxy and no extra login are needed.
 *
 * Every endpoint lives under one prefix (`/synoterm`) in both transports:
 *   proxy   → https://nas:5001/synoterm/{healthz,status,ws}   (nginx mount)
 *   direct  → http://nas:7381/synoterm/{healthz,status,ws}    (own port)
 * so switching transports never changes the paths, only the origin.
 */
let backend = null; // { origin, prefix, mode }

function apiConfig() {
  return window.SYNOTERM_CONFIG || {};
}

/** Prefix every endpoint lives under: "/synoterm" in DSM, "" in dev. */
function apiPrefix() {
  const proxy = apiConfig().proxy;
  return typeof proxy === "string" ? proxy.replace(/\/+$/, "") : "";
}

function backendOrigin() {
  return backend ? backend.origin : window.location.origin;
}

/** Origin + prefix, e.g. "https://nas:5001/synoterm". */
function backendBase() {
  return backendOrigin() + apiPrefix();
}

function chooseBackend(origin, mode) {
  backend = { origin, prefix: apiPrefix(), mode };
  window.synotermBackend = backend; // handy in the browser console / support
  console.info(`synoterm: backend ${mode} — ${backendBase()}`);
  return backend;
}

async function healthzAnswers(origin, credentials) {
  try {
    const response = await fetch(`${origin}${apiPrefix()}/healthz`, {
      credentials,
      cache: "no-store",
    });
    return response.ok;
  } catch {
    return false;
  }
}

/**
 * Picks the backend origin once, then caches it.
 *
 * The package can be reached two ways:
 *   1. same-origin through DSM's nginx mount (/synoterm/), applied by hand with
 *      contrib/install-nginx-mount.sh  — preferred: cookies, HTTPS, no extra port
 *   2. directly on the package's own port (http://nas:7381/) — works without any
 *      DSM configuration, but the page must come from DSM (or the same host)
 *
 * A cheap probe of <origin>/synoterm/healthz decides which is available; the
 * result is only a transport choice, authentication is unchanged either way.
 */
async function resolveBackend() {
  if (backend) {
    window.synotermBackend = backend;
    return backend;
  }
  const config = apiConfig();
  const prefix = apiPrefix();

  // Already talking to our own server? Then stay on this origin.
  if (Number.isFinite(config.port) && String(config.port) === window.location.port) {
    return chooseBackend(window.location.origin, "direct");
  }

  // 1. the mount on the origin that served this page (the normal case).
  if (prefix && (await healthzAnswers(window.location.origin, "same-origin"))) {
    return chooseBackend(window.location.origin, "proxy");
  }

  // 2. the same mount on DSM's HTTPS vhost. DSM is often opened on :5000 while
  //    the mount only exists on the HTTPS server block; the paths are identical,
  //    so the terminal can still use it — but cookies may not travel from an
  //    http page, hence the hint below.
  const httpsPort = Number.isFinite(config.httpsPort) ? config.httpsPort : 5001;
  if (prefix && window.location.protocol === "http:" && String(httpsPort) !== window.location.port) {
    const origin = `https://${window.location.hostname}:${httpsPort}`;
    if (await healthzAnswers(origin, "include")) {
      console.warn(
        `synoterm: DSM is open over HTTP but the mount lives on ${origin} — ` +
          `reopen DSM at ${origin}/ for session cookies to be sent`,
      );
      return chooseBackend(origin, "proxy-https");
    }
  }

  // 3. no mount anywhere: talk to the package's own port.
  if (Number.isFinite(config.port) && config.port > 0) {
    return chooseBackend(`${window.location.protocol}//${window.location.hostname}:${config.port}`, "direct");
  }
  return chooseBackend(window.location.origin, "same-origin");
}

function wsUrl() {
  const config = apiConfig();
  // An explicit path (`?ws=/synoterm/ws`, injected by a DSM wrapper) already
  // contains the prefix; only its origin is ours to choose.
  const explicit =
    typeof config.ws === "string" && config.ws.length > 0
      ? config.ws
      : new URLSearchParams(window.location.search).get("ws");
  if (explicit) {
    if (explicit.startsWith("ws://") || explicit.startsWith("wss://")) return explicit;
    return backendOrigin().replace(/^http/, "ws") + explicit;
  }
  return backendBase().replace(/^http/, "ws") + "/ws";
}

/** HTTP API path for control endpoints (healthz, status), e.g. /synoterm/status. */
function apiPath(name) {
  return `${backendBase()}/${name}`;
}

/**
 * DSM's CSRF token, if we can find it.
 *
 * Sources, in order of trustworthiness:
 *   1. `?SynoToken=` on this page (the DSM 7.2 wrapper forwards it)
 *   2. the same-origin DSM desktop window (frame or popup): globals, the DOM
 *      bootstrap, or its cookies
 *   3. a same-origin fetch of /webman/index.cgi (the desktop HTML contains it)
 *   4. a `SynoToken` cookie, if this DSM build sets one
 *
 * The `.url` registration gives us no injected token, but the terminal page is
 * same-origin with the DSM desktop, so on DSM 7.1 the token is usually reachable
 * through 2 or 3.
 */
let tokenCache = { value: "", source: "none" };

function rememberToken(value, source, force = false) {
  if (value && (force || !tokenCache.value)) {
    tokenCache = { value, source };
    console.info(`synoterm: DSM token from ${source} (${value.length} chars)`);
  }
  return tokenCache.value;
}

function clearTokenCache() {
  tokenCache = { value: "", source: "none" };
  console.info("synoterm: cleared cached DSM token");
}

/** Where we looked, so a support report can explain a failure. */
let tokenSources = [];

function noteSource(name, value) {
  tokenSources.push({ source: name, found: !!value, length: value ? value.length : 0 });
  return value || "";
}

function tokenFromText(text) {
  // DSM has used several spellings, quoted and unquoted, and in URLs the token
  // can arrive percent-encoded.
  const patterns = [
    /SynoToken["']?\s*[:=]\s*["']([^"'&<>\\]+)["']/,
    /SynoToken["']?\s*[:=]\s*([^"'&<>;,\s\\]+)/,
    /[?&](?:SynoToken|synotoken)=([^&"'<>\\]+)/,
    /SynoToken%3D([^&"'<>\\]+)/i,
  ];
  for (const pattern of patterns) {
    const match = text.match(pattern);
    if (match) return decodeURIComponent(match[1]);
  }
  return "";
}

function tokenFromCookies(cookieText) {
  for (const part of (cookieText || "").split(";")) {
    const eq = part.indexOf("=");
    if (eq < 0) continue;
    const name = part.slice(0, eq).trim();
    if (/synotoken/i.test(name)) return decodeURIComponent(part.slice(eq + 1).trim());
  }
  return "";
}

function tokenFromWindow(win) {
  if (!win || win === window) return "";
  try {
    // After login DSM redirects the desktop to …/index.cgi?SynoToken=…, so the
    // parent frame's own URL is often the easiest source.
    const fromUrl = tokenFromText(`${win.location.search || ""}${win.location.hash || ""}`);
    if (fromUrl) return fromUrl;

    // Globals DSM keeps in the desktop page (names have varied across releases).
    const globals = [win.SynoToken, win._SynoToken, win.synotoken, win.__SynoToken, win.SYNO_TOKEN];
    if (win.SYNO && win.SYNO.SDS && win.SYNO.SDS.Session) {
      const session = win.SYNO.SDS.Session;
      globals.push(
        typeof session.getSynoToken === "function" ? session.getSynoToken() : undefined,
        session.synoToken,
        session._synoToken,
        session.SynoToken,
      );
    }
    try {
      if (win.Ext && win.Ext.util && win.Ext.util.Cookies) {
        globals.push(win.Ext.util.Cookies.get("SynoToken"), win.Ext.util.Cookies.get("_SynoToken"));
      }
    } catch {
      /* Ext not reachable */
    }
    for (const candidate of globals) {
      if (typeof candidate === "string" && candidate.length > 0) return candidate;
    }

    const fromCookie = tokenFromCookies(win.document.cookie);
    if (fromCookie) return fromCookie;

    const html = win.document.documentElement ? win.document.documentElement.outerHTML : "";
    return tokenFromText(html.slice(0, 4 * 1024 * 1024));
  } catch {
    return "";
  }
}

async function discoverSynoToken(force = false) {
  if (force) clearTokenCache();
  if (tokenCache.value) return tokenCache.value;
  tokenSources = [];
  window.synotermTokenSources = tokenSources;

  const fromOwnUrl = noteSource("page URL", tokenFromText(`${window.location.search}${window.location.hash}`));
  if (fromOwnUrl) return rememberToken(fromOwnUrl, "page URL");

  for (const [name, win] of [
    ["parent frame", window.parent],
    ["opener window", window.opener],
    ["top window", window.top],
  ]) {
    const value = noteSource(name, tokenFromWindow(win));
    if (value) return rememberToken(value, name);
  }

  // Only ask DSM's desktop page when we are inside DSM: on a dev server the
  // path does not exist and the 404 would show in the console.
  const insideDsm = window.parent !== window || window.location.pathname.startsWith("/webman/");
  if (insideDsm) {
    for (const path of ["/webman/index.cgi", "/webman/desktop/index.html"]) {
      try {
        const response = await fetch(path, { credentials: "same-origin" });
        if (!response.ok) {
          noteSource(path, "");
          continue;
        }
        const value = noteSource(path, tokenFromText(await response.text()));
        if (value) return rememberToken(value, path);
      } catch {
        noteSource(path, "");
      }
    }

    // Last resort: the CGI probe shipped in this package. It runs inside webman
    // with the real request environment, so it can report what DSM itself sees.
    try {
      const response = await fetch("auth-probe.cgi", { credentials: "same-origin" });
      if (response.ok) {
        const info = await response.json();
        window.synotermAuthProbe = info;
        const value = noteSource("auth-probe.cgi", typeof info.token === "string" ? info.token : "");
        if (value) return rememberToken(value, "auth-probe.cgi");
      } else {
        noteSource("auth-probe.cgi", "");
      }
    } catch {
      noteSource("auth-probe.cgi", "");
    }
  }

  const fromCookie = noteSource("cookie", tokenFromCookies(document.cookie));
  if (fromCookie) return rememberToken(fromCookie, "cookie");

  return "";
}

function synoToken() {
  return tokenCache.value;
}

function base64url(token) {
  const bytes = new TextEncoder().encode(token);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

function synoTokenSubprotocol(token) {
  return `synoterm.syno-token.${base64url(token)}`;
}

/** Dev servers may require a shared secret (?t=… on the page URL). */
function devToken() {
  return new URLSearchParams(window.location.search).get("t") || "";
}

class Session {
  /**
   * `pane` must already be in the document *and visible*: xterm measures the
   * character cell from the container, and opening it in a `display:none` pane
   * makes it cache a bogus width (rows then render as a run of one glyph).
   */
  constructor(manager, pane, name) {
    this.manager = manager;
    this.name = name;
    this.state = "connecting";
    this.attempts = 0;
    this.closedByUser = false;

    this.pane = pane;

    this.term = new Terminal(termOptions());
    this.fit = new FitAddon();
    this.term.loadAddon(this.fit);
    this.term.loadAddon(new WebLinksAddon());
    this.term.open(pane);
    this.term.onData((data) => this.sendInput(data));
    this.term.onResize(({ cols, rows }) => this.sendControl({ type: "resize", cols, rows }));

    this.resizeObserver = new ResizeObserver(() => this.refit());
    this.attachClipboard();
  }

  /**
   * Clipboard support.
   *
   * xterm.js relies on the browser's own paste event, which needs its hidden
   * textarea to have focus — inside a DSM window (iframe) that is often not the
   * case, so Ctrl+V did nothing. The terminal shortcuts are handled explicitly:
   *
   *   Ctrl/Cmd+Shift+V, Shift+Insert  → paste from the clipboard
   *   Ctrl/Cmd+C with a selection     → copy it (without a selection it stays ^C)
   *   Ctrl/Cmd+V                      → native paste when the terminal is focused
   *
   * `navigator.clipboard` needs a user gesture (a key press qualifies) and, in
   * an iframe, the clipboard permissions policy — the ExtJS wrapper grants it.
   */
  attachClipboard() {
    this.term.attachCustomKeyEventHandler((event) => {
      if (event.type !== "keydown") return true;
      const mod = event.ctrlKey || event.metaKey;
      const key = (event.key || "").toLowerCase();

      // Plain Ctrl/Cmd+V: xterm.js would translate it to ^V and preventDefault,
      // which is why the browser never pasted anything. Hand the event back to
      // the browser: it pastes into xterm's hidden textarea, so no clipboard
      // permission is involved.
      if (mod && !event.shiftKey && !event.altKey && key === "v") {
        return false;
      }

      // Explicit paste shortcuts for when the native path is unavailable
      // (clipboard API needs a user gesture and, in an iframe, the policy).
      const wantsPaste = (mod && event.shiftKey && key === "v") || (event.shiftKey && event.key === "Insert");
      if (wantsPaste) {
        event.preventDefault();
        this.readClipboardAndPaste();
        return false;
      }

      if (mod && !event.shiftKey && key === "c" && this.term.hasSelection()) {
        event.preventDefault();
        if (navigator.clipboard && navigator.clipboard.writeText) {
          navigator.clipboard.writeText(this.term.getSelection()).catch(() => {});
        }
        this.term.clearSelection();
        return false;
      }
      return true;
    });
  }

  readClipboardAndPaste() {
    if (!navigator.clipboard || !navigator.clipboard.readText) return;
    navigator.clipboard.readText().then(
      (text) => {
        if (text) this.pasteText(text);
      },
      () => {
        /* permission denied: the browser's own paste event still applies */
      },
    );
  }

  pasteText(text) {
    if (!text) return;
    this.term.paste(text);
    this.term.focus();
  }

  get element() {
    return this.pane;
  }

  async connect() {
    if (this.connecting) return;
    this.connecting = true;
    try {
      await this.openSocket();
    } finally {
      this.connecting = false;
    }
  }

  async openSocket() {
    await resolveBackend();
    const url = wsUrl();
    const protocols = [];
    const dev = devToken();
    if (dev) protocols.push(`synoterm.dev-token.${base64url(dev)}`);
    const token = await discoverSynoToken();
    if (token) protocols.push(synoTokenSubprotocol(token));

    this.setState("connecting");
    let socket;
    try {
      socket = new WebSocket(url, protocols.length > 0 ? protocols : undefined);
    } catch (err) {
      this.fail(err);
      return;
    }
    socket.binaryType = "arraybuffer";
    this.socket = socket;

    socket.addEventListener("open", () => {
      this.attempts = 0;
      this.term.focus();
      this.sendControl({ type: "resize", cols: this.term.cols, rows: this.term.rows });
    });

    socket.addEventListener("message", (event) => {
      if (typeof event.data === "string") {
        this.handleControl(event.data);
        return;
      }
      this.term.write(new Uint8Array(event.data));
    });

    socket.addEventListener("close", () => {
      if (this.socket !== socket) return;
      this.socket = undefined;
      if (this.closedByUser) return;
      this.setState("error");
      // Only explain the first failure of a streak; the status line carries
      // the rest so the terminal stays readable.
      if (this.attempts === 0) this.explainFailure();
      this.scheduleReconnect();
      this.manager.updateStatus();
    });

    socket.addEventListener("error", () => {
      if (this.socket === socket) this.setState("error");
    });
  }

  handleControl(raw) {
    let message;
    try {
      message = JSON.parse(raw);
    } catch {
      return;
    }
    if (message.type === "ready") {
      this.attempts = 0;
      this.manager.setNotice("", false);
      this.setState("open");
      if (message.user) this.name = `${message.user}@nas`;
      this.manager.renderTabs();
    } else if (message.type === "error") {
      this.setState("error");
      this.term.write(`\r\n\x1b[31m${message.code || "error"}\x1b[0m\r\n`);
    } else if (message.type === "exit") {
      this.setState("closed");
    }
  }

  scheduleReconnect() {
    if (this.closedByUser) return;
    const delay = Math.min(8000, 500 * 2 ** this.attempts++);
    this.reconnectTimer = setTimeout(() => this.connect(), delay);
  }

  /**
   * A refused WebSocket handshake gives JavaScript no status code, so ask the
   * server why (same checks, plain HTTP). Turns "disconnected, retrying…"
   * loops into an actionable message.
   */
  async explainFailure() {
    const target = apiPath("status");
    try {
      const response = await fetch(target, { credentials: "same-origin" });
      const text = await response.text();
      let info;
      try {
        info = JSON.parse(text);
      } catch {
        info = undefined;
      }
      if (response.status === 404) {
        // No /status at all: an old server binary, or the mount path is wrong.
        const reason =
          `server has no ${target} (old build, or the mount path is wrong) — ` +
          `restart it with the current binary`;
        this.manager.setNotice(reason, true);
        this.term.write(`\r\n\x1b[31m${reason}\x1b[0m\r\n`);
        return;
      }
      if (!response.ok) {
        const reason = info?.reason || `HTTP ${response.status}`;
        // A stale/missing CSRF token is the common cause of a 401 here; drop
        // the cached token so the next reconnect re-discovers it instead of
        // retrying with the same dead value.
        if (response.status === 401 || /synotoken|token/i.test(reason)) {
          clearTokenCache();
        }
        const tokenNote = tokenCache.value
          ? ` (DSM token from ${tokenCache.source})`
          : " (no DSM token found — open the terminal from the DSM desktop)";
        this.manager.setNotice(`${reason}${tokenNote}`, true);
        this.term.write(`\r\n\x1b[31m${reason}\x1b[0m\r\n\x1b[2m${tokenNote.trim()}\x1b[0m\r\n`);
        return;
      }
      const user = info?.user ? ` as ${info.user}` : "";
      this.term.write(
        `\r\n\x1b[33mdisconnected${user}; the server is reachable — retrying…\x1b[0m\r\n`,
      );
      this.manager.setNotice(`disconnected — retrying (${this.attempts})`, true);
    } catch {
      this.term.write("\r\n\x1b[33mdisconnected; server not reachable — retrying…\x1b[0m\r\n");
      this.manager.setNotice("server not reachable — retrying", true);
    }
  }

  fail(err) {
    this.setState("error");
    this.term.write(`\r\n\x1b[31m${String(err)}\x1b[0m\r\n`);
  }

  sendInput(data) {
    if (this.socket?.readyState !== WebSocket.OPEN) return;
    this.socket.send(new TextEncoder().encode(data));
  }

  sendControl(message) {
    if (this.socket?.readyState !== WebSocket.OPEN) return;
    this.socket.send(JSON.stringify(message));
  }

  setState(state) {
    this.state = state;
    this.manager.updateTabState(this);
    this.manager.updateStatus();
  }

  applyFontSettings() {
    applyFont(this.term, () => this.refit());
  }

  refit() {
    if (!this.pane.classList.contains("active")) return;
    if (this.pane.clientWidth === 0 || this.pane.clientHeight === 0) return;
    try {
      this.fit.fit();
      // Repaint everything: after a resize the DOM renderer can keep stale
      // glyph runs otherwise.
      this.term.refresh(0, this.term.rows - 1);
    } catch {
      /* the pane may not be laid out yet */
    }
  }

  activate() {
    this.pane.classList.add("active");
    this.resizeObserver.observe(this.pane);
    // Wait for layout so fit() sees the real size.
    requestAnimationFrame(() => {
      this.refit();
      this.term.focus();
    });
  }

  deactivate() {
    this.pane.classList.remove("active");
    this.resizeObserver.disconnect();
  }

  close() {
    this.closedByUser = true;
    clearTimeout(this.reconnectTimer);
    this.sendControl({ type: "close" });
    this.socket?.close(1000, "tab closed");
    this.resizeObserver.disconnect();
    this.term.dispose();
  }
}

class TabManager {
  constructor(host) {
    this.host = host;
    this.tabs = [];
    this.active = undefined;
    this.counter = 0;

    document.getElementById("new-tab").addEventListener("click", () => this.newTab());

    // If the paste event does not land in xterm's textarea (focus in the DSM
    // window chrome, the settings panel, …) forward it to the active terminal.
    document.addEventListener("paste", (event) => {
      const session = this.active;
      if (!session || this.panel && !this.panel.hidden) return;
      const target = event.target;
      if (target && session.element.contains(target)) return; // xterm handles it
      const text = event.clipboardData ? event.clipboardData.getData("text") : "";
      if (!text) return;
      event.preventDefault();
      session.pasteText(text);
    });

    // Clicking anywhere in the terminal surface must give the shell the keyboard.
    document.getElementById("terminal-host").addEventListener("mousedown", () => {
      requestAnimationFrame(() => this.active?.term.focus());
    });
    window.addEventListener("focus", () => this.active?.term.focus());
    this.initSettingsPanel();
    window.addEventListener("keydown", (event) => this.onKeydown(event));
    window.addEventListener("beforeunload", () => {
      for (const tab of this.tabs) tab.close();
    });
  }

  onKeydown(event) {
    if (event.key === "Escape" && !this.panel.hidden) {
      this.toggleSettings(false);
      return;
    }
    if (!(event.ctrlKey || event.metaKey) || !event.shiftKey) return;
    if (event.key.toLowerCase() === "t") {
      event.preventDefault();
      this.newTab();
    } else if (event.key.toLowerCase() === "w") {
      event.preventDefault();
      if (this.active) this.closeTab(this.active);
    }
  }

  newTab() {
    this.counter += 1;
    const pane = document.createElement("div");
    pane.className = "terminal-pane active";
    this.host.appendChild(pane);

    // Only one pane may be active, and the new one must have layout before
    // xterm.js measures the font.
    if (this.active) this.active.deactivate();
    else for (const other of this.tabs) other.deactivate();

    const session = new Session(this, pane, `terminal ${this.counter}`);
    this.tabs.push(session);
    this.active = session;
    this.renderTabs();
    this.updateStatus();
    session.activate();
    session.connect();
    return session;
  }

  closeTab(session) {
    const index = this.tabs.indexOf(session);
    if (index === -1) return;
    session.close();
    session.element.remove();
    this.tabs.splice(index, 1);
    if (this.active === session) {
      this.active = undefined;
      const next = this.tabs[Math.max(0, index - 1)];
      if (next) this.select(next);
    }
    this.renderTabs();
    this.updateStatus();
    if (this.tabs.length === 0) this.newTab();
  }

  select(session) {
    if (this.active === session) {
      session.activate();
      return;
    }
    this.active?.deactivate();
    this.active = session;
    session.activate();
    this.renderTabs();
    this.updateStatus();
  }

  initSettingsPanel() {
    this.panel = document.getElementById("settings-panel");
    this.settingsButton = document.getElementById("settings");
    this.familyInput = document.getElementById("set-font-family");
    this.sizeInput = document.getElementById("set-font-size");
    this.heightInput = document.getElementById("set-line-height");

    const list = document.getElementById("font-choices");
    for (const family of FONT_CHOICES) {
      const option = document.createElement("option");
      option.value = family;
      list.appendChild(option);
    }

    this.settingsButton.addEventListener("click", (event) => {
      event.stopPropagation();
      this.toggleSettings();
    });
    document.getElementById("settings-close").addEventListener("click", () => this.toggleSettings(false));
    document.getElementById("settings-reset").addEventListener("click", () => {
      fontSettings = resetSettings();
      this.syncSettingsInputs();
      this.applyFontSettingsAll();
    });

    // Live preview while typing; persist once the field is left.
    const liveUpdate = () => {
      fontSettings = {
        fontFamily: sanitizeFontFamily(this.familyInput.value),
        fontSize: sanitizeFontSize(this.sizeInput.value),
        lineHeight: sanitizeLineHeight(this.heightInput.value),
      };
      this.applyFontSettingsAll();
    };
    const persist = () => {
      liveUpdate();
      fontSettings = saveSettings(fontSettings);
      this.syncSettingsInputs();
    };
    for (const input of [this.familyInput, this.sizeInput, this.heightInput]) {
      input.addEventListener("input", liveUpdate);
      input.addEventListener("change", persist);
      input.addEventListener("keydown", (event) => {
        if (event.key === "Enter") persist();
        if (event.key === "Escape") this.toggleSettings(false);
        event.stopPropagation();
      });
    }

    // Click outside or Escape closes the panel.
    document.addEventListener("click", (event) => {
      if (this.panel.hidden) return;
      if (this.panel.contains(event.target) || this.settingsButton.contains(event.target)) return;
      this.toggleSettings(false);
    });

    this.syncSettingsInputs();
  }

  syncSettingsInputs() {
    this.familyInput.value = fontSettings.fontFamily;
    this.sizeInput.min = String(FONT_LIMITS.fontSize.min);
    this.sizeInput.max = String(FONT_LIMITS.fontSize.max);
    this.sizeInput.value = String(fontSettings.fontSize);
    this.heightInput.min = String(FONT_LIMITS.lineHeight.min);
    this.heightInput.max = String(FONT_LIMITS.lineHeight.max);
    this.heightInput.value = String(fontSettings.lineHeight);
  }

  toggleSettings(force) {
    const show = force === undefined ? this.panel.hidden : force;
    this.panel.hidden = !show;
    this.settingsButton.setAttribute("aria-expanded", String(show));
    if (show) {
      this.syncSettingsInputs();
      this.familyInput.focus();
      this.familyInput.select();
    } else {
      this.active?.term.focus();
    }
  }

  renderTabs() {
    const container = document.getElementById("tabs");
    container.replaceChildren();
    for (const session of this.tabs) {
      const tab = document.createElement("button");
      tab.type = "button";
      tab.className = "tab";
      tab.setAttribute("role", "tab");
      tab.setAttribute("aria-selected", String(session === this.active));
      tab.dataset.state = session.state;

      const dot = document.createElement("span");
      dot.className = "dot";
      const label = document.createElement("span");
      label.className = "label";
      label.textContent = session.name;
      const close = document.createElement("span");
      close.className = "close";
      close.textContent = "×";
      close.title = "Close terminal (Ctrl+Shift+W)";
      close.addEventListener("click", (event) => {
        event.stopPropagation();
        this.closeTab(session);
      });

      tab.append(dot, label, close);
      tab.addEventListener("click", () => this.select(session));
      container.appendChild(tab);
    }
  }

  applyFontSettingsAll() {
    for (const session of this.tabs) session.applyFontSettings();
    this.updateStatus();
  }

  updateTabState(session) {
    const index = this.tabs.indexOf(session);
    if (index === -1) return;
    const tab = document.getElementById("tabs").children[index];
    if (tab) tab.dataset.state = session.state;
  }

  setNotice(message, isError) {
    this.notice = message;
    this.noticeIsError = !!isError;
    this.updateStatus();
  }

  updateStatus() {
    const el = document.getElementById("status");
    const text = document.getElementById("status-text");
    const session = this.active;
    if (!session) {
      text.textContent = "";
      return;
    }
    if (this.notice && (session.state !== "open" || this.noticeIsError)) {
      text.textContent = this.notice;
      el.classList.toggle("error", !!this.noticeIsError);
      return;
    }
    this.notice = undefined;
    const labels = {
      connecting: "connecting…",
      open: "connected",
      error: "disconnected — retrying",
      closed: "closed",
    };
    text.textContent = `${labels[session.state] || session.state} · ${session.term.cols}×${session.term.rows}`;
    el.classList.toggle("error", session.state === "error");
  }
}

async function boot() {
  const style = document.createElement("style");
  // Base stylesheet first, our theme last so it can override.
  style.textContent = `${xtermCss}\n${cssText}`;
  document.head.appendChild(style);

  const manager = new TabManager(document.getElementById("terminal-host"));
  window.synoterm = manager;

  // xterm measures its cell size from the rendered font; do it once fonts are
  // settled, otherwise rows can render with the wrong advance width.
  if (document.fonts && document.fonts.ready) {
    try {
      await document.fonts.ready;
    } catch {
      /* ignore */
    }
  }
  manager.newTab();
  if (document.fonts) {
    document.fonts.addEventListener("loadingdone", () => manager.active?.refit());
  }

  let resizeTimer;
  window.addEventListener("resize", () => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => manager.active?.refit(), 80);
  });
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", boot);
} else {
  boot();
}
