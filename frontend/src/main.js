import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebLinksAddon } from "@xterm/addon-web-links";
// xterm.js ships layout styles that are *required*: without them its helper
// elements (font-width measurement container, textarea, accessibility layer)
// stay visible and paint stray rows of characters over the screen.
import xtermCss from "@xterm/xterm/css/xterm.css";
import cssText from "./style.css";

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

const TERM_OPTIONS = {
  fontFamily: '"JetBrains Mono", "SFMono-Regular", Menlo, Consolas, "Liberation Mono", monospace',
  fontSize: 13,
  lineHeight: 1.15,
  cursorBlink: true,
  scrollback: 10000,
  allowProposedApi: true,
  theme: THEME,
};

/** Base path of the app ("/synoterm" in DSM, "" in dev). */
function appBase() {
  const path = window.location.pathname.replace(/\/index\.html$/, "");
  return path.replace(/\/$/, "");
}

/**
 * WebSocket path resolution order:
 *   1. window.SYNOTERM_CONFIG.ws  (written by the packaging step)
 *   2. ?ws=…                     (injected by the DSM 7.2 Vue wrapper)
 *   3. derived from the page URL (dev server)
 */
function wsPath() {
  const configured = window.SYNOTERM_CONFIG && window.SYNOTERM_CONFIG.ws;
  if (typeof configured === "string" && configured.length > 0) return configured;
  const injected = new URLSearchParams(window.location.search).get("ws");
  if (injected) return injected;
  return `${appBase()}/ws`;
}

/**
 * DSM's CSRF token, if we can find it.
 *
 *  - DSM 7.2 app scripts get `?SynoToken=…` appended to their src; the wrapper
 *    forwards it into this page's URL.
 *  - With the DSM 7.0/7.1 `.url` registration nothing is injected, so we try
 *    the same-origin DSM desktop frame and the token cookie.
 *
 * An empty value is fine: the backend falls back to cookie-only
 * authentication, and rejects the session if DSM disagrees.
 */
function synoToken() {
  const fromUrl = new URLSearchParams(window.location.search).get("SynoToken");
  if (fromUrl) return fromUrl;

  try {
    const parentWindow = window.parent;
    if (parentWindow && parentWindow !== window) {
      const candidates = [
        parentWindow.SynoToken,
        parentWindow._SynoToken,
        parentWindow.SYNO && parentWindow.SYNO.SDS && parentWindow.SYNO.SDS.Session
          ? parentWindow.SYNO.SDS.Session.getSynoToken?.()
          : undefined,
      ];
      for (const candidate of candidates) {
        if (typeof candidate === "string" && candidate.length > 0) return candidate;
      }
    }
  } catch {
    /* cross-origin parent (dev server) — expected */
  }

  const match = document.cookie.match(/(?:^|;\s*)(?:SynoToken|_SynoToken)=([^;]+)/);
  return match ? decodeURIComponent(match[1]) : "";
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

    this.term = new Terminal(TERM_OPTIONS);
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

  connect() {
    const scheme = window.location.protocol === "https:" ? "wss:" : "ws:";
    const url = `${scheme}//${window.location.host}${wsPath()}`;
    const protocols = [];
    const dev = devToken();
    if (dev) protocols.push(`synoterm.dev-token.${base64url(dev)}`);
    const token = synoToken();
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
    try {
      const response = await fetch(`${appBase()}/status`, { credentials: "same-origin" });
      const text = await response.text();
      let info;
      try {
        info = JSON.parse(text);
      } catch {
        info = undefined;
      }
      if (!response.ok) {
        const reason = info?.reason || `HTTP ${response.status}`;
        this.manager.setNotice(reason, true);
        this.term.write(`\r\n\x1b[31m${reason}\x1b[0m\r\n`);
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
    window.addEventListener("keydown", (event) => this.onKeydown(event));
    window.addEventListener("beforeunload", () => {
      for (const tab of this.tabs) tab.close();
    });
  }

  onKeydown(event) {
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
