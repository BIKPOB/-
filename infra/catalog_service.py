#!/usr/bin/env python3
"""Optional self-hosted VPN Gate catalog cache. Python standard library only.

No account credentials, traffic proxying or VPN tunneling happen in this service.
Clients validate downloaded profiles independently before invoking OpenVPN.
"""
from __future__ import annotations
import argparse
import base64
import csv
import io
import ipaddress
import json
import logging
import os
from pathlib import Path
import random
import re
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SOURCE = 'https://www.vpngate.net/api/iphone/'
MAX_BODY = 12 * 1024 * 1024
TTL = 15 * 60
MAX_STALE = 24 * 60 * 60


def inspect_catalog(data: bytes) -> dict:
    if len(data) > MAX_BODY:
        raise ValueError('catalog too large')
    text = data.decode('utf-8-sig')
    lines = text.splitlines()
    start = next((i for i, line in enumerate(lines) if line.startswith('#HostName,')), None)
    if start is None:
        raise ValueError('missing VPN Gate header')
    end = next((i for i in range(start + 1, len(lines)) if lines[i].strip() == '*'), len(lines))
    reader = csv.DictReader(io.StringIO('\n'.join([lines[start][1:]] + lines[start + 1:end])))
    needed = {'IP', 'CountryLong', 'CountryShort', 'OpenVPN_ConfigData_Base64'}
    if not needed.issubset(reader.fieldnames or []):
        raise ValueError('missing required fields')
    countries: dict[str, int] = {}
    count = 0
    for n, row in enumerate(reader):
        if n >= 5000:
            raise ValueError('too many records')
        try:
            if not ipaddress.ip_address(row['IP']).is_global:
                continue
            encoded = row['OpenVPN_ConfigData_Base64']
            if not encoded or len(encoded) > 256 * 1024:
                continue
            profile = base64.b64decode(encoded, validate=True).decode('utf-8')
            if len(profile.encode()) > 128 * 1024:
                continue
            remote = re.search(r'^remote\s+([^\s]+)\s+(\d+)\s*$', profile, re.M)
            if not remote or remote.group(1) != row['IP'] or not 1 <= int(remote.group(2)) <= 65535:
                continue
            code = row['CountryShort']
            if not re.fullmatch(r'[A-Z]{2}', code):
                continue
            countries[code] = countries.get(code, 0) + 1
            count += 1
        except (ValueError, TypeError, UnicodeError):
            continue
    if not count:
        raise ValueError('no usable public records')
    return {'records': count, 'countries': countries}


class Snapshot:
    def __init__(self, path: Path | None = None):
        self.path = path
        self.lock = threading.Lock()
        self.body: bytes | None = None
        self.fetched_at = 0.0
        self.stats: dict = {}
        if path and path.exists():
            try:
                payload = json.loads(path.read_text())
                body = base64.b64decode(payload['body'], validate=True)
                self.update(body, float(payload['fetched_at']), persist=False)
            except (ValueError, KeyError, OSError):
                logging.warning('Ignoring invalid catalog cache')

    def update(self, body: bytes, fetched_at: float | None = None, *, persist=True):
        stats = inspect_catalog(body)
        stamp = time.time() if fetched_at is None else fetched_at
        if stamp > time.time() + 300:
            raise ValueError('future cache timestamp')
        if self.path and persist:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            temporary = self.path.with_suffix('.tmp')
            temporary.write_text(json.dumps({'body': base64.b64encode(body).decode(), 'fetched_at': stamp}))
            temporary.replace(self.path)
        with self.lock:
            self.body, self.fetched_at, self.stats = body, stamp, stats

    def read(self):
        with self.lock:
            return self.body, self.fetched_at, self.stats.copy()


def download() -> bytes:
    started = time.monotonic()
    req = urllib.request.Request(SOURCE, headers={'User-Agent': 'QuietVPN-Catalog/0.2'})
    with urllib.request.urlopen(req, timeout=15) as response:
        if response.status != 200 or not response.url.startswith('https://www.vpngate.net/'):
            raise ValueError('unexpected upstream response')
        chunks = bytearray()
        while True:
            if time.monotonic() - started > 30:
                raise TimeoutError('catalog download deadline')
            chunk = response.read(65536)
            if not chunk:
                break
            chunks.extend(chunk)
            if len(chunks) > MAX_BODY:
                raise ValueError('catalog too large')
        return bytes(chunks)


def refresh_loop(snapshot: Snapshot, stop: threading.Event):
    failures = 0
    while not stop.is_set():
        try:
            snapshot.update(download())
            failures = 0
            interval = TTL + random.uniform(0, 60)
            logging.info('Catalog refreshed')
        except Exception as error:
            failures += 1
            interval = min(300, 30 * 2 ** min(failures, 4))
            logging.warning('Catalog refresh failed: %s', type(error).__name__)
        stop.wait(interval)


def handler_for(snapshot: Snapshot):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            body, fetched_at, stats = snapshot.read()
            age = max(0, time.time() - fetched_at)
            ready = body is not None and age < MAX_STALE
            if self.path == '/healthz':
                self.reply(200, b'{"alive":true}', 'application/json')
            elif self.path == '/readyz':
                self.reply(200 if ready else 503, json.dumps({'ready': ready, 'fetched_at': fetched_at,
                    'age_seconds': int(age), **stats}).encode(), 'application/json')
            elif self.path == '/v1/catalog.csv':
                if not ready:
                    self.reply(503, b'{"error":"catalog unavailable or expired"}', 'application/json')
                else:
                    self.reply(200, body, 'text/csv; charset=utf-8', fetched_at)
            else:
                self.reply(404, b'{"error":"not found"}', 'application/json')

        def reply(self, status, body, content_type, fetched_at=None):
            self.send_response(status)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('Cache-Control', 'public, max-age=60' if status == 200 else 'no-store')
            if fetched_at is not None:
                self.send_header('X-Catalog-Fetched-At', str(int(fetched_at)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, fmt, *args):
            # Do not collect client IP addresses or per-user access logs.
            pass
    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--host', default='127.0.0.1')
    parser.add_argument('--port', type=int, default=8080)
    parser.add_argument('--cache', type=Path, default=Path('data/catalog.json'))
    parser.add_argument('--once', action='store_true')
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format='%(levelname)s %(message)s')
    snapshot = Snapshot(args.cache)
    if args.once:
        snapshot.update(download())
        print(json.dumps(snapshot.read()[2], ensure_ascii=False))
        return
    stop = threading.Event()
    worker = threading.Thread(target=refresh_loop, args=(snapshot, stop), daemon=True)
    worker.start()
    server = ThreadingHTTPServer((args.host, args.port), handler_for(snapshot))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        server.server_close()


if __name__ == '__main__':
    main()
