"""Host-side cache service: unix socket, blobs in $XDG_CACHE_HOME/pkgs-cache. Prototype."""

import os
import socketserver
import sys
import threading
from pathlib import Path

ROOT = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "pkgs-cache"
STATS = {"get": 0, "hit": 0, "put": 0}


class Handler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        while True:
            line = self.rfile.readline()
            if not line:
                return
            parts = line.decode().split()
            if parts[0] == "GET":
                STATS["get"] += 1
                p = ROOT / parts[1]
                if p.is_file():
                    STATS["hit"] += 1
                    data = p.read_bytes()
                    self.wfile.write(f"OK {len(data)}\n".encode() + data)
                else:
                    self.wfile.write(b"MISS\n")
            elif parts[0] == "PUT":
                STATS["put"] += 1
                n = int(parts[2])
                data = self.rfile.read(n)
                p = ROOT / parts[1]
                p.parent.mkdir(parents=True, exist_ok=True)
                # unique per connection: two clients may PUT the same key at once
                tmp = p.with_name(f"{p.name}.{threading.get_ident()}.tmp")
                tmp.write_bytes(data)
                tmp.replace(p)
                self.wfile.write(b"OK\n")
            elif parts[0] == "STATS":
                self.wfile.write(f"{STATS}\n".encode())
            self.wfile.flush()


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


if __name__ == "__main__":
    sock = sys.argv[1]
    if os.path.exists(sock):
        os.unlink(sock)
    ROOT.mkdir(parents=True, exist_ok=True)
    srv = Server(sock, Handler)
    os.chmod(sock, 0o666)
    print(f"listening on {sock}, store {ROOT}", flush=True)
    srv.serve_forever()
