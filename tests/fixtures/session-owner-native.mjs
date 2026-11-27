// Drive the real Pi/omp watch and turn-end extensions with a fake engine API.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const [family, repo] = process.argv.slice(2);
const { FM_HOME: home } = process.env;
const state = join(home, "state");
const executable = (name) => join(repo, "bin", "fm-" + name + ".sh");
const call = (name, ...args) => spawnSync(executable(name), args, { encoding: "utf8", env: process.env });
const extension = (name) => pathToFileURL(join(repo, "." + family, "extensions", name + ".ts")).href;
const watchUrl = extension("fm-primary-" + family + "-watch");
const guardUrl = extension("fm-primary-turnend-guard");
const handlers = new Map();
let tool;
const delivered = [];
const harness = {
  on(name, handler) {
    const group = handlers.get(name) ?? [];
    group.push(handler);
    handlers.set(name, group);
  },
  registerCommand() {},
  registerTool(info) { tool = info; },
  async sendUserMessage(content, options) { delivered.push({ content, options }); },
};
async function dispatch(event, ...args) {
  const results = [];
  for (const handler of handlers.get(event) ?? []) results.push(await handler(...args));
  return results;
}

const legacy = spawnSync(process.execPath, ["--input-type=module", "-e", [
  "import assert from 'node:assert/strict';",
  "import { spawnSync } from 'node:child_process';",
  "import { existsSync, writeFileSync } from 'node:fs';",
  "const [watch, lock, state] = process.argv.slice(1);",
  "writeFileSync(state + '/.lock', process.pid + '\\n');",
  "(await import(watch)).default({ on() {}, registerCommand() {}, registerTool() {} });",
  "assert.notEqual(spawnSync(lock).status, 0);",
  "assert(!existsSync(state + '/.lock.owner-format'));",
].join("\n"), watchUrl, executable("lock"), state], { env: process.env, encoding: "utf8" });
assert.equal(legacy.status, 0, legacy.stderr);
(await import(watchUrl)).default(harness);
(await import(guardUrl)).default(harness);
assert.equal(process.env.FM_SESSION_OWNER_KIND, "native");
assert.equal(process.env.FM_SESSION_OWNER_PID, String(process.pid));
const current = call("lock", "verify", String(process.pid));
assert.equal(current.status, 0, current.stderr);
const generation = current.stdout.trim();
assert.match(generation, /^[a-f0-9]{64}$/);
const marks = ["watch", "turnend"].map((part) => join(state, "." + family + "-" + part + "-extension-loaded"));
for (const mark of marks) {
  const [build, pid, receipt] = readFileSync(mark, "utf8").trimEnd().split("\n");
  assert.match(build, /^sha256:[a-f0-9]{64}$/);
  assert.equal(pid, String(process.pid));
  assert.equal(receipt, generation);
}
const result = await tool.execute("fixture", {});
assert.match(result.content[0].text, /started .* extension arm child/);
const stop = await dispatch(family === "pi" ? "agent_settled" : "session_stop", {});
if (family === "pi") {
  assert.equal(delivered.length, 1);
  assert.equal(delivered[0].options.deliverAs, "followUp");
  assert.match(delivered[0].content, /fixture supervision needs a continuation/);
} else {
  const continuation = stop.find((entry) => entry?.continue);
  assert.equal(continuation?.continue, true);
  assert.match(continuation.additionalContext, /fixture supervision needs a continuation/);
}
const before = marks.map((path) => readFileSync(path, "utf8"));

// A nested engine starts with an inherited environment. Loading its real
// adapter must replace the binding and must never write the parent's markers.
const nested = spawnSync(process.execPath, ["--input-type=module", "-e", [
  "import assert from 'node:assert/strict';",
  "import { spawnSync } from 'node:child_process';",
  "const original = process.env.FM_SESSION_OWNER_ID;",
  "const native = await import(process.argv[1]);",
  "native.default({ on() {}, registerCommand() {}, registerTool() {} });",
  "assert.notEqual(process.env.FM_SESSION_OWNER_ID, original);",
  "assert.equal(process.env.FM_SESSION_OWNER_PID, String(process.pid));",
  "assert.notEqual(spawnSync(process.argv[2]).status, 0);",
].join("\n"), watchUrl, executable("lock")], { env: process.env, encoding: "utf8" });
assert.equal(nested.status, 0, nested.stderr);
assert.deepEqual(marks.map((path) => readFileSync(path, "utf8")), before);
const unavailable = spawnSync(process.execPath, ["--input-type=module", "-e", [
  "import assert from 'node:assert/strict';",
  "const handlers = new Map();",
  "(await import(process.argv[1])).default({ on(event, handler) { handlers.set(event, handler); } });",
  "const result = await handlers.get('tool_call')({ type: 'tool_call', toolName: 'bash', input: { command: 'cd projects/managed' } });",
  "assert.equal(result.block, true);",
  "assert.match(result.reason, /fixture seatbelt refuses a project cd/);",
  "assert.equal(handlers.has('agent_settled') || handlers.has('session_stop'), false);",
].join("\n"), guardUrl], { env: { ...process.env, FM_PROC_ROOT_OVERRIDE: join(state, "unreadable-proc") }, encoding: "utf8" });
assert.equal(unavailable.status, 0, unavailable.stderr);
await dispatch("session_shutdown", {}, {});

const completion = join(state, ".session-start-complete." + generation);
writeFileSync(completion, String(process.pid) + "\nstart=" + process.env.FM_SESSION_OWNER_START + "\ngeneration=" + generation + "\n");
for (const source of ["clear", "compact"]) {
  const rebuild = call("sessionstart-run", "--source", source);
  assert.equal(rebuild.status, 0, rebuild.stderr);
  assert.match(rebuild.stdout, /fixture digest --reemit/);
}
const proof = join(state, ".lock.owner." + String(process.pid));
const matching = readFileSync(proof, "utf8");
writeFileSync(proof, matching.replace(/:\d+\t/, ":0\t"));
assert.notEqual(call("lock", "verify", String(process.pid)).status, 0);
const compact = call("sessionstart-run", "--source", "compact");
assert.equal(compact.status, 0, compact.stderr);
assert.doesNotMatch(compact.stdout, /--reemit/);
assert.match(compact.stdout, /fixture digest --source compact/);
assert(existsSync(completion));
