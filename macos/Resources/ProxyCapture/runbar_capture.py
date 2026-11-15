"""Runbar's mitmdump addon (mitmproxy >= 10).

Unmatched HTTP traffic is streamed unchanged. Explicit project rules may buffer
and rewrite a bounded JSON response before it is sent. WebSocket injection is
available only through explicit user commands; completed messages are released.
"""
import asyncio
import base64
import collections
import json
import os
import sys
import threading
import time
import zlib
from pathlib import Path

from mitmproxy import ctx

# mitmdump loads addons by filename; the sibling module is bundled with this one.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from runbar_rewrite import JSONDocument, RewriteError, Settings, bounded_decode, bounded_encode, save_artifact

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
        self.flows = {}
        self.control = Path(os.environ["RUNBAR_PROXY_CONTROL"]) if os.environ.get("RUNBAR_PROXY_CONTROL") else None
        self.decrypt_tls = os.environ.get("RUNBAR_PROXY_DECRYPT_TLS") == "1"
        rewrite_path = os.environ.get("RUNBAR_PROXY_REWRITE_DIRECTORY")
        self.rewrite_directory = Path(rewrite_path) if rewrite_path else (self.control.parent / "rewrite" if self.control else None)
        self.rewrite_settings = Settings()
        self.rewrite_signature = None
        self.active_rewrites = 0
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
        if self.control:
            self.control.mkdir(mode=0o700, parents=True, exist_ok=True)
            self.reload_rewrite_rules()
            self.publish_connections()
            self.commands = asyncio.create_task(self.watch_commands())
        self.emit({"type": "ready", "port": ports[0]})
        self.watchdog = asyncio.create_task(self.watch_parent())

    def reload_rewrite_rules(self):
        path = self.control / "rewrite-rules.json"
        revision = self.rewrite_settings.revision
        try:
            stat = path.stat()
            signature = (stat.st_mtime_ns, stat.st_size)
            if signature == self.rewrite_signature:
                return
            self.rewrite_signature = signature
            if stat.st_size > BODY_LIMIT:
                raise RewriteError("规则配置超过 1 MB")
            with path.open("rb") as handle:
                data = handle.read(BODY_LIMIT + 1)
            if len(data) > BODY_LIMIT:
                raise RewriteError("规则配置超过 1 MB")
            value = json.loads(data)
            revision = value.get("revision", revision)
            replacement = Settings(value)
            self.rewrite_settings = replacement
            reply = {"revision": replacement.revision, "error": None}
        except FileNotFoundError:
            return
        except Exception as error:
            reply = {"revision": revision, "error": limited_text(error, 2048)}
        try:
            ack = self.control / "rewrite-ack.json"
            temporary = ack.with_suffix(".tmp")
            temporary.write_text(json.dumps(reply, ensure_ascii=True), encoding="utf-8")
            os.chmod(temporary, 0o600)
            temporary.replace(ack)
        except OSError as error:
            self.emit({"type": "warning", "issue": "rewrite", "message": "无法保存改写配置回执：" + limited_text(error, 1024)})

    def publish_connections(self):
        if self.control:
            path = self.control / "connections.json"
            temporary = path.with_suffix(".tmp")
            temporary.write_text(json.dumps([{"id": f.id, "url": self.socket_url(f)} for f in self.flows.values()]))
            temporary.replace(path)

    async def watch_commands(self):
        while True:
            await asyncio.sleep(0.1)
            self.reload_rewrite_rules()
            for path in list(self.control.glob("*.request"))[:16]:
                response = {"error": "发送失败"}
                try:
                    if path.stat().st_size > BODY_LIMIT * 6 + 4096:
                        raise ValueError("消息超过 1 MB")
                    command = json.loads(path.read_text())
                    if time.time() > command["expires"]:
                        raise ValueError("发送请求已过期")
                    flow = self.flows.get(command["flowID"])
                    if not flow or not flow.live:
                        raise ValueError("连接已断开，请重新选择")
                    content = command["text"].encode("utf-8")
                    if not content or len(content) > BODY_LIMIT:
                        raise ValueError("请输入不超过 1 MB 的消息")
                    ctx.master.commands.call("inject.websocket", flow, False, content, True)
                    response = {"error": None}
                except Exception as error:
                    response = {"error": str(error)}
                finally:
                    path.unlink(missing_ok=True)
                result = path.with_suffix(".response")
                temporary = result.with_suffix(".tmp")
                temporary.write_text(json.dumps(response))
                temporary.replace(result)
            # Remove abandoned replies after a client closes its editor.
            for path in self.control.glob("*.response"):
                if time.time() - path.stat().st_mtime > 30:
                    path.unlink(missing_ok=True)

    async def watch_parent(self):
        while True:
            await asyncio.sleep(1)
            if os.getppid() != self.parent:
                ctx.master.shutdown()
                return

    def done(self):
        if hasattr(self, "watchdog"):
            self.watchdog.cancel()
        if hasattr(self, "commands"):
            self.commands.cancel()
        self.flows.clear()
        self.publish_connections()
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
        try:
            candidates = self.rewrite_settings.candidates(flow.request.method, flow.request.pretty_url)
            if candidates:
                state["rewrite_candidates"] = candidates
                if self.active_rewrites >= 8:
                    state["rewrite"] = candidates[0].summary("skipped", reason="候选请求超过 8 条并发改写上限")
                else:
                    self.active_rewrites += 1
                    state["rewrite_slot"] = True
                    state["rewrite_request"] = bytearray()
                    state["rewrite_request_needed"] = any(rule.needs_body for rule in candidates)
        except Exception as error:
            state["rewrite"] = {"state": "skipped", "count": 0, "reason": limited_text(error, 1024)}
        flow.request.stream = self.tee(state, "request")
        self.report(flow, complete=False)

    def tee(self, state, side):
        def stream(chunk):
            state[side + "_bytes"] += len(chunk)
            if side == "request" and state.get("rewrite_slot") and state.get("rewrite_request_needed"):
                request = state["rewrite_request"]
                request.extend(chunk[:max(0, BODY_LIMIT - len(request))])
            if state["accepted"] and not state["released"]:
                available = max(0, min(BODY_LIMIT - len(state[side]), PREVIEW_BUDGET - self.preview_bytes))
                copied = chunk[:available]
                state[side].extend(copied)
                self.preview_bytes += len(copied)
            return chunk
        return stream

    def request(self, flow):
        state = flow.metadata.get("runbar_capture")
        if state is not None:
            state["request_complete"] = True
            self.select_rewrite(flow, state)

    def release_rewrite(self, state):
        if state.pop("rewrite_slot", False):
            self.active_rewrites -= 1
        state.pop("rewrite_request", None)
        state.pop("rewrite_candidates", None)
        state.pop("rewrite_rule", None)
        state.pop("rewrite_request_needed", None)

    def select_rewrite(self, flow, state):
        if not state.get("rewrite_slot") or state.get("rewrite_rule") or state.get("rewrite"):
            return
        document = None
        parsed = False
        for rule in state.get("rewrite_candidates", ()):
            try:
                if rule.needs_body and not parsed:
                    body = state.get("rewrite_request", b"")
                    if not state.get("request_complete") or flow.request.stream is True or state["request_bytes"] != len(body):
                        raise RewriteError("请求正文未完整采集，无法校验参数")
                    body = bounded_decode(bytes(body), flow.request.headers.get("content-encoding", ""))
                    document = JSONDocument(body)
                    parsed = True
                if rule.matches_body(document):
                    state["rewrite_rule"] = rule
                    state.pop("rewrite_request", None)
                    return
            except Exception as error:
                state["rewrite"] = rule.summary("skipped", reason=limited_text(error, 2048))
                self.release_rewrite(state)
                return
        self.release_rewrite(state)

    def responseheaders(self, flow):
        state = flow.metadata.get("runbar_capture")
        if state is not None:
            self.select_rewrite(flow, state)
            rule = state.get("rewrite_rule")
            if rule and state.get("rewrite_slot"):
                reason = None
                response = flow.response
                if flow.request.method == "HEAD" or response.status_code < 200 or response.status_code in (204, 206, 304):
                    reason = "该响应没有可改写的完整 JSON 正文"
                elif "text/event-stream" in response.headers.get("content-type", "").lower():
                    reason = "流式事件响应不执行 JSON 改写"
                elif response.headers.get("content-encoding", "identity").strip().lower() not in ("", "identity", "gzip", "deflate"):
                    reason = "不支持该响应的压缩编码"
                else:
                    try:
                        length = int(response.headers.get("content-length", "-1"))
                    except ValueError:
                        length = -1
                    if length > BODY_LIMIT:
                        reason = "响应正文超过 1 MB 改写上限"
                if reason:
                    state["rewrite"] = rule.summary("skipped", reason=reason)
                    self.release_rewrite(state)
                else:
                    state["rewrite_buffered"] = True
                    response.stream = False
                    return
            flow.response.stream = self.tee(state, "response")

    async def response(self, flow):
        state = flow.metadata.get("runbar_capture")
        if state is None:
            return
        try:
            if state.get("rewrite_buffered"):
                rule = state["rewrite_rule"]
                response = flow.response
                raw = response.raw_content
                if raw is None or response.stream is True:
                    state["rewrite"] = rule.summary("skipped", reason="响应正文超过 1 MB，已原样透传；正文未完整缓存")
                    state["response_unavailable"] = True
                    state["response_bytes"] = -1
                else:
                    state["response_bytes"] = len(raw)
                    encoding = response.headers.get("content-encoding", "")
                    original_headers = response.headers.copy()
                    artifact_id = None
                    try:
                        original = bounded_decode(raw, encoding)
                        state["response_override"] = original
                        rewritten, changes = rule.apply(original)
                        if not changes:
                            state["rewrite"] = rule.summary("unchanged")
                        else:
                            encoded = bounded_encode(rewritten, encoding)
                            if self.rewrite_directory is None:
                                raise RewriteError("改写记录目录不可用")
                            artifact_id = await asyncio.to_thread(save_artifact, self.rewrite_directory, rule, original, headers(response.headers), changes)
                            # No response headers/body have left the proxy yet.
                            # Audit data is saved before changing what is sent.
                            response.raw_content = encoded
                            if "transfer-encoding" in response.headers:
                                response.headers.pop("content-length", None)
                            else:
                                response.headers["content-length"] = str(len(encoded))
                            for field in ("etag", "content-md5", "digest", "content-digest", "repr-digest"):
                                response.headers.pop(field, None)
                            state["response_override"] = rewritten
                            state["response_bytes"] = len(encoded)
                            state["rewrite"] = rule.summary("changed", len(changes), artifact_id=artifact_id)
                    except Exception as error:
                        response.raw_content = raw
                        response.headers = original_headers
                        state["response_bytes"] = len(raw)
                        if artifact_id:
                            try:
                                (self.rewrite_directory / (artifact_id + ".json")).unlink(missing_ok=True)
                            except OSError:
                                pass
                        state["rewrite"] = rule.summary("skipped", reason=limited_text(error, 2048))
                        if "response_override" not in state:
                            # The original encoded body remains intact even if
                            # bounded decompression or parsing is unavailable.
                            state["response_raw_override"] = raw
            elif flow.response.stream is True:
                # stream_large_bodies can take over a tee for an unknown-length
                # response. Never label the missing tail as a complete payload.
                state["response_unavailable"] = True
                state["response_bytes"] = -1
            self.report(flow, complete=True)
        finally:
            self.release_rewrite(state)

    def error(self, flow):
        state = flow.metadata.get("runbar_capture")
        if state:
            if state.get("rewrite_buffered"):
                state["response_unavailable"] = True
                state["response_bytes"] = -1
            if state.get("rewrite_rule") and not state.get("rewrite"):
                state["rewrite"] = state["rewrite_rule"].summary("skipped", reason="请求未完成，未执行响应改写")
            self.release_rewrite(state)
        self.report(flow, complete=True)

    def body(self, state, side, message):
        if state.get(side + "_unavailable"):
            if side == "request":
                # Keep the independent response readable even if an oversized
                # upload could only be sampled. This prefix is never matched.
                return base64.b64encode(bytes(state[side])).decode("ascii"), ["request 仅有已采集的部分正文，字节总数未知"]
            return None, [side + " 正文超限或未完整采集，字节总数未知"]
        if side + "_override" in state:
            return base64.b64encode(state[side + "_override"]).decode("ascii"), []
        data = state.get(side + "_raw_override", bytes(state[side]))
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
            if flow.request.stream is True:
                state["request_unavailable"] = True
                state["request_bytes"] = -1
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
            "requestBody": req, "responseBody": resp, "complete": complete, "failure": error, "note": "; ".join(notes),
            "rewrite": state.get("rewrite")}})
        if complete and not state["released"]:
            self.preview_bytes -= len(state["request"]) + len(state["response"])
            state["request"].clear(); state["response"].clear()
            if state["accepted"]:
                self.active_previews -= 1
            state["released"] = True
            state.pop("response_override", None)
            state.pop("response_raw_override", None)

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
        self.flows[flow.id] = flow
        self.publish_connections()
        self.socket_event(flow, "open")

    def websocket_message(self, flow):
        message = flow.websocket.messages[-1]
        self.socket_event(flow, "send" if message.from_client else "receive", message)
        # mitmproxy forwards its local `message` object after the hook; clearing
        # history does not mutate that object's content or dropped flag.
        flow.websocket.messages.clear()

    def websocket_end(self, flow):
        self.flows.pop(flow.id, None)
        self.publish_connections()
        self.socket_event(flow, "close")
        flow.websocket.messages.clear()

    @staticmethod
    def socket_url(flow):
        url = flow.request.pretty_url
        if url.startswith("https://"):
            url = "wss://" + url[8:]
        elif url.startswith("http://"):
            url = "ws://" + url[7:]
        return url

    def socket_event(self, flow, kind, message=None):
        self.sequence += 1
        data = message.content if message else b""
        note = "消息超过 1 MB，仅保留前缀" if len(data) > BODY_LIMIT else ""
        if kind == "close":
            note = limited_text(flow.websocket.close_reason or "", 2048)
        url = self.socket_url(flow)
        self.emit({"type": "websocket", "socket": {
            "id": self.sequence, "flowID": flow.id, "url": limited_text(url, 16_384),
            "timestamp": micros(message.timestamp) if message else micros(), "kind": kind,
            "opcode": int(message.type) if message else 0, "bytes": len(data),
            "payload": base64.b64encode(data[:BODY_LIMIT]).decode("ascii"), "note": note,
            "closeCode": flow.websocket.close_code if kind == "close" else None,
            "requestHeaders": headers(flow.request.headers) if kind == "open" else None,
            "responseHeaders": headers(flow.response.headers) if kind == "open" and flow.response else None}})


addons = [Capture()]
