"""Runbar's read-only mitmdump addon (mitmproxy >= 10).

Never change a request, response, or WebSocket message. HTTP bodies are streamed
unchanged; only a bounded copy is retained for the local capture pipe. mitmdump
does not keep a historical view, and completed WebSocket messages are released.
"""
import asyncio
import base64
import collections
import json
import os
import threading
import time
import zlib

from mitmproxy import ctx

BODY_LIMIT = 1024 * 1024
PREVIEW_BUDGET = 16 * 1024 * 1024
QUEUE_BUDGET = 16 * 1024 * 1024
LINE_LIMIT = 4 * 1024 * 1024
PREFIX = b"RUNBAR_CAPTURE_V1 "


def micros(value=None):
    return int((time.time() if value is None else value) * 1_000_000)


def limited_text(value, limit):
    return str(value).encode("utf-8", "replace")[:limit].decode("utf-8", "ignore")


def headers(value):
    result = {}
    size = 2
    if value is not None:
        for name, content in value.items(multi=True):
            # The serialized JSON size, including escaping, is the actual bound.
            name, content = limited_text(name, 1024), limited_text(content, 16_384)
            cost = len(json.dumps([name, content], ensure_ascii=False).encode("utf-8")) + 8
            if size + cost > 31_000:
                result["[Runbar]"] = ["Headers 超过 32 KB，已截断"]
                break
            result.setdefault(name, []).append(content)
            size += cost
    return json.dumps(result, ensure_ascii=False, separators=(",", ":"))


