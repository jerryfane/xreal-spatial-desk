#!/usr/bin/env python3
"""Fake XREAL One: replays a session captured by record_session.py on the glasses' TCP ports.

  52998  sensor stream: recorded frames, byte-exact, original timing, broadcast live to every client
  52999  control channel: recorded unsolicited frames (buttons, wear, state, telemetry) on the same
         timeline; GET requests (body 18 00) answered with the recorded replies. Commands that were
         never recorded are logged and NOT answered, because their real reply format is unknown.

Like the real glasses, clients join the live stream wherever playback currently is.
Standard library only.

Usage:
  python3 fake_glasses.py CAPTURE_DIR [--host 127.0.0.1] [--loop] [--speed 1.0]
                          [--start-marker free_look] [--end-marker end]

To serve on the real address with the glasses unplugged:
  sudo ifconfig lo0 alias 169.254.2.1      # undo: sudo ifconfig lo0 -alias 169.254.2.1
  python3 fake_glasses.py CAPTURE_DIR --host 169.254.2.1

Commands on stdin while running:
  off | on            send the recorded "glasses taken off" / "put on" event
  press KEY           send a recorded button press (down, then up 150 ms later); KEY as recorded, e.g. 2 or 3
  jump MARKER         restart playback at a recorded step (see `markers`)
  markers             list recorded steps
  quit
"""
import argparse
import gzip
import json
import os
import socket
import struct
import sys
import threading
import time

SENSOR_PORT, CONTROL_PORT = 52998, 52999
GET_BODY = b"\x18\x00"


def open_capture(capture_dir, name):
    """Open NAME or NAME.gz (published captures are gzipped; fresh recordings are not)."""
    path = os.path.join(capture_dir, name)
    return open(path) if os.path.exists(path) else gzip.open(path + ".gz", "rt")


def load(capture_dir):
    with open_capture(capture_dir, "markers.jsonl") as f:
        markers = [json.loads(l) for l in f]
    start = markers[0]["t_ns"]
    timeline = []
    with open_capture(capture_dir, "frames.jsonl") as f:
        for line in f:
            r = json.loads(line)
            if r["dir"] == "rx" and r["t_ns"] >= start:
                timeline.append((r["t_ns"] - start, r["port"], bytes.fromhex(r["hex"])))
    timeline.sort(key=lambda e: e[0])
    with open_capture(capture_dir, "control_gets.json") as f:
        gets = json.load(f)
    replies = {int(v["cmd"], 16): bytes.fromhex(v["reply_hex"]) for v in gets.values() if v.get("reply_hex")}
    marks = [{"name": m["marker"], "t": m["t_ns"] - start} for m in markers]
    # On-demand event templates, taken from the recording itself.
    wear, buttons = {}, {}
    for _, port, fr in timeline:
        if port != CONTROL_PORT:
            continue
        magic = struct.unpack(">H", fr[:2])[0]
        if magic == 0x273D and len(fr) == 8:          # observed bodies: 18 02 (taken off), 18 01 (put on)
            wear.setdefault({2: "off", 1: "on"}.get(fr[7]), fr)
        elif magic == 0x272E and len(fr) >= 14:       # body: u32 key, u32 state (1 down, 2 up), ...
            key, state = struct.unpack_from("<II", fr, 6)
            buttons.setdefault((key, state), fr)
    return timeline, replies, marks, wear, buttons


class Port:
    """Accepts clients on one TCP port; frames are written under a per-client lock."""

    def __init__(self, host, port, on_client=None):
        self.clients, self.lock, self.port = {}, threading.Lock(), port
        self.srv = socket.create_server((host, port), reuse_port=False)
        self.on_client = on_client
        threading.Thread(target=self._accept, daemon=True).start()

    def _accept(self):
        while True:
            try:
                c, addr = self.srv.accept()
            except OSError:
                return
            c.settimeout(1.0)
            with self.lock:
                self.clients[c] = threading.Lock()
            log(f"port {self.port}: client {addr[0]}:{addr[1]} connected")
            if self.on_client:
                threading.Thread(target=self.on_client, args=(self, c), daemon=True).start()

    def send(self, c, data):
        lk = self.clients.get(c)
        if lk is None:
            return
        try:
            with lk:
                c.sendall(data)
        except OSError:
            self.drop(c)

    def broadcast(self, data):
        for c in list(self.clients):
            self.send(c, data)

    def drop(self, c):
        with self.lock:
            if self.clients.pop(c, None) is not None:
                log(f"port {self.port}: client disconnected")
        try:
            c.close()
        except OSError:
            pass


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def control_handler(replies):
    def handle(port, c):
        buf = b""
        while c in port.clients:
            try:
                chunk = c.recv(65536)
            except socket.timeout:
                continue
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
            while len(buf) >= 6:
                cmd, length = struct.unpack(">HI", buf[:6])
                if len(buf) < 6 + length:
                    break
                payload, buf = buf[6:6 + length], buf[6 + length:]
                if length < 4:
                    log(f"control: malformed request 0x{cmd:04x}")
                    continue
                txid = struct.unpack(">I", payload[:4])[0] & 0x7FFFFFFF
                body = payload[4:]
                reply = replies.get(cmd) if body == GET_BODY else None
                if reply is None:
                    log(f"control: unrecorded command 0x{cmd:04x} body={body.hex()} — not answered")
                    continue
                port.send(c, struct.pack(">HII", cmd, len(reply) + 4, txid) + reply)
        port.drop(c)
    return handle


