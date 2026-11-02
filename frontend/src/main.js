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
  background: "#10161d",
  foreground: "#c8d3e0",
  cursor: "#61dafb",
  cursorAccent: "#10161d",
  selectionBackground: "rgba(97, 218, 251, 0.28)",
  black: "#1a2430",
  red: "#ff6b6b",
  green: "#57d38c",
  yellow: "#f0c674",
  blue: "#61dafb",
  magenta: "#c792ea",
  cyan: "#7fdbca",
  white: "#c8d3e0",
  brightBlack: "#7d8a99",
  brightRed: "#ff8a8a",
  brightGreen: "#7ee2a8",
  brightYellow: "#ffd98a",
  brightBlue: "#8be9fd",
  brightMagenta: "#dba6ff",
  brightCyan: "#a2f5e8",
  brightWhite: "#ffffff",
};

/** Current font settings; changed from the settings panel or ?font…= params. */
let fontSettings = loadSettings();

function termOptions() {
  return {
    fontFamily: cssFontFamily(fontSettings.fontFamily),
    fontSize: fontSettings.fontSize,
    lineHeight: fontSettings.lineHeight,
    cursorBlink: true,
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

/** Base path of the app ("/synoterm" in DSM, "" in dev). */
function appBase() {
  const path = window.location.pathname.replace(/\/index\.html$/, "");
  return path.replace(/\/$/, "");
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
 * Resolution order:
 *   1. window.SYNOTERM_CONFIG.port  → http(s)://<same host>:<port>
 *   2. window.SYNOTERM_CONFIG.ws    → explicit websocket URL/path
 *   3. ?ws=…                        (injected by the DSM 7.2 Vue wrapper)
 *   4. derived from the page URL    (dev server, same origin)
 */
let backend = null; // { base, mode }

/**
 * Picks the backend endpoint once, then caches it.
 *
 * The package can be reached two ways:
 *   1. same-origin through DSM's nginx mount (/synoterm/), applied by hand with
 *      contrib/install-nginx-mount.sh  — preferred: cookies, HTTPS, no extra port
 *   2. directly on the package's own port (http://nas:7381/) — works without any
 *      DSM configuration, but the page must come from DSM (or the same host)
 *
 * A cheap same-origin probe of <proxy>/healthz decides which is available; the
 * result is only a transport choice, authentication is unchanged either way.
 */
async function resolveBackend() {
  if (backend) {
    window.synotermBackend = backend; // handy in the browser console / support
    return backend;
  }
  const config = window.SYNOTERM_CONFIG || {};
  const proxy = typeof config.proxy === "string" ? config.proxy.replace(/\/$/, "") : "";

  // Already talking to our own server? Then stay same-origin.
  if (Number.isFinite(config.port) && String(config.port) === window.location.port) {
    backend = { base: window.location.origin + appBase(), mode: "direct" };
    window.synotermBackend = backend;
    return backend;
  }

  if (proxy) {
    try {
      const response = await fetch(`${proxy}/healthz`, { credentials: "same-origin", cache: "no-store" });
      if (response.ok) {
        backend = { base: proxy, mode: "proxy" };
        window.synotermBackend = backend;
        return backend;
      }
    } catch {
      /* no mount: fall through to the package's own port */
    }
  }

  if (typeof config.base === "string" && config.base.length > 0) {
    backend = { base: config.base, mode: "config" };
    window.synotermBackend = backend;
    return backend;
  }
  if (Number.isFinite(config.port) && config.port > 0) {
    backend = {
      base: `${window.location.protocol}//${window.location.hostname}:${config.port}`,
      mode: "direct",
    };
    window.synotermBackend = backend;
    return backend;
  }
  backend = { base: window.location.origin + appBase(), mode: "same-origin" };
  window.synotermBackend = backend;
  return backend;
}

function backendBase() {
  return backend ? backend.base : window.location.origin + appBase();
}

function wsUrl() {
  const config = window.SYNOTERM_CONFIG || {};
  if (typeof config.ws === "string" && config.ws.length > 0) {
    return config.ws.startsWith("ws://") || config.ws.startsWith("wss://")
      ? config.ws
      : `${backendBase()}${config.ws}`;
  }
  const injected = new URLSearchParams(window.location.search).get("ws");
  if (injected) return `${window.location.origin}${injected}`;
  const base = backendBase();
  return base.replace(/^http/, "ws") + "/ws";
}

/**
 * HTTP API base for control endpoints (/status, /healthz).
 *
 * Derived from the *WebSocket* path, not from the page URL: with the DSM
 * package the page is served from /webman/3rdparty/<pkg>/web/ while the API
 * lives behind the nginx mount /synoterm/, so using the page path made /status
 * 404 exactly where it was most needed.
 */
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

function rememberToken(value, source) {
  if (value && !tokenCache.value) {
    tokenCache = { value, source };
    console.info(`synoterm: DSM token from ${source} (${value.length} chars)`);
  }
  return tokenCache.value;
}

function tokenFromText(text) {
  const match = text.match(/SynoToken["']?\s*[:=]\s*["']([^"'&<>]+)["']/);
  return match ? match[1] : "";
}

function tokenFromWindow(win) {
  if (!win || win === window) return "";
  try {
    const candidates = [win.SynoToken, win._SynoToken];
    if (win.SYNO && win.SYNO.SDS && win.SYNO.SDS.Session) {
      const session = win.SYNO.SDS.Session;
      candidates.push(typeof session.getSynoToken === "function" ? session.getSynoToken() : undefined);
    }
    for (const candidate of candidates) {
      if (typeof candidate === "string" && candidate.length > 0) return candidate;
    }
    const cookie = win.document.cookie || "";
    const match = cookie.match(/(?:^|;\s*)(?:SynoToken|_SynoToken)=([^;]+)/);
    if (match) return decodeURIComponent(match[1]);
    const html = win.document.documentElement ? win.document.documentElement.outerHTML : "";
    return tokenFromText(html.slice(0, 4 * 1024 * 1024));
  } catch {
    return "";
  }
}

async function discoverSynoToken() {
  if (tokenCache.value) return tokenCache.value;

  const fromUrl = new URLSearchParams(window.location.search).get("SynoToken");
  if (fromUrl) return rememberToken(fromUrl, "page URL");

  for (const [name, win] of [
    ["parent frame", window.parent],
    ["opener window", window.opener],
    ["top window", window.top],
  ]) {
    const value = tokenFromWindow(win);
    if (value) return rememberToken(value, name);
  }

  // Only ask DSM's desktop page when we are actually inside DSM: on a dev
  // server this path does not exist and the 404 would show up in the console.
  const insideDsm = window.parent !== window || window.location.pathname.startsWith("/webman/");
  if (insideDsm) {
    try {
      const response = await fetch("/webman/index.cgi", { credentials: "same-origin" });
      if (response.ok) {
        const value = tokenFromText(await response.text());
        if (value) return rememberToken(value, "/webman/index.cgi");
      }
    } catch {
      /* not served from the DSM origin */
    }
  }

  const match = document.cookie.match(/(?:^|;\s*)(?:SynoToken|_SynoToken)=([^;]+)/);
  if (match) return rememberToken(decodeURIComponent(match[1]), "cookie");

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