class Capture:
    def __init__(self):
        self.decrypt_tls = os.environ.get("RUNBAR_PROXY_DECRYPT_TLS") == "1"
        self.parent = os.getppid()
        self.preview_bytes = 0
        self.active_previews = 0
        self.sequence = 0
        self.pending = collections.deque()
        self.pending_bytes = 0
        self.dropped = 0
        self.stopping = False
        self.last_tls_warning = 0.0
        self.condition = threading.Condition()
        self.writer = threading.Thread(target=self.write_events, name="runbar-capture", daemon=True)
        self.writer.start()

    def emit(self, event):
        encoded = PREFIX + json.dumps(event, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"
        with self.condition:
            if self.stopping:
                return
            if len(encoded) > LINE_LIMIT or self.pending_bytes + len(encoded) > QUEUE_BUDGET or len(self.pending) >= 2048:
                self.dropped += 1
                return
            self.pending.append(encoded)
            self.pending_bytes += len(encoded)
            self.condition.notify()

    def write_events(self):
        def write(data):
            view = memoryview(data)
            while view:
                written = os.write(1, view)
                view = view[written:]
        try:
            while True:
                with self.condition:
                    while not self.pending and not self.stopping:
                        self.condition.wait()
                    if not self.pending:
                        return
                    event = self.pending.popleft()
                    self.pending_bytes -= len(event)
                    dropped, self.dropped = self.dropped, 0
                if dropped:
                    write(PREFIX + json.dumps({"type": "warning", "dropped": dropped,
                        "message": "抓包缓存处理速度落后，部分事件未记录；代理继续转发。"}, ensure_ascii=False).encode("utf-8") + b"\n")
                write(event)
        except (BrokenPipeError, OSError):
            # The owner has gone. Never block its former target on capture I/O.
            with self.condition:
                self.stopping = True
                self.pending.clear()
                self.pending_bytes = 0

    def running(self):
        proxy = ctx.master.addons.get("proxyserver")
        ports = [address[1] for address in proxy.listen_addrs() if address[0] == "127.0.0.1"]
        if not ports:
            raise RuntimeError("Runbar 代理未在本机 IPv4 地址监听")
        self.emit({"type": "ready", "port": ports[0]})
        self.watchdog = asyncio.create_task(self.watch_parent())

    async def watch_parent(self):
        while True:
            await asyncio.sleep(1)
            if os.getppid() != self.parent:
                ctx.master.shutdown()
                return

    def done(self):
        if hasattr(self, "watchdog"):
            self.watchdog.cancel()
        with self.condition:
            self.stopping = True
            self.condition.notify()
        self.writer.join(timeout=1)

    def tls_clienthello(self, data):
        if not self.decrypt_tls:
            data.ignore_connection = True

    def tls_failed_client(self, data):
        if self.decrypt_tls and time.monotonic() - self.last_tls_warning >= 5:
            self.last_tls_warning = time.monotonic()
            self.emit({"type": "warning", "issue": "tlsHandshake", "message": "目标 App 未完成 TLS 握手；请检查是否信任 Runbar 抓包证书，以及是否使用证书固定或自定义证书库。"})

    def requestheaders(self, flow):
        accepted = self.active_previews < 64
        if accepted:
            self.active_previews += 1
        state = {"request": bytearray(), "response": bytearray(), "request_bytes": 0,
                 "response_bytes": 0, "accepted": accepted, "released": False}
        flow.metadata["runbar_capture"] = state
        flow.request.stream = self.tee(state, "request")
        self.report(flow, complete=False)

    def tee(self, state, side):
        def stream(chunk):
            state[side + "_bytes"] += len(chunk)
            if state["accepted"] and not state["released"]:
                available = max(0, min(BODY_LIMIT - len(state[side]), PREVIEW_BUDGET - self.preview_bytes))
                copied = chunk[:available]
                state[side].extend(copied)
                self.preview_bytes += len(copied)
            return chunk
        return stream

    def responseheaders(self, flow):
        state = flow.metadata.get("runbar_capture")
        if state is not None:
            flow.response.stream = self.tee(state, "response")

    def response(self, flow):
        self.report(flow, complete=True)

    def error(self, flow):
        self.report(flow, complete=True)

    def body(self, state, side, message):
        data = bytes(state[side])
        notes = []
        if state[side + "_bytes"] > len(data):
            notes.append(side + " 正文仅保留部分内容（单正文 1 MB / 全局预览预算）")
        encoding = message.headers.get("content-encoding", "").lower().strip() if message else ""
        if encoding in ("gzip", "deflate") and data:
            try:
                decoded = zlib.decompressobj(31 if encoding == "gzip" else 15).decompress(data, BODY_LIMIT + 1)
                if len(decoded) > BODY_LIMIT:
                    notes.append(side + " 解压正文超过 1 MB，仅保留前缀")
                data = decoded[:BODY_LIMIT]
            except zlib.error:
                notes.append(side + " 压缩正文不完整，保留压缩原文")
        elif encoding and encoding != "identity":
            notes.append(side + " Content-Encoding=" + limited_text(encoding, 64) + "，保留压缩原文")
        return base64.b64encode(data).decode("ascii"), notes

    def report(self, flow, complete):
        request, response = flow.request, flow.response
        state = flow.metadata.get("runbar_capture")
        if state is None:
            return
        req, resp, notes = None, None, []
        if complete:
            req, req_notes = self.body(state, "request", request)
            resp, resp_notes = self.body(state, "response", response)
            notes = req_notes + resp_notes
        error = limited_text(flow.error.msg, 2048) if flow.error else None
        self.emit({"type": "http", "record": {
            "flowID": flow.id, "method": limited_text(request.method, 64), "url": limited_text(request.pretty_url, 16_384),
            "startMicros": micros(request.timestamp_start),
            "endMicros": micros(response.timestamp_end) if complete and response and response.timestamp_end else (micros() if complete else None),
            "status": response.status_code if response else None,
            "contentType": limited_text(response.headers.get("content-type", ""), 1024) if response else "",
            "requestHeaders": headers(request.headers), "responseHeaders": headers(response.headers if response else None),
            "requestBytes": state["request_bytes"], "responseBytes": state["response_bytes"],
            "requestBody": req, "responseBody": resp, "complete": complete, "failure": error, "note": "; ".join(notes)}})
        if complete and not state["released"]:
            self.preview_bytes -= len(state["request"]) + len(state["response"])
            state["request"].clear(); state["response"].clear()
            if state["accepted"]:
                self.active_previews -= 1
            state["released"] = True

    def http_connected(self, flow):
        if not self.decrypt_tls:
            self.tunnel(flow)

    def http_connect_error(self, flow):
        self.tunnel(flow, failure="CONNECT 隧道建立失败")

    def tunnel(self, flow, failure=None):
        request = flow.request
        self.emit({"type": "http", "record": {
            "flowID": flow.id, "method": "CONNECT", "url": limited_text("https://" + request.authority, 16_384),
            "startMicros": micros(request.timestamp_start), "endMicros": micros(), "status": None if failure else 200,
            "contentType": "", "requestHeaders": headers(request.headers), "responseHeaders": "{}",
            "requestBytes": 0, "responseBytes": 0, "requestBody": None, "responseBody": None,
            "complete": True, "failure": failure,
            "note": "TLS 透传，仅记录 CONNECT 隧道；状态不是源站 HTTP 响应，无法查看 HTTPS 正文或 WSS 消息。"}})

    def websocket_start(self, flow):
        self.socket_event(flow, "open")

    def websocket_message(self, flow):
        message = flow.websocket.messages[-1]
        self.socket_event(flow, "send" if message.from_client else "receive", message)
        # mitmproxy forwards its local `message` object after the hook; clearing
        # history does not mutate that object's content or dropped flag.
        flow.websocket.messages.clear()

    def websocket_end(self, flow):
        self.socket_event(flow, "close")
        flow.websocket.messages.clear()

    def socket_event(self, flow, kind, message=None):
        self.sequence += 1
        data = message.content if message else b""
        note = "消息超过 1 MB，仅保留前缀" if len(data) > BODY_LIMIT else ""
        if kind == "close":
            note = limited_text(flow.websocket.close_reason or "", 2048)
        url = flow.request.pretty_url
        if url.startswith("https://"):
            url = "wss://" + url[8:]
        elif url.startswith("http://"):
            url = "ws://" + url[7:]
        self.emit({"type": "websocket", "socket": {
            "id": self.sequence, "flowID": flow.id, "url": limited_text(url, 16_384),
            "timestamp": micros(message.timestamp) if message else micros(), "kind": kind,
            "opcode": int(message.type) if message else 0, "bytes": len(data),
            "payload": base64.b64encode(data[:BODY_LIMIT]).decode("ascii"), "note": note,
            "closeCode": flow.websocket.close_code if kind == "close" else None,
            "requestHeaders": headers(flow.request.headers) if kind == "open" else None,
            "responseHeaders": headers(flow.response.headers) if kind == "open" and flow.response else None}})


addons = [Capture()]
