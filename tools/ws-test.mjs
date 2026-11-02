#!/usr/bin/env node
// Protocol smoke test / end-to-end probe.
//
//   node tools/ws-test.mjs [url] [options]
//
//   url                    default ws://127.0.0.1:8080/ws
//   --cookie '<header>'    Cookie header (DSM session), e.g. 'id=abc123'
//   --token '<token>'      SynoToken; sent as the WebSocket subprotocol
//   --dev-token '<token>'  dev server shared secret (synoterm.dev-token.*)
//   --origin '<url>'       Origin header override (default: derived from url)
//   --insecure             accept self-signed TLS (DSM's default certificate)
//   --expect '<text>'      text that must appear in the output
//   --timeout <seconds>    default 10
//   --quiet                only print the verdict
import WebSocket from "ws";

const args = process.argv.slice(2);
let url = "ws://127.0.0.1:8080/ws";
const options = { cookie: "", token: "", devToken: "", origin: "", insecure: false, expect: "SYNOTERM_WS_OK", timeout: 10, quiet: false };

for (let i = 0; i < args.length; i += 1) {
  const arg = args[i];
  if (!arg.startsWith("--") && url === "ws://127.0.0.1:8080/ws") {
    url = arg;
  } else if (arg === "--cookie") options.cookie = args[++i] || "";
  else if (arg === "--token") options.token = args[++i] || "";
  else if (arg === "--dev-token") options.devToken = args[++i] || "";
  else if (arg === "--origin") options.origin = args[++i] || "";
  else if (arg === "--expect") options.expect = args[++i] || "";
  else if (arg === "--timeout") options.timeout = Number(args[++i] || 10);
  else if (arg === "--insecure") options.insecure = true;
  else if (arg === "--quiet") options.quiet = true;
  else {
    console.error(`unknown argument: ${arg}`);
    process.exit(2);
  }
}

const origin = options.origin || new URL(url).origin;
const headers = { Origin: origin };
if (options.cookie) headers.Cookie = options.cookie;

const protocols = [];
if (options.devToken) protocols.push(`synoterm.dev-token.${base64url(options.devToken)}`);
if (options.token) protocols.push(`synoterm.syno-token.${base64url(options.token)}`);

function base64url(value) {
  return Buffer.from(value, "utf8").toString("base64").replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

const log = (...parts) => {
  if (!options.quiet) console.log(...parts);
};

log(`connecting ${url}`);
log(
  `  origin: ${origin}` +
    (options.cookie ? `, cookie: ${maskCookie(options.cookie)}` : "") +
    (options.token ? ", token: <redacted>" : "") +
    (options.devToken ? ", dev-token: <redacted>" : ""),
);

const socket = new WebSocket(url, protocols.length > 0 ? protocols : undefined, {
  headers,
  ...(options.insecure ? { rejectUnauthorized: false } : {}),
});

let output = "";
let control = [];
let settled = false;

const timer = setTimeout(() => {
  finish(1, `timeout after ${options.timeout}s — no "${options.expect}" in the output`);
}, options.timeout * 1000);

function finish(code, reason) {
  if (settled) return;
  settled = true;
  clearTimeout(timer);
  if (control.length > 0) log(`  control frames: ${control.join(" ")}`);
  if (code === 0) {
    log(`ws-test: ok (${url})`);
  } else {
    console.error(`ws-test: FAILED — ${reason}`);
    if (output) console.error(`  last output: ${JSON.stringify(output.slice(-300))}`);
  }
  try {
    socket.terminate();
  } catch {
    /* ignore */
  }
  process.exit(code);
}

function maskCookie(cookie) {
  // Never print session material: the transcript may be shared.
  return cookie.replace(/(id=)([^;]*)/, (_m, key) => `${key}********`);
}

socket.on("open", () => {
  log("  handshake: 101 Switching Protocols");
  socket.send(JSON.stringify({ type: "resize", cols: 100, rows: 30 }));
  socket.send(Buffer.from(`echo ${options.expect}\n`));
});

socket.on("message", (data, isBinary) => {
  if (isBinary) {
    output += data.toString();
    if (output.split(options.expect).length > 2) finish(0);
    return;
  }
  const raw = data.toString();
  output += raw;
  try {
    const message = JSON.parse(raw);
    control.push(message.type + (message.code ? `(${message.code})` : ""));
    if (message.type === "ready") log(`  server: ready${message.user ? ` as ${message.user}` : ""}`);
    if (message.type === "error") finish(1, `server error: ${JSON.stringify(message)}`);
  } catch {
    /* not JSON — treat as text output */
  }
});

socket.on("unexpected-response", (request, response) => {
  let body = "";
  response.on("data", (chunk) => {
    body += chunk.toString();
  });
  response.on("end", () => {
    const hint = {
      401: "DSM did not accept the session (cookie missing/expired, or the token is required)",
      403: "cross-origin request, or the account is not in the administrators group",
      404: "wrong path — is the nginx mount /synoterm/ present?",
      429: "session limit reached",
      500: "authenticate.cgi missing/failed, or the binary lacks the setuid privilege",
    }[response.statusCode];
    finish(1, `HTTP ${response.statusCode} ${hint || ""}${body ? ` — ${body.trim().slice(0, 160)}` : ""}`);
  });
});

socket.on("error", (error) => finish(1, error.message));
