"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const http = require("node:http");
const { validateContext, verifyVM } = require("../../extensions/runbar-vscode/bridge");

async function fixture(t, pid, extensions) {
    const calls = [];
    const server = http.createServer((request, response) => {
        const url = new URL(request.url, "http://127.0.0.1");
        calls.push([request.method, url.pathname, url.searchParams.get("isolateId")]);
        const result = url.pathname.endsWith("/getVM")
            ? { type: "VM", pid, isolates: [{ id: "isolates/main", isSystemIsolate: false }] }
            : { type: "Isolate", extensionRPCs: extensions };
        response.writeHead(200, { "Content-Type": "application/json" }); response.end(JSON.stringify({ result }));
    });
    await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
    t.after(() => new Promise((resolve) => server.close(resolve)));
    return { endpoint: new URL(`http://127.0.0.1:${server.address().port}/FIXTURE_AUTH/`), calls };
}

test("old bridge contexts remain valid; attached app PID must be a positive integer", () => {
    const context = { version: 1, projectPath: "/tmp/source", projectName: "Fixture",
        sessionID: "00000000-0000-0000-0000-000000000001", expiresAt: Date.now() + 100000 };
    assert.equal(validateContext(context), context);
    for (const processID of [0, 1, -2, "42", 2.5, 2147483648]) {
        assert.throws(() => validateContext({ ...context, processID }), /invalid-context/);
    }
    assert.equal(validateContext({ ...context, processID: 42 }).processID, 42);
});

test("a responding VM from another app is rejected before isolate inspection", async (t) => {
    const { endpoint, calls } = await fixture(t, 77, ["ext.flutter.reassemble"]);
    await assert.rejects(verifyVM(endpoint, 42), /wrong-process/);
    assert.deepEqual(calls, [["GET", "/FIXTURE_AUTH/getVM", null]]);
});

test("Debug capability is inspected with read-only requests", async (t) => {
    const { endpoint, calls } = await fixture(t, 42, ["ext.flutter.reassemble"]);
    await verifyVM(endpoint, 42);
    assert.deepEqual(calls, [["GET", "/FIXTURE_AUTH/getVM", null], ["GET", "/FIXTURE_AUTH/getIsolate", "isolates/main"]]);
});

test("a Profile-like VM is not handed to the breakpoint debugger", async (t) => {
    const { endpoint } = await fixture(t, 42, ["ext.flutter.connectedVmServiceUri"]);
    await assert.rejects(verifyVM(endpoint, 42), /debug-unavailable/);
});