class Player:
    def __init__(self, timeline, marks, ports, speed, loop, start_t, end_t):
        self.timeline, self.marks, self.ports = timeline, marks, ports
        self.speed, self.loop = speed, loop
        self.range = (start_t, end_t)
        self.jump_to = start_t
        self.lock = threading.Lock()

    def jump(self, t):
        with self.lock:
            self.jump_to = t

    def run(self):
        lo, hi = self.range
        while True:
            with self.lock:
                t_start, self.jump_to = self.jump_to, None
            i = next((k for k, e in enumerate(self.timeline) if e[0] >= t_start), len(self.timeline))
            wall0 = time.monotonic()
            mark_i = sum(1 for m in self.marks if m["t"] <= t_start)
            if mark_i:
                log(f"playing: {self.marks[mark_i - 1]['name']}")
            while i < len(self.timeline) and self.timeline[i][0] <= hi:
                if self.jump_to is not None:
                    break
                t, port, fr = self.timeline[i]
                while mark_i < len(self.marks) and self.marks[mark_i]["t"] <= t:
                    log(f"playing: {self.marks[mark_i]['name']}")
                    mark_i += 1
                delay = wall0 + (t - t_start) / 1e9 / self.speed - time.monotonic()
                if delay > 0.0005:
                    time.sleep(delay)
                self.ports[port].broadcast(fr)
                i += 1
            if self.jump_to is not None:
                continue
            if not self.loop:
                log("end of recording (use --loop to repeat, or `jump MARKER`); still answering GET requests")
                while self.jump_to is None:
                    time.sleep(0.1)
                continue
            log("looping")
            self.jump_to = lo


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("capture")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--speed", type=float, default=1.0)
    ap.add_argument("--loop", action="store_true")
    ap.add_argument("--start-marker")
    ap.add_argument("--end-marker")
    args = ap.parse_args()

    timeline, replies, marks, wear, buttons = load(args.capture)
    by_name = {m["name"]: m["t"] for m in marks}
    for name in (args.start_marker, args.end_marker):
        if name and name not in by_name:
            sys.exit(f"unknown marker {name!r}; recorded: {', '.join(by_name)}")
    start_t = by_name.get(args.start_marker, 0)
    end_t = by_name.get(args.end_marker, timeline[-1][0])
    log(f"loaded {len(timeline)} frames, {len(replies)} GET replies, {len(marks)} markers; "
        f"buttons recorded: {sorted({k for k, _ in buttons})}; wear events: {sorted(k for k in wear if k)}")

    ports = {SENSOR_PORT: Port(args.host, SENSOR_PORT), CONTROL_PORT: Port(args.host, CONTROL_PORT, control_handler(replies))}
    log(f"serving fake glasses on {args.host}:{SENSOR_PORT} (sensor) and :{CONTROL_PORT} (control)")
    player = Player(timeline, marks, ports, args.speed, args.loop, start_t, end_t)
    threading.Thread(target=player.run, daemon=True).start()

    for line in sys.stdin:
        cmd = line.split()
        if not cmd:
            continue
        if cmd[0] in ("off", "on"):
            if cmd[0] in wear:
                ports[CONTROL_PORT].broadcast(wear[cmd[0]]); log(f"sent wear {cmd[0]}")
            else:
                log(f"no recorded wear-{cmd[0]} event")
        elif cmd[0] == "press" and len(cmd) == 2 and cmd[1].isdigit():
            key = int(cmd[1])
            if (key, 1) in buttons and (key, 2) in buttons:
                ports[CONTROL_PORT].broadcast(buttons[(key, 1)]); time.sleep(0.15)
                ports[CONTROL_PORT].broadcast(buttons[(key, 2)]); log(f"pressed key {key}")
            else:
                log(f"key {key} not recorded; recorded: {sorted({k for k, _ in buttons})}")
        elif cmd[0] == "jump" and len(cmd) == 2 and cmd[1] in by_name:
            player.jump(by_name[cmd[1]])
        elif cmd[0] == "markers":
            print("  " + "\n  ".join(f"{m['t'] / 1e9:6.1f}s  {m['name']}" for m in marks), flush=True)
        elif cmd[0] == "quit":
            break
        else:
            print("commands: off | on | press KEY | jump MARKER | markers | quit", flush=True)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
