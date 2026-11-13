#!/usr/bin/env python3
"""claude-beacon server: tracks Claude Code agent states, pushes changes over SSE.

POST /event   {session_id, host, project, state, label?, title?}   (Authorization: Bearer <token>)
              label: where the session runs (the hook sends the tmux session name)
              title: what the session is (the /rename name, else Claude's auto-generated title)
POST /ack     {session_id?}  acknowledge needs_input and done sessions (all if no session_id)
GET  /state   current snapshot as JSON
GET  /events  Server-Sent Events stream (snapshot on connect, then on every change)

States: working | needs_input | done | ended
`waiting` counts needs_input sessions that haven't been acknowledged; `idle` counts done
sessions that haven't been. Any new event for a session clears its acknowledgment. A needs_input session never times out: it
stays until that session acts again, ends, or is acknowledged. State survives restarts
when BEACON_STATE_FILE is set.
"""
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("BEACON_PORT", "8799"))
TOKEN = os.environ.get("BEACON_TOKEN", "")
STALE_SECONDS = int(os.environ.get("BEACON_STALE_SECONDS", str(6 * 3600)))
STATE_FILE = os.environ.get("BEACON_STATE_FILE", "")
STATES = {"working", "needs_input", "done", "ended"}

lock = threading.Condition()
sessions = {}  # session_id -> {session_id, host, project, state, updated}
version = 0


def save():
    """Persist sessions (caller holds the lock)."""
    if not STATE_FILE:
        return
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(sessions, f)
    os.replace(tmp, STATE_FILE)


def load():
    if STATE_FILE and os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE) as f:
                sessions.update(json.load(f))
        except (OSError, ValueError):
            pass


def snapshot():
    now = time.time()
    items = [dict(s, age=int(now - s["updated"])) for s in sessions.values()]
    items.sort(key=lambda s: s["updated"])
    waiting = sum(1 for s in items if s["state"] == "needs_input" and not s["acked"])
    idle = sum(1 for s in items if s["state"] == "done" and not s["acked"])
    return {"waiting": waiting, "idle": idle, "sessions": items}


def apply_event(ev):
    global version
    sid, state = ev["session_id"], ev["state"]
    with lock:
        if state == "ended":
            sessions.pop(sid, None)
        else:
            sessions[sid] = {
                "session_id": sid,
                "host": ev.get("host", ""),
                "project": ev.get("project", ""),
                "label": str(ev.get("label") or "")[:64],
                "title": str(ev.get("title") or "")[:120],
                "state": state,
                "updated": time.time(),
                "acked": False,
            }
        version += 1
        save()
        lock.notify_all()


def apply_ack(session_id=None):
    global version
    with lock:
        for sid, s in sessions.items():
            if s["state"] in ("needs_input", "done") and session_id in (None, sid):
                s["acked"] = True
        version += 1
        save()
        lock.notify_all()


def reaper():
    global version
    while True:
        time.sleep(60)
        cutoff = time.time() - STALE_SECONDS
        with lock:
            # never reap a needs_input session the user hasn't acknowledged
            dead = [k for k, s in sessions.items() if s["updated"] < cutoff
                    and not (s["state"] == "needs_input" and not s["acked"])]
            for k in dead:
                del sessions[k]
            if dead:
                version += 1
                save()
                lock.notify_all()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def authed(self):
        if not TOKEN:
            return True
        return self.headers.get("Authorization", "") == f"Bearer {TOKEN}"

    def send_json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path not in ("/event", "/ack"):
            return self.send_json(404, {"error": "not found"})
        if not self.authed():
            return self.send_json(401, {"error": "unauthorized"})
        if self.path == "/ack":
            try:
                length = int(self.headers.get("Content-Length", 0))
                body = json.loads(self.rfile.read(length) or b"{}")
            except Exception:
                return self.send_json(400, {"error": "bad request"})
            apply_ack(body.get("session_id"))
            return self.send_json(200, {"ok": True})
        try:
            ev = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
            assert ev["session_id"] and ev["state"] in STATES
        except Exception:
            return self.send_json(400, {"error": "bad event"})
        apply_event(ev)
        self.send_json(200, {"ok": True})

    def do_GET(self):
        if self.path == "/health":
            return self.send_json(200, {"ok": True})
        if not self.authed():
            return self.send_json(401, {"error": "unauthorized"})
        if self.path == "/state":
            with lock:
                return self.send_json(200, snapshot())
        if self.path == "/events":
            return self.stream()
        self.send_json(404, {"error": "not found"})

    def stream(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        seen = -1
        try:
            while True:
                with lock:
                    if version == seen:
                        lock.wait(timeout=15)
                    changed = version != seen
                    seen = version
                    data = json.dumps(snapshot())
                if changed:
                    self.wfile.write(f"event: state\ndata: {data}\n\n".encode())
                else:
                    self.wfile.write(b": keepalive\n\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


if __name__ == "__main__":
    load()
    threading.Thread(target=reaper, daemon=True).start()
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    srv.daemon_threads = True
    print(f"claude-beacon listening on :{PORT}", flush=True)
    srv.serve_forever()
