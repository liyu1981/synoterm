import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebLinksAddon } from "@xterm/addon-web-links";
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

/** WebSocket path: injected by the DSM wrapper, derived from the URL in dev. */
function wsPath() {
  return new URLSearchParams(window.location.search).get("ws") || `${appBase()}/ws`;
}

/** DSM hands the CSRF token to third-party app scripts via ?SynoToken=… */
function synoToken() {
  return new URLSearchParams(window.location.search).get("SynoToken") || "";
}

function synoTokenSubprotocol(token) {
  const bytes = new TextEncoder().encode(token);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  const encoded = btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
  return `synoterm.syno-token.${encoded}`;
}

class Session {
  constructor(manager, name) {
    this.manager = manager;
    this.name = name;
    this.state = "connecting";
    this.attempts = 0;
    this.closedByUser = false;

    this.pane = document.createElement("div");
    this.pane.className = "terminal-pane";

    this.term = new Terminal(TERM_OPTIONS);
    this.fit = new FitAddon();
    this.term.loadAddon(this.fit);
    this.term.loadAddon(new WebLinksAddon());
    this.term.open(this.pane);
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
    const token = synoToken();
    const protocols = token ? [synoTokenSubprotocol(token)] : undefined;

    this.setState("connecting");
    let socket;
    try {
      socket = new WebSocket(url, protocols);
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
      this.scheduleReconnect();
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
    this.term.write(`\r\n\x1b[33mdisconnected, retrying in ${Math.round(delay / 1000)}s…\x1b[0m\r\n`);
    this.reconnectTimer = setTimeout(() => this.connect(), delay);
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
    try {
      this.fit.fit();
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
    const session = new Session(this, `terminal ${this.counter}`);
    this.tabs.push(session);
    this.host.appendChild(session.element);
    this.renderTabs();
    this.select(session);
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

  updateStatus() {
    const el = document.getElementById("status");
    const text = document.getElementById("status-text");
    const session = this.active;
    if (!session) {
      text.textContent = "";
      return;
    }
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

function boot() {
  const style = document.createElement("style");
  style.textContent = cssText;
  document.head.appendChild(style);

  const manager = new TabManager(document.getElementById("terminal-host"));
  window.synoterm = manager;
  manager.newTab();
  window.addEventListener("resize", () => manager.active?.refit());
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", boot);
} else {
  boot();
}
