"use strict";

const vscode = require("vscode");
const fs = require("node:fs/promises");
const path = require("node:path");
const { randomBytes } = require("node:crypto");
const { tokenPattern, ticketFromURI, bridgeRequest, validateContext, vmServiceURL, verifyVM } = require("./bridge");

// Only short-lived capability tokens are handed across windows. The authenticated
// VM address is retrieved once, after the correct local workspace has opened.
function activate(context) {
    const processing = new Set();
    const sessions = new Map();
    const pendingRoot = path.join(context.globalStorageUri.fsPath, "pending");
    let disposed = false;

    async function pendingNames() {
        const names = [];
        try {
            const directory = await fs.opendir(pendingRoot);
            let visited = 0;
            for await (const entry of directory) {
                if (/^[a-f0-9]{64}\.json$/.test(entry.name)) { names.push(entry.name); }
                if (++visited >= 128) { break; }
            }
        } catch { /* No pending handoff directory yet. */ }
        return names;
    }

    async function readPending(name) {
        const file = path.join(pendingRoot, name);
        const info = await fs.lstat(file);
        if (!info.isFile() || info.isSymbolicLink() || info.size > 16384) { throw new Error("invalid-ticket"); }
        const pending = JSON.parse(await fs.readFile(file, "utf8"));
        if (!tokenPattern.test(pending.token) || `${pending.token}.json` !== name || !Number.isFinite(pending.expiresAt) ||
            pending.expiresAt <= Date.now() || pending.expiresAt > Date.now() + 185000) {
            await fs.unlink(file); return;
        }
        return pending;
    }

    async function workspaceFor(projectPath) {
        const wanted = await fs.realpath(projectPath);
        for (const folder of vscode.workspace.workspaceFolders || []) {
            if (folder.uri.scheme !== "file") { continue; }
            try { if (await fs.realpath(folder.uri.fsPath) === wanted) { return folder; } }
            catch { /* An unrelated missing workspace folder cannot own this request. */ }
        }
    }

    async function report(ticket, claimID, status, reason) {
        try { await bridgeRequest(ticket, "result", { status, reason, claimID }); } catch { /* Runbar may have closed. */ }
    }

    async function accept(ticket, fromPending = false) {
        if (disposed || processing.has(ticket.token)) { return; }
        processing.add(ticket.token);
        const claimID = randomBytes(16).toString("hex");
        let handedOff = false;
        try {
            if (process.platform !== "darwin" || vscode.env.remoteName) { throw new Error("local-mac-only"); }
            const target = validateContext(await bridgeRequest(ticket, "context"));
            let folder = await workspaceFor(target.projectPath);
            if (!folder) {
                // Do not replace a user's other project or trust it automatically.
                // Opening a new window restarts that window's extension host.
                if (fromPending) { return; }
                await fs.mkdir(pendingRoot, { recursive: true, mode: 0o700 });
                let active = 0;
                for (const name of await pendingNames()) {
                    try { if (await readPending(name)) { active++; } } catch { /* Ignore a stale malformed file. */ }
                }
                if (active >= 8) { throw new Error("too-many-requests"); }
                await fs.writeFile(path.join(pendingRoot, `${ticket.token}.json`), JSON.stringify({
                    ...ticket, projectPath: target.projectPath, expiresAt: target.expiresAt,
                }), { flag: "wx", mode: 0o600 });
                await vscode.commands.executeCommand("vscode.openFolder", vscode.Uri.file(target.projectPath), { forceNewWindow: true });
                handedOff = true;
                return;
            }
            if (!vscode.workspace.isTrusted) { throw new Error("workspace-untrusted"); }
            const dart = vscode.extensions.getExtension("Dart-Code.dart-code");
            if (!dart) { throw new Error("dart-extension-missing"); }
            // Explicit Dart debugger selection is essential: a second Flutter
            // resident compiler would compete with the one owned by Runbar.
            const version = String(dart.packageJSON.version).split(".").map(Number);
            if (version[0] < 3 || (version[0] === 3 && version[1] < 144)) { throw new Error("dart-extension-outdated"); }
            await dart.activate();
            if (disposed) { return; }
            const claimed = validateContext(await bridgeRequest(ticket, "claim", { claimID, appDebugger: "v1" }));
            if (claimed.projectPath !== target.projectPath || claimed.sessionID !== target.sessionID ||
                claimed.processID !== target.processID) { throw new Error("run-changed"); }
            const endpoint = vmServiceURL(claimed.vmServiceUri);
            // No redirects, proxies or arbitrary URLs; probe before handing the
            // endpoint to the debug adapter. Do not log authentication paths.
            await verifyVM(endpoint, claimed.processID);
            // Recheck the owning run after SDK activation and the VM probe.
            const current = validateContext(await bridgeRequest(ticket, "context"));
            if (current.sessionID !== target.sessionID || current.processID !== target.processID ||
                current.projectPath !== target.projectPath) { throw new Error("run-changed"); }
            if (disposed || target.expiresAt <= Date.now()) { throw new Error("run-changed"); }
            if (sessions.has(target.sessionID)) {
                await report(ticket, claimID, "attached");
                await vscode.commands.executeCommand("workbench.view.debug");
                return;
            }
            const started = await vscode.debug.startDebugging(folder, {
                name: `Runbar: ${target.projectName}`,
                type: "dart",
                request: "attach",
                debuggerType: "dart",
                cwd: folder.uri.fsPath,
                vmServiceUri: endpoint.toString(),
                runbarSessionID: target.sessionID,
            });
            if (!started) { throw new Error("attach-failed"); }
            await report(ticket, claimID, "attached");
            await vscode.commands.executeCommand("workbench.view.debug");
        } catch (error) {
            // Exception strings from network/debug adapters can contain the VM
            // authentication token. Use a closed set of user-facing reasons.
            const reasons = new Set(["workspace-untrusted", "dart-extension-missing", "dart-extension-outdated", "local-mac-only", "run-changed", "vm-unavailable", "wrong-process", "debug-unavailable"]);
            const reason = reasons.has(error?.message) ? error.message : "attach-failed";
            await report(ticket, claimID, "failed", reason);
            const detail = {
                "workspace-untrusted": "请先在 VS Code 中信任此源码目录，再回到 Runbar 点击连接。",
                "dart-extension-missing": "请安装并启用官方 Dart 和 Flutter 扩展。",
                "dart-extension-outdated": "请将官方 Dart 扩展更新到 3.144.0 或更新版本。",
                "local-mac-only": "当前只支持本机 macOS 的 VS Code 窗口。请退出远程工作区后重试。",
                "wrong-process": "调试服务不再属于原来关联的 App，请在 Runbar 重新连接 App 后再试。",
                "debug-unavailable": "此 App 未提供 Flutter Debug 调试能力。请运行 Debug 包，待初始化完成后重试；Profile / Release 不支持此断点连接。",
            }[reason] || "请确认 Runbar 中的 Debug 运行仍在进行，再点击连接。调试器的详细错误可在 VS Code 中查看。";
            void vscode.window.showErrorMessage(`Runbar 未能连接调试。${detail}`);
        } finally {
            processing.delete(ticket.token);
            if (!handedOff) { await fs.unlink(path.join(pendingRoot, `${ticket.token}.json`)).catch(() => {}); }
        }
    }

    async function resumePending() {
        // This dedicated directory contains no VM URI; cap reads and size even
        // when old requests remain after an interrupted window opening.
        for (const name of await pendingNames()) {
            try {
                const pending = await readPending(name);
                if (!pending) { continue; }
                if (typeof pending.projectPath === "string" && await workspaceFor(pending.projectPath)) { await accept(pending, true); }
            } catch { /* A different window may already have consumed this token. */ }
        }
    }

    context.subscriptions.push(
        vscode.window.registerUriHandler({ handleUri: async (uri) => {
            try { await accept(ticketFromURI(uri)); }
            catch { void vscode.window.showErrorMessage("Runbar 连接链接无效，请从 Runbar 重新连接。"); }
        } }),
        vscode.debug.onDidStartDebugSession((session) => {
            if (session.type === "dart" && session.configuration.runbarSessionID) { sessions.set(session.configuration.runbarSessionID, session); }
        }),
        vscode.debug.onDidTerminateDebugSession((session) => {
            if (sessions.get(session.configuration.runbarSessionID)?.id === session.id) { sessions.delete(session.configuration.runbarSessionID); }
        }),
        vscode.workspace.onDidGrantWorkspaceTrust(() => { void resumePending(); }),
        { dispose() { disposed = true; } },
    );
    void resumePending();
}

module.exports = { activate };
