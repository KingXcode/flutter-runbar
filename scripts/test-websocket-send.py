"""Exercise explicit injection through the real bundled mitmproxy, using a local WS peer."""
import base64
import hashlib
import json
import os
from pathlib import Path
import socket
import platform
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
engine = Path(os.environ.get('RUNBAR_TEST_MITMDUMP', str(ROOT / f'.build/proxy-engine-cache/12.3.1/{platform.machine()}/mitmproxy.app/Contents/MacOS/mitmdump')))

def until(predicate):
    for _ in range(150):
        result = predicate()
        if result:
            return result
        time.sleep(.1)
    raise AssertionError('Timed out')

def headers(peer):
    data = b''
    while b'\r\n\r\n' not in data:
        data += peer.recv(1)
    return data.decode()

def exact(peer, size):
    data = b''
    while len(data) < size:
        chunk = peer.recv(size - len(data))
        assert chunk
        data += chunk
    return data

with tempfile.TemporaryDirectory() as temporary:
    directory = Path(temporary)
    server = socket.socket()
    server.bind(('127.0.0.1', 0))
    server.listen()
    received = []
    def serve():
        peer, _ = server.accept()
        peer.settimeout(15)
        request = headers(peer)
        key = next(line.split(': ', 1)[1] for line in request.split('\r\n') if line.lower().startswith('sec-websocket-key:'))
        accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest())
        peer.sendall(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + b'\r\n\r\n')
        first, length = exact(peer, 2)
        assert first == 0x81 and length & 128
        length &= 127
        mask = exact(peer, 4)
        payload = exact(peer, length)
        received.append(bytes(value ^ mask[index % 4] for index, value in enumerate(payload)))
        peer.sendall(b'\x81' + bytes([length]) + received[0])
        time.sleep(.5)
        peer.close()
    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    process = subprocess.Popen([str(engine), '--quiet', '--listen-host', '127.0.0.1', '--listen-port', '0', '--set', f'confdir={directory / "cert"}', '-s', str(ROOT / 'Resources/ProxyCapture/runbar_capture.py')], env={**os.environ, 'RUNBAR_PROXY_CONTROL': str(directory / 'control')}, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    events = []
    def read():
        for line in process.stdout:
            if line.startswith(b'RUNBAR_CAPTURE_V1 '):
                events.append(json.loads(line.split(b' ', 1)[1]))
    threading.Thread(target=read, daemon=True).start()
    try:
        ready = until(lambda: next((event for event in events if event['type'] == 'ready'), None))
        client = socket.create_connection(('127.0.0.1', ready['port']), timeout=15)
        port = server.getsockname()[1]
        client.sendall(f'GET http://127.0.0.1:{port}/echo HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n'.encode())
        assert '101' in headers(client)
        manifest = directory / 'control/connections.json'
        targets = until(lambda: json.loads(manifest.read_text()))
        def command(name, flow, expires):
            path = directory / f'control/{name}.request'
            temporary_path = path.with_suffix('.tmp')
            temporary_path.write_text(json.dumps({'flowID': flow, 'text': 'hello 世界', 'expires': expires}))
            temporary_path.replace(path)
            reply = path.with_suffix('.response')
            until(reply.exists)
            return json.loads(reply.read_text())
        assert command('expired', targets[0]['id'], 0)['error']
        assert command('missing', 'missing', time.time() + 3)['error']
        assert not received
        assert command('valid', targets[0]['id'], time.time() + 3)['error'] is None
        assert exact(client, 2) == b'\x81\x0c'
        assert exact(client, 12) == 'hello 世界'.encode()
        until(lambda: any(event.get('socket', {}).get('kind') == 'send' for event in events))
        assert received == ['hello 世界'.encode()]
        client.close()
        until(lambda: json.loads(manifest.read_text()) == [])
        print('PASS: UTF-8 text reaches server, echo reaches client, send captured, expired/missing rejected, closed connection removed')
    finally:
        process.terminate()
        process.wait(timeout=10)
        server.close()
