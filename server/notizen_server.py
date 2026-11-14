#!/usr/bin/env python3
"""Notizen-Sync-Server für den Raspberry Pi.

Braucht nur Python 3 (keine zusätzlichen Pakete). Speichert Notizen in einer
SQLite-Datei, Anhänge (Bilder, PDFs, Dateien) als einzelne Dateien, und gleicht
alles zwischen iPhone, iPad und Mac ab.

Start:  python3 notizen_server.py [--port 8787] [--data ~/.notizen-server]
"""

import argparse
import hashlib
import hmac
import json
import os
import re
import secrets
import sqlite3
import tempfile
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

MAX_SYNC_BODY = 100 * 1024 * 1024   # Notizen inkl. Zeichnungen
MAX_BLOB = 500 * 1024 * 1024        # einzelner Anhang
POLL_SECONDS = 25
CHUNK = 1024 * 1024
BLOB_RE = re.compile(r"^/api/blobs/([0-9a-f]{64})$")

SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS notes (
    id TEXT PRIMARY KEY,
    folder_id TEXT,
    text TEXT NOT NULL DEFAULT '',
    pinned INTEGER NOT NULL DEFAULT 0,
    trashed INTEGER NOT NULL DEFAULT 0,
    deleted INTEGER NOT NULL DEFAULT 0,
    created_at REAL NOT NULL,
    modified_at REAL NOT NULL,
    rev INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS folders (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL DEFAULT '',
    deleted INTEGER NOT NULL DEFAULT 0,
    modified_at REAL NOT NULL,
    rev INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS notes_rev ON notes(rev);
CREATE INDEX IF NOT EXISTS folders_rev ON folders(rev);
"""


class Store:
    """Alle Datenbankzugriffe laufen über eine Sperre – für den Hausgebrauch reicht das."""

    def __init__(self, data_dir):
        os.makedirs(data_dir, exist_ok=True)
        self.db_path = os.path.join(data_dir, "notizen.db")
        self.blob_dir = os.path.join(data_dir, "blobs")
        os.makedirs(self.blob_dir, exist_ok=True)
        self.changed = threading.Condition()
        with self._connect() as db:
            db.executescript(SCHEMA)
            cols = {r[1] for r in db.execute("PRAGMA table_info(notes)")}
            if "content" not in cols:
                # Neu in Version 2: Blöcke (Text, Zeichnungen, Anhänge) als JSON
                db.execute("ALTER TABLE notes ADD COLUMN content TEXT")
            db.execute(
                "INSERT OR IGNORE INTO meta(key, value) VALUES('server_id', ?)",
                (str(uuid.uuid4()),),
            )
            db.execute("INSERT OR IGNORE INTO meta(key, value) VALUES('rev', '0')")
            self.server_id = db.execute(
                "SELECT value FROM meta WHERE key='server_id'"
            ).fetchone()[0]
            self.rev = int(
                db.execute("SELECT value FROM meta WHERE key='rev'").fetchone()[0]
            )

    def _connect(self):
        db = sqlite3.connect(self.db_path, timeout=30)
        db.row_factory = sqlite3.Row
        return db

    # --- Anhänge ------------------------------------------------------------

    def blob_path(self, digest):
        return os.path.join(self.blob_dir, digest)

    def has_blob(self, digest):
        return os.path.exists(self.blob_path(digest))

    # --- Notizen ------------------------------------------------------------

    @staticmethod
    def _note_out(r):
        blocks = None
        if r["content"]:
            try:
                blocks = json.loads(r["content"])
            except ValueError:
                blocks = None
        out = {
            "id": r["id"],
            "folderId": r["folder_id"],
            "text": r["text"],
            "pinned": bool(r["pinned"]),
            "trashed": bool(r["trashed"]),
            "deleted": bool(r["deleted"]),
            "createdAt": r["created_at"],
            "modifiedAt": r["modified_at"],
        }
        if blocks is not None:
            out["blocks"] = blocks
        return out

    def sync(self, since, notes, folders):
        with self.changed:
            db = self._connect()
            try:
                rev = self.rev
                for n in notes:
                    row = db.execute(
                        "SELECT modified_at FROM notes WHERE id=?", (n["id"],)
                    ).fetchone()
                    if row is not None and row["modified_at"] >= n["modifiedAt"]:
                        continue  # Server hat schon eine neuere Fassung
                    rev += 1
                    blocks = n.get("blocks")
                    db.execute(
                        "INSERT OR REPLACE INTO notes"
                        "(id, folder_id, text, pinned, trashed, deleted, created_at, modified_at, rev, content)"
                        " VALUES(?,?,?,?,?,?,?,?,?,?)",
                        (
                            n["id"],
                            n.get("folderId"),
                            n.get("text", ""),
                            int(bool(n.get("pinned"))),
                            int(bool(n.get("trashed"))),
                            int(bool(n.get("deleted"))),
                            float(n.get("createdAt", n["modifiedAt"])),
                            float(n["modifiedAt"]),
                            rev,
                            json.dumps(blocks, ensure_ascii=False) if blocks is not None else None,
                        ),
                    )
                for f in folders:
                    row = db.execute(
                        "SELECT modified_at FROM folders WHERE id=?", (f["id"],)
                    ).fetchone()
                    if row is not None and row["modified_at"] >= f["modifiedAt"]:
                        continue
                    rev += 1
                    db.execute(
                        "INSERT OR REPLACE INTO folders(id, name, deleted, modified_at, rev)"
                        " VALUES(?,?,?,?,?)",
                        (
                            f["id"],
                            f.get("name", ""),
                            int(bool(f.get("deleted"))),
                            float(f["modifiedAt"]),
                            rev,
                        ),
                    )
                db.execute("UPDATE meta SET value=? WHERE key='rev'", (str(rev),))
                db.commit()

                out_notes = [
                    self._note_out(r)
                    for r in db.execute(
                        "SELECT * FROM notes WHERE rev > ? ORDER BY rev", (since,)
                    )
                ]
                out_folders = [
                    {
                        "id": r["id"],
                        "name": r["name"],
                        "deleted": bool(r["deleted"]),
                        "modifiedAt": r["modified_at"],
                    }
                    for r in db.execute(
                        "SELECT * FROM folders WHERE rev > ? ORDER BY rev", (since,)
                    )
                ]
            finally:
                db.close()
            if rev != self.rev:
                self.rev = rev
                self.changed.notify_all()
            return {
                "rev": rev,
                "serverId": self.server_id,
                "notes": out_notes,
                "folders": out_folders,
            }

    def wait_for_change(self, since):
        with self.changed:
            self.changed.wait_for(lambda: self.rev != since, timeout=POLL_SECONDS)
            return {"rev": self.rev, "serverId": self.server_id}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "Notizen/2.0"
    store = None
    token = ""

    def log_message(self, fmt, *args):
        pass  # kein Log pro Anfrage – schont die SD-Karte

    def _send(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _fail(self, status, error):
        # Nicht gelesene Anfragedaten würden die nächste Anfrage stören.
        self.close_connection = True
        self._send(status, {"error": error})

    def _authorized(self):
        given = self.headers.get("Authorization", "")
        if hmac.compare_digest(given.encode(), ("Bearer " + self.token).encode()):
            return True
        self._fail(401, "unauthorized")
        return False

    def _length(self, limit):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return None
        if length < 0 or length > limit:
            return None
        return length

    def do_GET(self):
        url = urlparse(self.path)
        if not self._authorized():
            return
        if url.path == "/api/ping":
            self._send(200, {"ok": True, "rev": self.store.rev,
                             "serverId": self.store.server_id, "version": 2})
        elif url.path == "/api/poll":
            try:
                since = int(parse_qs(url.query).get("since", ["0"])[0])
            except ValueError:
                since = 0
            self._send(200, self.store.wait_for_change(since))
        elif BLOB_RE.match(url.path):
            self._get_blob(BLOB_RE.match(url.path).group(1))
        else:
            self._send(404, {"error": "not found"})

    def _get_blob(self, digest):
        path = self.store.blob_path(digest)
        try:
            f = open(path, "rb")
        except FileNotFoundError:
            self._send(404, {"error": "not found"})
            return
        with f:
            size = os.fstat(f.fileno()).st_size
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(size))
            self.send_header("Cache-Control", "private, max-age=31536000, immutable")
            self.end_headers()
            while True:
                chunk = f.read(CHUNK)
                if not chunk:
                    break
                self.wfile.write(chunk)

    def do_PUT(self):
        url = urlparse(self.path)
        if not self._authorized():
            return
        m = BLOB_RE.match(url.path)
        if not m:
            self._fail(404, "not found")
            return
        digest = m.group(1)
        length = self._length(MAX_BLOB)
        if length is None:
            self._fail(413, "too large")
            return
        if self.store.has_blob(digest):
            # Schon vorhanden: Daten verwerfen, damit die Verbindung sauber bleibt.
            remaining = length
            while remaining > 0:
                chunk = self.rfile.read(min(CHUNK, remaining))
                if not chunk:
                    break
                remaining -= len(chunk)
            self._send(200, {"ok": True})
            return
        # In eine Temp-Datei streamen und dabei prüfen – kein großer Speicherbedarf.
        h = hashlib.sha256()
        fd, tmp = tempfile.mkstemp(dir=self.store.blob_dir, prefix=".upload-")
        try:
            with os.fdopen(fd, "wb") as out:
                remaining = length
                while remaining > 0:
                    chunk = self.rfile.read(min(CHUNK, remaining))
                    if not chunk:
                        break
                    h.update(chunk)
                    out.write(chunk)
                    remaining -= len(chunk)
            if remaining > 0 or h.hexdigest() != digest:
                os.unlink(tmp)
                self._fail(400, "checksum mismatch")
                return
            os.replace(tmp, self.store.blob_path(digest))
        except Exception:
            if os.path.exists(tmp):
                os.unlink(tmp)
            raise
        self._send(200, {"ok": True})

    def do_POST(self):
        url = urlparse(self.path)
        if not self._authorized():
            return
        if url.path not in ("/api/sync", "/api/blobs/missing"):
            self._fail(404, "not found")
            return
        length = self._length(MAX_SYNC_BODY)
        if length is None:
            self._fail(413, "too large")
            return
        try:
            data = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            self._send(400, {"error": "bad request"})
            return

        if url.path == "/api/blobs/missing":
            hashes = data.get("hashes", []) if isinstance(data, dict) else []
            missing = [x for x in hashes
                       if isinstance(x, str) and re.fullmatch(r"[0-9a-f]{64}", x)
                       and not self.store.has_blob(x)]
            self._send(200, {"missing": missing})
            return

        try:
            since = int(data.get("since", 0))
            notes = data.get("notes", [])
            folders = data.get("folders", [])
            for item in notes + folders:
                if not isinstance(item["id"], str) or not isinstance(
                    item["modifiedAt"], (int, float)
                ):
                    raise ValueError("bad item")
            for n in notes:
                if n.get("blocks") is not None and not isinstance(n["blocks"], list):
                    raise ValueError("bad blocks")
        except (ValueError, KeyError, TypeError, AttributeError):
            self._send(400, {"error": "bad request"})
            return
        self._send(200, self.store.sync(since, notes, folders))


def load_token(data_dir):
    path = os.path.join(data_dir, "token.txt")
    if os.path.exists(path):
        with open(path) as f:
            token = f.read().strip()
        if token:
            return token
    token = secrets.token_urlsafe(24)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(token + "\n")
    return token


def main():
    parser = argparse.ArgumentParser(description="Notizen-Sync-Server")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--data", default=os.path.expanduser("~/.notizen-server"))
    args = parser.parse_args()

    Handler.store = Store(args.data)
    Handler.token = load_token(args.data)
    ThreadingHTTPServer.daemon_threads = True
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"Notizen-Server läuft auf Port {args.port}", flush=True)
    print(f"Daten:  {args.data}", flush=True)
    print(f"Token:  {Handler.token}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
