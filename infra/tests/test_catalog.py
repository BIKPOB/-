import base64
import csv
import io
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
import urllib.request
import urllib.error
from http.server import ThreadingHTTPServer
from catalog_service import Snapshot, inspect_catalog, handler_for, MAX_STALE


def feed(ip='8.8.8.8', profile=None):
    # Synthetic fixtures only: never represent these addresses as actual VPNs.
    profile = profile or f'client\ndev tun\nremote {ip} 443\n<ca>\nTEST\n</ca>\n'
    output = io.StringIO()
    writer = csv.writer(output)
    writer.writerow(['#HostName', 'IP', 'CountryLong', 'CountryShort', 'OpenVPN_ConfigData_Base64'])
    writer.writerow(['fixture', ip, 'Test, country', 'US', base64.b64encode(profile.encode()).decode()])
    return ('*vpn_servers\n' + output.getvalue() + '*\n').encode()


class CatalogTests(unittest.TestCase):
    def test_quoted_csv_and_profiles(self):
        self.assertEqual(inspect_catalog(feed()), {'records': 1, 'countries': {'US': 1}})

    def test_html_instead_of_feed_rejected(self):
        with self.assertRaises(ValueError): inspect_catalog(b'<html>blocked</html>')

    def test_private_lan_not_accepted(self):
        with self.assertRaises(ValueError): inspect_catalog(feed('127.0.0.1'))

    def test_mismatched_remote_rejected(self):
        with self.assertRaises(ValueError): inspect_catalog(feed(profile='remote 1.1.1.1 443'))

    def test_failed_update_retains_good_snapshot(self):
        snapshot = Snapshot()
        snapshot.update(feed())
        with self.assertRaises(ValueError): snapshot.update(b'bad')
        self.assertEqual(snapshot.read()[0], feed())

    def test_disk_cache_roundtrip(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'cache.json'
            first = Snapshot(path); first.update(feed())
            second = Snapshot(path)
            self.assertEqual(first.read(), second.read())

    def test_http_readiness_and_stale_failure(self):
        snapshot = Snapshot()
        server = ThreadingHTTPServer(('127.0.0.1', 0), handler_for(snapshot))
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        base = f'http://127.0.0.1:{server.server_port}'
        try:
            with urllib.request.urlopen(base+'/healthz') as response:
                self.assertTrue(json.load(response)['alive'])
            with self.assertRaises(urllib.error.HTTPError) as result:
                urllib.request.urlopen(base+'/readyz')
            self.assertEqual(result.exception.code, 503)
            snapshot.update(feed())
            with urllib.request.urlopen(base+'/v1/catalog.csv') as response:
                self.assertEqual(response.read(), feed())
            snapshot.update(feed(), time.time() - MAX_STALE - 1)
            with self.assertRaises(urllib.error.HTTPError) as result:
                urllib.request.urlopen(base+'/v1/catalog.csv')
            self.assertEqual(result.exception.code, 503)
        finally:
            server.shutdown(); server.server_close(); thread.join()


if __name__ == '__main__': unittest.main()
