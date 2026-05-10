#!/usr/bin/env node
// Persistent-VM daemon + thin client for the gondolin-sandbox skill.
//
// daemon mode  : boot a VM with /workspace bind-mounted to the host
//                project dir, listen on a Unix socket, run each
//                received command via `vm.exec` and stream output
//                back over the socket.
// exec mode    : connect to the daemon, send a base64-encoded command,
//                stream stdout/stderr to process.stdout/.stderr until
//                the daemon reports an exit code, then exit with same.
//
// The exec mode is what the PreToolUse hook rewrites every Bash call
// into. Because the host Bash tool runs our exec mode natively, it
// gets line-by-line streaming as bytes arrive on the socket.
//
// State persists across calls because the VM lives in the daemon
// process, not in each call.

import { VM, RealFSProvider } from "@earendil-works/gondolin";
import net from "node:net";
import fs from "node:fs";
import { Buffer } from "node:buffer";
import { Writable } from "node:stream";

const args = process.argv.slice(2);
const subcmd = args[0];

function getOpt(name) {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : undefined;
}

// --- shared: line-delimited JSON over a socket ------------------------

function makeLineReader(stream, onLine) {
  let buf = Buffer.alloc(0);
  stream.on("data", (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    while (true) {
      const i = buf.indexOf(0x0a);
      if (i < 0) break;
      const line = buf.slice(0, i).toString("utf8");
      buf = buf.slice(i + 1);
      if (line.length === 0) continue;
      onLine(line);
    }
  });
}

function send(conn, obj) {
  conn.write(JSON.stringify(obj) + "\n");
}

// --- daemon -----------------------------------------------------------

async function runDaemon() {
  const sockPath = getOpt("sock");
  const workspace = getOpt("workspace");
  if (!sockPath || !workspace) {
    console.error("daemon needs --sock <path> --workspace <hostPath>");
    process.exit(2);
  }

  try {
    fs.unlinkSync(sockPath);
  } catch {}

  process.stderr.write(`[gondolin-helper] booting VM (workspace=${workspace})\n`);
  const vm = await VM.create({
    vfs: { mounts: { "/workspace": new RealFSProvider(workspace) } },
  });
  process.stderr.write(`[gondolin-helper] VM ready\n`);

  let shuttingDown = false;
  async function shutdown() {
    if (shuttingDown) return;
    shuttingDown = true;
    try { await vm.close(); } catch {}
    try { fs.unlinkSync(sockPath); } catch {}
    process.exit(0);
  }
  for (const sig of ["SIGTERM", "SIGINT", "SIGHUP"]) {
    process.on(sig, shutdown);
  }

  const server = net.createServer(async (conn) => {
    let active = false;
    makeLineReader(conn, async (line) => {
      if (active) return;
      active = true;
      let req;
      try {
        req = JSON.parse(line);
      } catch (e) {
        send(conn, { type: "error", message: `bad json: ${e.message}` });
        conn.end();
        return;
      }

      if (req.type === "shutdown") {
        send(conn, { type: "bye" });
        conn.end();
        await shutdown();
        return;
      }

      const cmd = Buffer.from(req.cmdB64, "base64").toString("utf8");

      // Build writable streams that forward each chunk to the client.
      const mkStream = (label) => new Writable({
        write(chunk, _enc, cb) {
          try {
            send(conn, { type: label, dataB64: Buffer.from(chunk).toString("base64") });
          } catch {}
          cb();
        },
      });
      const stdoutW = mkStream("out");
      const stderrW = mkStream("err");

      try {
        const result = await vm.exec(cmd, {
          stdout: stdoutW,
          stderr: stderrW,
          cwd: req.cwd ?? "/workspace",
        });
        send(conn, { type: "exit", exitCode: result.exitCode, signal: result.signal });
      } catch (e) {
        send(conn, { type: "error", message: e?.message ?? String(e) });
      }
      conn.end();
    });
    conn.on("error", () => {});
  });

  server.listen(sockPath, () => {
    process.stderr.write(`[gondolin-helper] listening ${sockPath}\n`);
  });
}

// --- exec (client) ----------------------------------------------------

function runExec() {
  const sockPath = getOpt("sock");
  const cmdB64 = args[args.length - 1];
  if (!sockPath || !cmdB64 || cmdB64.startsWith("--")) {
    console.error("exec needs --sock <path> <BASE64_CMD>");
    process.exit(2);
  }

  const conn = net.createConnection(sockPath);
  let exited = false;
  let exitCode = 1;

  conn.on("error", (e) => {
    process.stderr.write(`gondolin-helper: socket error: ${e.message}\n`);
    if (!exited) process.exit(1);
  });

  conn.on("connect", () => {
    send(conn, { cmdB64 });
  });

  makeLineReader(conn, (line) => {
    let msg;
    try { msg = JSON.parse(line); } catch { return; }
    switch (msg.type) {
      case "out":
        process.stdout.write(Buffer.from(msg.dataB64, "base64"));
        break;
      case "err":
        process.stderr.write(Buffer.from(msg.dataB64, "base64"));
        break;
      case "exit":
        exited = true;
        exitCode = msg.exitCode ?? 1;
        conn.end();
        break;
      case "error":
        process.stderr.write(`gondolin-helper: ${msg.message}\n`);
        exited = true;
        exitCode = 1;
        conn.end();
        break;
    }
  });

  conn.on("close", () => {
    process.exit(exited ? exitCode : 1);
  });
}

// --- shutdown signal ------------------------------------------------

function runShutdown() {
  const sockPath = getOpt("sock");
  if (!sockPath) {
    console.error("shutdown needs --sock <path>");
    process.exit(2);
  }
  if (!fs.existsSync(sockPath)) process.exit(0);

  const conn = net.createConnection(sockPath);
  conn.on("error", () => process.exit(0));
  conn.on("connect", () => send(conn, { type: "shutdown" }));
  conn.on("close", () => process.exit(0));
  setTimeout(() => process.exit(0), 5000).unref();
}

// --- dispatch ---------------------------------------------------------

if (subcmd === "daemon") await runDaemon();
else if (subcmd === "exec") runExec();
else if (subcmd === "shutdown") runShutdown();
else {
  console.error(`unknown subcommand: ${subcmd}`);
  console.error("usage: helper.mjs (daemon|exec|shutdown) [options]");
  process.exit(2);
}
