"use strict";

const http = require("node:http");
const https = require("node:https");

const extensionID = "kingxcode.runbar-bridge";
const tokenPattern = /^[a-f0-9]{64}$/;

function ticketFromURI(uri) {
    if (uri.scheme !== "vscode" || uri.authority.toLowerCase() !== extensionID || uri.path !== "/attach") {
        throw new Error("invalid-ticket");
    }
    const query = new URLSearchParams(uri.query);
    if (query.getAll("port").length !== 1 || query.getAll("token").length !== 1 || [...query.keys()].length !== 2) {
        throw new Error("invalid-ticket");
    }
    const port = query.get("port");
    const token = query.get("token");
    if (!/^[0-9]{1,5}$/.test(port) || Number(port) < 1024 || Number(port) > 65535 || !tokenPattern.test(token)) {
        throw new Error("invalid-ticket");
    }
    return { port: Number(port), token };
}

function requestJSON(url, method = "GET", body, limit = 262144) {
    return new Promise((resolve, reject) => {
        const client = url.protocol === "https:" ? https : http;
        const bytes = body === undefined ? undefined : Buffer.from(JSON.stringify(body));
        const req = client.request(url, {
            method,
            agent: false,
            headers: bytes ? { "Content-Type": "application/json", "Content-Length": bytes.length } : {},
        }, (response) => {
            if (response.statusCode !== 200) {
                response.resume(); reject(new Error("service-unavailable")); return;
            }
            const chunks = [];
            let size = 0;
            response.on("data", (chunk) => {
                size += chunk.length;
                if (size > limit) { req.destroy(new Error("response-too-large")); return; }
                chunks.push(chunk);
            });
            response.on("error", reject);
            response.on("end", () => {
                try { resolve(JSON.parse(Buffer.concat(chunks).toString("utf8"))); }
                catch { reject(new Error("invalid-response")); }
            });
        });
        // Absolute deadline, including a peer that continuously sends data.
        const timeout = setTimeout(() => req.destroy(new Error("service-timeout")), 8000);
        req.on("close", () => clearTimeout(timeout));
        req.on("error", reject);
        req.end(bytes);
    });
}

function bridgeRequest(ticket, action, body) {
    if (!Number.isInteger(ticket.port) || ticket.port < 1024 || ticket.port > 65535 || !tokenPattern.test(ticket.token)) {
        throw new Error("invalid-ticket");
    }
    return requestJSON(new URL(`http://127.0.0.1:${ticket.port}/v1/${ticket.token}/${action}`), body === undefined ? "GET" : "POST", body, 32768);
}

function validateContext(value) {
    if (!value || value.version !== 1 || typeof value.projectPath !== "string" || !value.projectPath.startsWith("/") ||
        value.projectPath.length > 8192 || value.projectPath.includes("\0") ||
        typeof value.projectName !== "string" || value.projectName.length > 1024 ||
        typeof value.sessionID !== "string" || !/^[0-9a-f-]{36}$/i.test(value.sessionID) ||
        !Number.isFinite(value.expiresAt) || value.expiresAt <= Date.now() || value.expiresAt > Date.now() + 185000) {
        throw new Error("invalid-context");
    }
    return value;
}

function vmServiceURL(value) {
    if (typeof value !== "string" || value.length > 16384) { throw new Error("invalid-vm-uri"); }
    const url = new URL(value);
    if (!["http:", "https:"].includes(url.protocol) || !["127.0.0.1", "localhost", "[::1]"].includes(url.hostname) ||
        url.username || url.password || url.search || url.hash) { throw new Error("invalid-vm-uri"); }
    if (!url.pathname.endsWith("/")) { url.pathname += "/"; }
    return url;
}

module.exports = { extensionID, tokenPattern, ticketFromURI, bridgeRequest, validateContext, vmServiceURL, requestJSON };
