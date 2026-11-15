"""Lossless rewrite tests and real bundled-proxy integration using local peers.

python3 macos/scripts/test-response-rewrite.py [--unit-only]
No system proxy, certificate trust, or business application is modified.
"""
import argparse
import base64
import concurrent.futures
import gzip
import http.client
import json
import os
import platform
import re
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Resources/ProxyCapture"))
from runbar_rewrite import BODY_LIMIT, JSONDocument, RewriteError, Rule, Settings, bounded_decode, equal, path_parts, subset

RULE_ID = "AE378BD9-2C98-4B89-AE8B-CF92DF51AF41"
SAMPLE = b'{"code":0,"body":{"isClearing":false,"untouched":false,"precise":9007199254740993,"decimal":1.234567890123456789,"symbols":[["code","name","' + "清盘中".encode() + b'","open"],' + b','.join(
    ('["%06d","%s",false,false]' % (600000 + i, "浦发银行" if i == 0 else "测试股票")).encode() for i in range(40)) + b']}}'


def rule(**updates):
    value = {"id": RULE_ID, "name": "模拟清盘中", "notes": "验证原值与高亮", "enabled": True,
             "method": "POST", "urlMode": "contains", "urlPattern": "/", "requestJSON": '{"blocks":[2000]}',
             "queryJSON": "", "requestConditions": [], "actions": [
                 {"id": str(uuid.uuid4()), "kind": "table", "path": "$.body.symbols", "column": "清盘中",
                  "headerRow": 0, "rowConditionsJSON": "", "valueJSON": "true"}]}
    value.update(updates)
    return value


def action(path="$.body.isClearing", value="true"):
    return {"id": str(uuid.uuid4()), "kind": "json", "path": path, "valueJSON": value}


