"""Loopback-only HTTP fixture for actual interrupted/ranged URLSession I/O."""
import http.server
import threading
import time
from urllib.parse import urlsplit

counts = {}
lock = threading.Lock()

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        route = urlsplit(self.path).path
        with lock:
            count = counts.get(self.path, 0)
            counts[self.path] = count + 1
        if route == '/cancel':
            data = b'01234567' * 262144
            offset = int(self.headers.get('Range', 'bytes=0-')[6:-1])
            self.send_response(206 if offset else 200)
            self.send_header('Content-Length', str(len(data) - offset))
            self.send_header('ETag', '"cancel-v1"')
            if offset:
                self.send_header('Content-Range', f'bytes {offset}-{len(data)-1}/{len(data)}')
            self.end_headers()
            try:
                for index in range(offset, len(data), 65536):
                    self.wfile.write(data[index:index+65536]); self.wfile.flush()
                    time.sleep(0.01 if not offset else 0)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        data = b'01234567' * 131072
        partial = 327680
        if count == 0:
            self.send_response(200)
            self.send_header('Content-Length', str(len(data))); self.send_header('ETag', '"v1"')
            self.end_headers(); self.wfile.write(data[:partial]); self.wfile.flush()
            time.sleep(0.05); self.close_connection = True
            return
        if route == '/changed':
            self.send_response(200); self.send_header('Content-Length', '4'); self.send_header('ETag', '"v2"')
            self.end_headers(); self.wfile.write(b'NEW!'); return
        offset = partial - 1 if route == '/wrong-range' else partial
        if self.headers.get('Range') != f'bytes={partial}-' or self.headers.get('If-Range') != '"v1"':
            self.send_error(400); return
        self.send_response(206)
        self.send_header('Content-Length', str(len(data)-offset)); self.send_header('ETag', '"v1"')
        self.send_header('Content-Range', f'bytes {offset}-{len(data)-1}/{len(data)}')
        self.end_headers(); self.wfile.write(data[offset:])

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
