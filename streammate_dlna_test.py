#!/usr/bin/env python3
"""StreamMate DLNA test: ask the TV's media renderer to play a test video
served from this Mac. Standard library only.

Usage: python3 streammate_dlna_test.py [TV_IP] [DESCRIPTION_PORT]
"""
import http.server
import os
import re
import socket
import sys
import threading
import time
import urllib.request
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape

TV = sys.argv[1] if len(sys.argv) > 1 else "192.168.49.1"
DESC_PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 1840
HERE = os.path.dirname(os.path.abspath(__file__))
HTTP_PORT = 8765
AVT = "urn:schemas-upnp-org:service:AVTransport:1"
FILES = {
    "streammate_test.mp4": "video/mp4",
    "streammate_test.ts": "video/mpeg",
}
DLNA_FEATURES = "DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"

hits = []


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _serve(self, head_only):
        name = self.path.lstrip("/").split("?")[0]
        hits.append("%s /%s Range=%s UA=%s" % (
            self.command, name, self.headers.get("Range"), self.headers.get("User-Agent")))
        if name not in FILES:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        path = os.path.join(HERE, name)
        size = os.path.getsize(path)
        start, end = 0, size - 1
        m = re.match(r"bytes=(\d*)-(\d*)", self.headers.get("Range") or "")
        partial = False
        if m and (m.group(1) or m.group(2)):
            partial = True
            if m.group(1):
                start = int(m.group(1))
                if m.group(2):
                    end = min(int(m.group(2)), size - 1)
            else:
                start = max(0, size - int(m.group(2)))
        if start > end or start >= size:
            self.send_response(416)
            self.send_header("Content-Range", "bytes */%d" % size)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_response(206 if partial else 200)
        self.send_header("Content-Type", FILES[name])
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Accept-Ranges", "bytes")
        if partial:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        self.send_header("transferMode.dlna.org", "Streaming")
        self.send_header("contentFeatures.dlna.org", DLNA_FEATURES)
        self.end_headers()
        if head_only:
            return
        try:
            with open(path, "rb") as f:
                f.seek(start)
                left = end - start + 1
                while left > 0:
                    chunk = f.read(min(65536, left))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    left -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        self._serve(False)

    def do_HEAD(self):
        self._serve(True)

    def log_message(self, *a):
        pass


def find_control_url():
    base = "http://%s:%d" % (TV, DESC_PORT)
    xml = urllib.request.urlopen(base + "/", timeout=6).read()
    root = ET.fromstring(xml)
    name = None
    for el in root.iter():
        tag = el.tag.split("}")[-1]
        if tag == "friendlyName" and name is None:
            name = el.text
        if tag == "service":
            kids = {c.tag.split("}")[-1]: (c.text or "").strip() for c in el}
            if "AVTransport" in kids.get("serviceType", ""):
                url = kids.get("controlURL", "")
                if not url.startswith("http"):
                    url = base + (url if url.startswith("/") else "/" + url)
                return name, url
    sys.exit("RESULT: no AVTransport service in the TV's description.")


def soap(url, action, args):
    body = "".join("<%s>%s</%s>" % (k, escape(str(v)), k) for k, v in args)
    env = ('<?xml version="1.0" encoding="utf-8"?>'
           '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
           's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
           '<u:%s xmlns:u="%s">%s</u:%s></s:Body></s:Envelope>' % (action, AVT, body, action))
    req = urllib.request.Request(url, data=env.encode(), method="POST", headers={
        "Content-Type": 'text/xml; charset="utf-8"',
        "SOAPACTION": '"%s#%s"' % (AVT, action),
        "User-Agent": "StreamMate/0.1 UPnP/1.0",
    })
    try:
        return True, urllib.request.urlopen(req, timeout=8).read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        return False, "HTTP %s %s" % (e.code, e.read().decode(errors="replace"))
    except Exception as e:
        return False, "ERR %s" % e


def field(xml, tag):
    m = re.search(r"<%s[^>]*>([^<]*)</%s>" % (tag, tag), xml)
    return m.group(1) if m else "?"


def short_err(text):
    code = field(text, "errorCode")
    desc = field(text, "errorDescription")
    return "UPnP error %s (%s)" % (code, desc) if code != "?" else text[:200]


def didl(url, mime, title):
    return ('<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
            'xmlns:dc="http://purl.org/dc/elements/1.1/" '
            'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
            '<item id="0" parentID="-1" restricted="1"><dc:title>%s</dc:title>'
            '<upnp:class>object.item.videoItem</upnp:class>'
            '<res protocolInfo="http-get:*:%s:%s">%s</res></item></DIDL-Lite>'
            % (escape(title), mime, DLNA_FEATURES, escape(url)))


def try_play(ctrl, my_ip, name):
    mime = FILES[name]
    url = "http://%s:%d/%s" % (my_ip, HTTP_PORT, name)
    print("\n=== %s (%s)" % (name, mime))
    del hits[:]
    soap(ctrl, "Stop", [("InstanceID", 0)])
    ok, r = soap(ctrl, "SetAVTransportURI", [
        ("InstanceID", 0), ("CurrentURI", url), ("CurrentURIMetaData", didl(url, mime, "StreamMate test"))])
    print("  SetAVTransportURI: %s" % ("ok" if ok else short_err(r)))
    if not ok:
        return False
    ok, r = soap(ctrl, "Play", [("InstanceID", 0), ("Speed", 1)])
    print("  Play: %s" % ("ok" if ok else short_err(r)))
    playing = False
    for i in range(7):
        time.sleep(2)
        ok1, t = soap(ctrl, "GetTransportInfo", [("InstanceID", 0)])
        ok2, p = soap(ctrl, "GetPositionInfo", [("InstanceID", 0)])
        state = field(t, "CurrentTransportState") if ok1 else short_err(t)
        pos = field(p, "RelTime") if ok2 else "?"
        print("  t+%2ds state=%s status=%s position=%s" % (
            (i + 1) * 2, state, field(t, "CurrentTransportStatus") if ok1 else "?", pos))
        if state == "PLAYING" and pos not in ("?", "0:00:00", "00:00:00", "NOT_IMPLEMENTED"):
            playing = True
    print("  requests from the TV: %d" % len(hits))
    for h in hits[:6]:
        print("    " + h)
    soap(ctrl, "Stop", [("InstanceID", 0)])
    return playing and bool(hits)


def main():
    for name in FILES:
        if not os.path.exists(os.path.join(HERE, name)):
            sys.exit("Missing %s next to this script." % name)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.connect((TV, 9))
    my_ip = s.getsockname()[0]
    s.close()
    name, ctrl = find_control_url()
    print("[ok] renderer: %s" % name)
    print("[ok] control URL: %s" % ctrl)
    srv = http.server.ThreadingHTTPServer(("0.0.0.0", HTTP_PORT), Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    print("[ok] serving test videos from http://%s:%d/" % (my_ip, HTTP_PORT))
    print("     (if macOS asks to allow incoming connections for Python, click Allow)")
    results = {n: try_play(ctrl, my_ip, n) for n in FILES}
    print()
    for n, ok in results.items():
        print("RESULT %s: %s" % (n, "PLAYED" if ok else "did not play"))
    print("Did the TV show a moving test pattern with a beep? Tell Claude what you saw.")


if __name__ == "__main__":
    main()