class RewriteTests(unittest.TestCase):
    def test_realistic_table_changes_only_40_target_tokens(self):
        output, changes = Rule(rule(), 1).apply(SAMPLE)
        self.assertEqual(len(changes), 40)
        expected = SAMPLE.replace(b',false,false]', b',true,false]')
        self.assertEqual(output, expected)
        self.assertEqual(changes[0]["path"], '$["body"]["symbols"][1][2]')
        self.assertEqual(changes[0]["originalJSON"], "false")
        self.assertEqual(changes[0]["replacementJSON"], "true")

    def test_types_subset_array_equality_and_contains(self):
        compiled = Rule(rule(), 1)
        self.assertTrue(compiled.matches_body(JSONDocument('{"blocks":[2000],"count":40}')))
        for value in ['{"blocks":["2000"]}', '{"blocks":[2000,2001]}', '{"blocks":[true]}', '{}']:
            self.assertFalse(compiled.matches_body(JSONDocument(value)))
        compiled = Rule(rule(requestJSON="", requestConditions=[{"path": "$.blocks", "operation": "contains", "valueJSON": "2000"}]), 1)
        self.assertTrue(compiled.matches_body(JSONDocument('{"blocks":[2000,2001]}')))
        self.assertFalse(equal(JSONDocument("true").root, JSONDocument("1").root))
        self.assertTrue(equal(JSONDocument("1.0000").root, JSONDocument("1e0").root))

    def test_url_and_query_sources(self):
        compiled = Rule(rule(method="GET", urlMode="path", urlPattern="/quotes", queryJSON='{"tag":["a","b"],"name":"hello world"}', requestJSON=""), 1)
        self.assertTrue(compiled.matches_headers("GET", "https://example.invalid/quotes?tag=a&tag=b&name=hello+world&count=40"))
        self.assertFalse(compiled.matches_headers("POST", "https://example.invalid/quotes?tag=a&tag=b&name=hello+world"))
        with self.assertRaises(RewriteError):
            Rule(rule(queryJSON='{"count":40}'), 1)

    def test_header_reordering_and_row_filter(self):
        data = '{"body":{"symbols":[["清盘中","code"],[false,"600000"],[false,"600004"]]}}'.encode()
        selected = rule()
        selected["actions"][0]["rowConditionsJSON"] = '{"code":"600000"}'
        output, changes = Rule(selected, 1).apply(data)
        self.assertEqual(len(changes), 1)
        self.assertEqual(changes[0]["path"], '$["body"]["symbols"][1][0]')
        self.assertEqual(output, data.replace(b'[false,"600000"]', b'[true,"600000"]'))

    def test_json_wildcards_escaped_keys_and_unicode(self):
        data = '{"a.b":{"😀":[{"x":false,"same":false},{"x":false}]}}'.encode()
        compiled = Rule(rule(actions=[action('$["a.b"]["😀"][*].x')]), 1)
        output, changes = compiled.apply(data)
        self.assertEqual(output, data.replace(b'"x":false', b'"x":true'))
        self.assertEqual(len(changes), 2)
        self.assertEqual(JSONDocument('"\\ud83d\\ude00"').root.value, "😀")

    def test_invalid_and_overlapping_targets_are_atomic(self):
        compiled = Rule(rule(actions=[action(), action("$.body.untouched"), action("$.missing")]), 1)
        with self.assertRaises(RewriteError):
            compiled.apply(SAMPLE)
        for actions in [[action(), action()], [action("$.body", "{}"), action()]]:
            with self.assertRaisesRegex(RewriteError, "重叠"):
                Rule(rule(actions=actions), 1).apply(SAMPLE)
        for data in [b'{"x":1,"x":2}', b'{"x":NaN}', b'[1,]', b'{"x":1}trailing', b'"bad\x01"', b'\xff', b'"\\ud800"']:
            with self.assertRaises(RewriteError):
                JSONDocument(data)

    def test_no_change_empty_selection_and_missing_header(self):
        output, changes = Rule(rule(actions=[action(value="false")]), 1).apply(SAMPLE)
        self.assertEqual(output, SAMPLE)
        self.assertFalse(changes)
        output, changes = Rule(rule(actions=[action("$.items[*].x")]), 1).apply(b'{"items":[]}')
        self.assertFalse(changes)
        with self.assertRaises(RewriteError):
            Rule(rule(), 1).apply(b'{"body":{"symbols":[["code"],["600000"]]}}')

    def test_compression_limits_and_precision(self):
        for encoded, coding in [(gzip.compress(SAMPLE), "gzip"), (zlib.compress(SAMPLE), "deflate")]:
            self.assertEqual(bounded_decode(encoded, coding), SAMPLE)
        with self.assertRaises(RewriteError):
            bounded_decode(gzip.compress(b"x" * (BODY_LIMIT + 1)), "gzip")
        with self.assertRaises(RewriteError):
            bounded_decode(gzip.compress(SAMPLE)[:-3], "gzip")
        original = b'{"n":1.234567890123456789,"big":9007199254740993,"flag":false}'
        output, changes = Rule(rule(actions=[action("$.flag")]), 1).apply(original)
        self.assertEqual(output, original.replace(b'"flag":false', b'"flag":true'))

    def test_settings_snapshots_and_invalid_config(self):
        snapshot = Settings({"schemaVersion": 1, "revision": 3, "enabled": True, "rules": [rule()]})
        self.assertEqual(snapshot.candidates("POST", "http://localhost/quotes")[0].revision, 3)
        with self.assertRaises(RewriteError):
            Settings({"schemaVersion": 1, "revision": 4, "enabled": True, "rules": [rule(), rule()]})


def until(predicate, message="condition", timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.025)
    raise AssertionError("Timed out: " + message)


