// Tests for Model.js, the widget's pure interpretation of status.json.
// Model.js is QML-flavoured JavaScript, so the `.pragma library` line is
// stripped before it is evaluated here.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import test from "node:test";
import assert from "node:assert/strict";

const here = dirname(fileURLToPath(import.meta.url));
const source = readFileSync(join(here, "..", "Model.js"), "utf8")
  .replace(/^\.pragma library\s*$/m, "");
// The export list is derived rather than written out: a hand-kept list silently
// omits each new function, and the test then fails as "not a function" rather
// than as the thing it was meant to check.
const names = [...source.matchAll(/^function\s+([A-Za-z0-9_]+)\s*\(/gm)].map(m => m[1]);
const Model = {};
new Function("exports", `${source}\n;Object.assign(exports, {${names.join(", ")}});`)(Model);

// A real pair of Pushover ids. Both are 19 digits; Number() rounds them, and
// the rounded values are what a naive `a > b` would be comparing.
const IDS = ["1182737485987742200", "1182737485987742201"];

test("two ids that differ only in the last digit are not equal as numbers", () => {
  assert.equal(Number(IDS[0]), Number(IDS[1]),
    "precondition: these ids collide once parsed as doubles");
  assert.notEqual(IDS[0], IDS[1]);
});

test("unread counts position, so colliding ids stay distinct", () => {
  const messages = [{ idStr: IDS[1] }, { idStr: IDS[0] }];
  assert.equal(Model.unreadCount(messages, IDS[0]), 1);
  assert.equal(Model.unreadCount(messages, IDS[1]), 0);
});

test("no marker means everything is unread", () => {
  assert.equal(Model.unreadCount([{ idStr: "a" }, { idStr: "b" }], ""), 2);
});

test("a marker that aged out of the window means everything is unread", () => {
  assert.equal(Model.unreadCount([{ idStr: "a" }], "long-gone"), 1);
});

test("newestIdStr takes the head, because the daemon writes newest-first", () => {
  assert.equal(Model.newestIdStr([{ idStr: "new" }, { idStr: "old" }]), "new");
  assert.equal(Model.newestIdStr([]), "");
});

test("a status file from a newer daemon is refused, not guessed at", () => {
  const status = Model.parseStatus(JSON.stringify({ schemaVersion: 99 }));
  assert.equal(status.ok, false);
  assert.equal(status.schemaTooNew, true);
});

test("unparseable input reads as blank rather than throwing", () => {
  for (const input of ["", "   ", "not json", "null", "[]"]) {
    const status = Model.parseStatus(input);
    assert.equal(status.ok, false, `input: ${JSON.stringify(input)}`);
    assert.deepEqual(status.messages, []);
  }
});

test("normalizeMessages keeps the id as a string and drops junk entries", () => {
  const out = Model.normalizeMessages([
    { id: 1182737485987742200, idStr: IDS[0], title: "t" },
    null,
    "nonsense",
  ]);
  assert.equal(out.length, 1);
  assert.equal(out[0].idStr, IDS[0]);
});

test("only an unacknowledged emergency with a receipt offers the action", () => {
  assert.equal(Model.needsAck({ priority: 2, receipt: "r", acked: false }), true);
  assert.equal(Model.needsAck({ priority: 2, receipt: "r", acked: true }), false);
  assert.equal(Model.needsAck({ priority: 2, receipt: "", acked: false }), false);
  assert.equal(Model.needsAck({ priority: 1, receipt: "r", acked: false }), false);
});

test("priority labels name only what is worth naming", () => {
  assert.equal(Model.priorityLabel(0), "");
  assert.equal(Model.priorityLabel(2), "Emergency");
  assert.equal(Model.priorityLabel(-1), "Quiet");
});

test("dismissed messages drop out of the list", () => {
  const messages = [{ idStr: "c" }, { idStr: "b" }, { idStr: "a" }];
  assert.deepEqual(Model.liveMessages(messages, ["b"]).map(m => m.idStr), ["c", "a"]);
  assert.equal(Model.liveMessages(messages, []).length, 3);
});

test("dismissed messages are not counted as unread", () => {
  const messages = [{ idStr: "c" }, { idStr: "b" }, { idStr: "a" }];
  assert.equal(Model.unreadCount(messages, "a", []), 2);
  assert.equal(Model.unreadCount(messages, "a", ["b"]), 1);
  assert.equal(Model.unreadCount(messages, "a", ["b", "c"]), 0);
});

test("dismissing the marked message does not re-unread the ones above it", () => {
  // The marker is held against the full list for exactly this reason.
  const messages = [{ idStr: "c" }, { idStr: "b" }, { idStr: "a" }];
  assert.equal(Model.unreadCount(messages, "b", ["b"]), 1);
});

test("the dismissed list is pruned to what the daemon still holds", () => {
  const messages = [{ idStr: "b" }, { idStr: "a" }];
  assert.deepEqual(Model.prunedDismissed(messages, ["a", "gone", "b"]), ["a", "b"]);
  assert.deepEqual(Model.prunedDismissed(messages, null), []);
});

test("only http(s) urls are openable, matching the daemon's gate", () => {
  assert.equal(Model.isOpenableUrl("https://example.com"), true);
  assert.equal(Model.isOpenableUrl("http://example.com"), true);
  for (const hostile of ["file:///etc/passwd", "ssh://h", "javascript:alert(1)", "", null]) {
    assert.equal(Model.isOpenableUrl(hostile), false, String(hostile));
  }
});

test("an acknowledged emergency stops asking to be acknowledged", () => {
  const msg = { idStr: "m1", priority: 2, receipt: "r", acked: false };
  assert.equal(Model.needsAck(msg, []), true);
  assert.equal(Model.needsAck(msg, ["m1"]), false);
});

test("a status file with no running flag reads as running", () => {
  // Written by a daemon from before the flag existed.
  const status = Model.parseStatus(JSON.stringify({ schemaVersion: 1, connected: true }));
  assert.equal(status.running, true);
  assert.equal(Model.parseStatus(JSON.stringify({ schemaVersion: 1, running: false })).running, false);
});

test("the id-string fallback covers a file written before idStr existed", () => {
  // The one path where the invariant could break: no idStr, only a number.
  const out = Model.normalizeMessages([{ id: "1182737485987742185", title: "t" }]);
  assert.equal(out[0].idStr, "1182737485987742185");
});

test("an empty message list prunes nothing, because the daemon restarts", () => {
  // Pruning against a transiently empty history would discard every dismissal
  // the user has made, including the one being written in the same call.
  assert.deepEqual(Model.prunedDismissed([], ["a", "b"]), ["a", "b"]);
  assert.deepEqual(Model.prunedDismissed(null, ["a"]), ["a"]);
});

test("clearing keeps earlier dismissals rather than replacing them", () => {
  // What `dismissAll` now builds: the union, then pruned to the live window.
  const messages = [{ idStr: "b" }, { idStr: "a" }];
  const union = ["older-and-aged-out", "a", "b"];
  assert.deepEqual(Model.prunedDismissed(messages, union), ["a", "b"]);
  // And with no history at all, nothing is discarded.
  assert.deepEqual(Model.prunedDismissed([], union), union);
});

// --- handlers ---------------------------------------------------------------

const HANDLERS = JSON.stringify({
  handlers: [{
    name: "ridekick",
    match: { app: "Ridekick Admin" },
    actions: [{ key: "i", label: "Investigate with Claude", run: ["/bin/true"] }],
  }],
});

test("a handler matches its sender by exact app name", () => {
  const handlers = Model.parseHandlers(HANDLERS);
  assert.equal(Model.actionsFor({ app: "Ridekick Admin" }, handlers).length, 1);
  assert.equal(Model.actionsFor({ app: "ridekick admin" }, handlers).length, 1);
});

test("a sender that merely resembles the handler's gets nothing", () => {
  const handlers = Model.parseHandlers(HANDLERS);
  // The whole safety argument: substring matching would hand a local command
  // to any sender that can put "Ridekick Admin" somewhere in its app name.
  for (const app of ["Ridekick Admin (staging)", "Not Ridekick Admin", "Ridekick", "Pushover", ""]) {
    assert.deepEqual(Model.actionsFor({ app }, handlers), [], app);
  }
});

test("a handler cannot rebind a key the panel already spends", () => {
  const handlers = Model.parseHandlers(JSON.stringify({
    handlers: [{ match: { app: "X" }, actions: [
      { key: "d", label: "Delete everything", run: ["/bin/true"] },
      { key: "a", label: "Acknowledge", run: ["/bin/true"] },
      { key: "z", label: "Fine", run: ["/bin/true"] },
    ] }],
  }));
  assert.deepEqual(Model.actionsFor({ app: "X" }, handlers).map(a => a.key), ["z"]);
});

test("a malformed action is dropped without taking its siblings with it", () => {
  const handlers = Model.parseHandlers(JSON.stringify({
    handlers: [{ match: { app: "X" }, actions: [
      { key: "q", label: "No command" },
      { key: "qq", label: "Two characters", run: ["/bin/true"] },
      { key: "w", label: "Empty command", run: [] },
      { key: "e", label: "Good", run: ["/bin/true"] },
      { key: "e", label: "Duplicate key", run: ["/bin/true"] },
    ] }],
  }));
  assert.deepEqual(Model.actionsFor({ app: "X" }, handlers).map(a => a.key), ["e"]);
});

test("a broken handlers file disables handlers, not the panel", () => {
  assert.deepEqual(Model.parseHandlers("{not json"), []);
  assert.deepEqual(Model.parseHandlers(""), []);
  assert.deepEqual(Model.parseHandlers("[]"), []);
  assert.deepEqual(Model.parseHandlers('{"handlers":"nope"}'), []);
});

test("the hint names every key the row will answer to", () => {
  const handlers = Model.parseHandlers(HANDLERS);
  assert.equal(
    Model.actionHint(Model.actionsFor({ app: "Ridekick Admin" }, handlers)),
    "i to investigate with claude",
  );
  assert.equal(Model.actionHint([]), "");
});
