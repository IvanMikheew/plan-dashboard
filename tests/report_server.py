# HTTP-endpoint for tests/harness.html: receives the JSON report (POST /report)
# and writes it to tests/last-report.json. Started by tests/run_harness.ps1.
# Usage: python report_server.py [port]
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'last-report.json')
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8078


class Handler(BaseHTTPRequestHandler):
    def _cors(self):
        self.send_header('Access-Control-Allow-Origin', '*')

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.send_header('Access-Control-Allow-Methods', 'POST, GET, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()

    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        body = self.rfile.read(n)
        if self.path.startswith('/report'):
            with open(OUT, 'wb') as f:
                f.write(body)
            self.send_response(200)
            self._cors()
            self.end_headers()
            self.wfile.write(b'ok')
        else:
            self.send_response(404)
            self.end_headers()

    def do_GET(self):
        self.send_response(200)
        self._cors()
        self.end_headers()
        self.wfile.write(b'ok')

    def log_message(self, *args):
        pass


HTTPServer(('127.0.0.1', PORT), Handler).serve_forever()