def integration(sample_only=False):
    engine = Path(os.environ.get("RUNBAR_TEST_MITMDUMP", str(ROOT / (".build/proxy-engine-cache/12.3.1/" + platform.machine() + "/mitmproxy.app/Contents/MacOS/mitmdump"))))
    if not engine.is_file():
        raise AssertionError("Bundled mitmdump is unavailable: " + str(engine))
    with tempfile.TemporaryDirectory(prefix="runbar-rewrite-test-") as temporary:
        directory = Path(temporary)
        control = directory / "control"
        control.mkdir()
        artifacts = directory / "rewrite"
        events, diagnostics = [], []
        latch = threading.Event()
        arrivals = []
        large = b'{"padding":"' + b"x" * BODY_LIMIT + b'","isClearing":false}'

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):
                pass

            def do_POST(self):
                self.serve()

            def do_GET(self):
                self.serve()

            def serve(self):
                self.rfile.read(int(self.headers.get("Content-Length", "0")))
                if self.path.startswith("/held"):
                    arrivals.append(self.path)
                    latch.wait(15)
                raw = large if self.path.startswith("/large") or self.path.startswith("/gzip-bomb") else SAMPLE
                if self.path.startswith("/invalid"):
                    raw = b'{"broken":}'
                encoding = None
                if self.path.startswith("/gzip"):
                    raw, encoding = gzip.compress(raw), "gzip"
                elif self.path.startswith("/deflate"):
                    raw, encoding = zlib.compress(raw), "deflate"
                chunked = "chunked" in self.path
                self.send_response(200)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("ETag", '"original-tag"')
                self.send_header("Content-MD5", "original-digest")
                if encoding:
                    self.send_header("Content-Encoding", encoding)
                self.send_header("Connection", "close")
                self.send_header("Transfer-Encoding", "chunked") if chunked else self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                if self.path.startswith("/abort"):
                    self.wfile.write(raw[:32])
                    self.wfile.flush()
                    self.connection.shutdown(socket.SHUT_WR)
                    self.close_connection = True
                    return
                if chunked:
                    for index in range(0, len(raw), 16_384):
                        chunk = raw[index:index + 16_384]
                        self.wfile.write(("%x\r\n" % len(chunk)).encode() + chunk + b"\r\n")
                        self.wfile.flush()
                    self.wfile.write(b"0\r\n\r\n")
                else:
                    self.wfile.write(raw)
                self.close_connection = True

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        cert = directory / "server-cert.pem"
        key = directory / "server-key.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1", "-keyout", str(key), "-out", str(cert)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        tls_server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        server_context.load_cert_chain(str(cert), str(key))
        tls_server.socket = server_context.wrap_socket(tls_server.socket, server_side=True)
        threading.Thread(target=tls_server.serve_forever, daemon=True).start()

        def write_rules(revision, rules, enabled=True):
            path = control / "rewrite-rules.json"
            temporary = path.with_suffix(".tmp")
            temporary.write_text(json.dumps({"schemaVersion": 1, "revision": revision, "enabled": enabled, "rules": rules}), encoding="utf-8")
            temporary.replace(path)

        write_rules(1, [rule()])
        process = subprocess.Popen([str(engine), "--quiet", "--listen-host", "127.0.0.1", "--listen-port", "0", "--set", "stream_large_bodies=1m", "--set", "confdir=" + str(directory / "cert"), "--set", "ssl_verify_upstream_trusted_ca=" + str(cert), "-s", str(ROOT / "Resources/ProxyCapture/runbar_capture.py")], env={**os.environ, "RUNBAR_PROXY_CONTROL": str(control), "RUNBAR_PROXY_REWRITE_DIRECTORY": str(artifacts), "RUNBAR_PROXY_DECRYPT_TLS": "1"}, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

        def read_events():
            for line in process.stdout:
                if line.startswith(b"RUNBAR_CAPTURE_V1 "):
                    events.append(json.loads(line.split(b" ", 1)[1]))
                else:
                    diagnostics.append(line.decode("utf-8", "replace"))

        def read_errors():
            for line in process.stderr:
                diagnostics.append(line.decode("utf-8", "replace"))

        threading.Thread(target=read_events, daemon=True).start()
        threading.Thread(target=read_errors, daemon=True).start()
        try:
            ready = until(lambda: next((item for item in events if item["type"] == "ready"), None) or (process.poll() is not None and (_ for _ in ()).throw(AssertionError("Proxy exited: " + "".join(diagnostics)))), "proxy ready")
            proxy_port = ready["port"]

            def ack(revision):
                path = control / "rewrite-ack.json"
                def loaded():
                    if not path.exists():
                        return None
                    value = json.loads(path.read_text())
                    return value if value["revision"] == revision else None
                return until(loaded, "rules revision " + str(revision))

            assert ack(1)["error"] is None

            def request(path, blocks=None, method="POST", secure=False, raw_body=None):
                identifier = str(uuid.uuid4())
                path += ("&" if "?" in path else "?") + "testID=" + identifier
                if secure:
                    context = ssl.create_default_context(cafile=str(directory / "cert/mitmproxy-ca-cert.pem"))
                    connection = http.client.HTTPSConnection("127.0.0.1", proxy_port, timeout=25, context=context)
                    connection.set_tunnel("localhost", tls_server.server_port)
                    target = path
                else:
                    connection = http.client.HTTPConnection("127.0.0.1", proxy_port, timeout=25)
                    target = "http://127.0.0.1:%d%s" % (server.server_port, path)
                body = json.dumps({"blocks": [2000] if blocks is None else blocks, "count": 40}).encode() if method == "POST" else None
                if raw_body is not None:
                    body = raw_body
                connection.request(method, target, body=body, headers={"Content-Type": "application/json"})
                response = connection.getresponse()
                payload = response.read()
                response_headers = dict(response.getheaders())
                connection.close()
                record = until(lambda: next((item["record"] for item in events if item["type"] == "http" and item["record"]["complete"] and identifier in item["record"]["url"]), None), "captured response")
                encoding = response_headers.get("Content-Encoding", "").lower()
                decoded = gzip.decompress(payload) if encoding == "gzip" else zlib.decompress(payload) if encoding == "deflate" else payload
                return decoded, response_headers, record

            expected = re.sub(rb'(?<=,)(\s*)false(?=\s*,\s*false\s*\])', lambda match: match.group(1) + b"true", SAMPLE)
            original_json, expected_json = json.loads(SAMPLE), json.loads(expected)
            header = original_json["body"]["symbols"][0]
            column = header.index("清盘中")
            intended = json.loads(SAMPLE)
            for row in intended["body"]["symbols"][1:]:
                row[column] = True
            assert expected_json == intended
            for path, secure in [("/quotes", False), ("/chunked", False), ("/gzip", False), ("/deflate", False), ("/quotes", True)]:
                payload, response_headers, record = request(path, secure=secure)
                assert payload == expected, path
                assert record["rewrite"]["state"] == "changed" and record["rewrite"]["count"] == 40
                assert "ETag" not in response_headers and "Content-MD5" not in response_headers
                artifact = json.loads((artifacts / (record["rewrite"]["artifactID"] + ".json")).read_text())
                assert base64.b64decode(artifact["originalBody"]) == SAMPLE
                assert len(artifact["changes"]) == 40
                assert base64.b64decode(record["responseBody"]) == expected
            print("PASS integration: HTTP, HTTPS, chunked, gzip, deflate; 40 values changed; original artifacts and precision intact")
            if sample_only:
                print("PASS supplied sample: all 40 清盘中 cells changed; all other original bytes remain identical")
                return

            for blocks in [[3000], [2000, 2001], ["2000"]]:
                payload, response_headers, record = request("/quotes", blocks=blocks)
                assert payload == SAMPLE and record.get("rewrite") is None
                assert response_headers["ETag"] == '"original-tag"'
            for path in ["/large", "/large-chunked", "/gzip-bomb", "/invalid"]:
                payload, response_headers, record = request(path)
                assert payload == (b'{"broken":}' if path == "/invalid" else large)
                assert record["rewrite"]["state"] == "skipped", (path, record)
                assert response_headers["ETag"] == '"original-tag"'
            print("PASS integration: typed request matching, large known/chunked, decompression limit, invalid JSON all pass through unchanged")
            _, _, record = request("/abort")
            assert record["failure"] and record["rewrite"]["state"] == "skipped"
            assert record["responseBody"] is None and record["responseBytes"] == -1
            assert "artifactID" not in record["rewrite"]
            print("PASS integration: interrupted upstream body never becomes an empty complete response or a successful rewrite")

            backup = directory / "rewrite-backup"
            artifacts.rename(backup)
            artifacts.write_text("blocked")
            payload, response_headers, record = request("/quotes")
            assert payload == SAMPLE and record["rewrite"]["state"] == "skipped"
            assert response_headers["ETag"] == '"original-tag"'
            artifacts.unlink()
            backup.rename(artifacts)

            with concurrent.futures.ThreadPoolExecutor(max_workers=9) as executor:
                running = [executor.submit(request, "/held") for _ in range(8)]
                until(lambda: len(arrivals) == 8, "eight pending candidates")
                payload, _, record = request("/quotes")
                assert payload == SAMPLE and "8" in record["rewrite"]["reason"]
                replacement = rule(name="更新后的规则")
                replacement["actions"][0]["valueJSON"] = "false"
                write_rules(2, [replacement])
                assert ack(2)["error"] is None
                latch.set()
                for pending in running:
                    payload, _, record = pending.result(timeout=25)
                    assert payload == expected and record["rewrite"]["revision"] == 1
                payload, _, record = request("/quotes")
                assert payload == SAMPLE and record["rewrite"]["state"] == "unchanged" and record["rewrite"]["revision"] == 2
            print("PASS integration: audit write failure preserves response; eight-candidate bound; in-flight rules stay frozen; hot update acknowledged")

            invalid_rule = rule(name="")
            write_rules(3, [invalid_rule])
            assert ack(3)["error"]
            payload, _, record = request("/quotes")
            assert payload == SAMPLE and record["rewrite"]["revision"] == 2
            write_rules(4, [replacement], enabled=False)
            assert ack(4)["error"] is None
            payload, _, record = request("/quotes")
            assert payload == SAMPLE and record.get("rewrite") is None
            print("PASS integration: malformed update keeps previous rules; project switch disables rewriting")

            upload = b'{"blocks":[2000],"padding":"' + b"x" * BODY_LIMIT + b'"}'
            write_rules(5, [rule(requestJSON="")])
            assert ack(5)["error"] is None
            payload, _, record = request("/quotes", raw_body=upload)
            assert payload == expected and record["rewrite"]["state"] == "changed"
            assert record["requestBody"] is not None and record["responseBody"] is not None
            assert "部分" in record["note"]
            write_rules(6, [rule()])
            assert ack(6)["error"] is None
            payload, _, record = request("/quotes", raw_body=upload)
            assert payload == SAMPLE and record["rewrite"]["state"] == "skipped"
            assert "请求正文" in record["rewrite"]["reason"]

            first = rule(actions=[action("$.missing")])
            second = rule(id=str(uuid.uuid4()))
            write_rules(7, [first, second])
            assert ack(7)["error"] is None
            payload, _, record = request("/quotes")
            assert payload == SAMPLE and record["rewrite"]["state"] == "skipped"
            assert record["rewrite"]["ruleID"] == RULE_ID

            query_rule = rule(method="GET", requestJSON="", queryJSON='{"tag":["a","b"]}', actions=[action(), action("$.body.untouched")])
            write_rules(8, [query_rule])
            assert ack(8)["error"] is None
            payload, _, record = request("/quotes?tag=a&tag=b", method="GET")
            assert payload == SAMPLE.replace(b'"isClearing":false', b'"isClearing":true').replace(b'"untouched":false', b'"untouched":true')
            assert record["rewrite"]["count"] == 2
            print("PASS integration: URL-only rewrite preserves oversized upload preview; partial request never matches JSON conditions; first match is exclusive; query source and multiple actions")
        except Exception:
            print("Proxy diagnostics:\n" + "".join(diagnostics), file=sys.stderr)
            raise
        finally:
            latch.set()
            process.terminate()
            process.wait(timeout=10)
            server.shutdown()
            tls_server.shutdown()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--unit-only", action="store_true")
    parser.add_argument("--sample", type=Path, help="Also use this supplied 40-row response for the real proxy smoke test")
    arguments = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(RewriteTests))
    if not result.wasSuccessful():
        raise SystemExit(1)
    if not arguments.unit_only:
        if arguments.sample:
            SAMPLE = arguments.sample.read_bytes()
        integration(sample_only=arguments.sample is not None)
