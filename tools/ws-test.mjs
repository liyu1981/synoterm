#!/usr/bin/env node
// Protocol smoke test: talks to a running synoterm with a raw WebSocket client
// and asserts the shell echo round-trip.
//
//   ./zig-out/bin/synoterm --listen 8080 --auth dev --web-root frontend/dist &
//   npm i ws && node tools/ws-test.mjs ws://127.0.0.1:8080/ws
import WebSocket from "ws";

const url = process.argv[2] || "ws://127.0.0.1:8080/ws";
const origin = new URL(url).origin;

const socket = new WebSocket(url, { headers: { Origin: origin } });
let output = "";

const timeout = setTimeout(() => {
  console.error("ws-test: timeout waiting for shell echo");
  console.error(JSON.stringify(output.slice(0, 400)));
  socket.terminate();
  process.exit(1);
}, 8000);

socket.on("open", () => {
  socket.send(JSON.stringify({ type: "resize", cols: 100, rows: 30 }));
  socket.send(Buffer.from("echo SYNOTERM_WS_OK\n"));
});

socket.on("message", (data, isBinary) => {
  output += data.toString();
  if (!isBinary) {
    const message = JSON.parse(data.toString());
    if (message.type === "error") {
      console.error("ws-test: server error", message);
      process.exit(1);
    }
  }
  if (output.split("SYNOTERM_WS_OK").length > 2) {
    clearTimeout(timeout);
    console.log("ws-test: ok");
    socket.close();
    process.exit(0);
  }
});

socket.on("error", (error) => {
  console.error("ws-test:", error.message);
  process.exit(1);
});
