"""Serve the preview on all network interfaces without caching files."""
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class PreviewHandler(SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


if __name__ == "__main__":
    directory = Path(__file__).resolve().parent / "dist"
    handler = partial(PreviewHandler, directory=str(directory))
    with ThreadingHTTPServer(("0.0.0.0", 4173), handler) as server:
        print("Polka preview: http://localhost:4173 (listening on all interfaces)", flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
