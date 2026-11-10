#!/usr/bin/env python3
"""Record an XREAL One session for offline development (read-only).

Captures, with host timestamps:
  * replies to a fixed set of safe GET queries on the control channel (TCP 52999)
  * every frame the glasses send on the control channel during the session
    (button presses, wear/state events, telemetry)
  * the raw sensor stream (TCP 52998)
while voice prompts (macOS `say`) guide the wearer through head movements.

Nothing is ever written to the glasses except GET requests (body 18 00).

Usage:  python3 record_session.py [--host 169.254.2.1] [--out ../captures]
"""
import argparse
import json
import os
import socket
import struct
import subprocess
import sys
import threading
import time
from collections import Counter
from datetime import datetime, timezone

CONTROL_PORT, SENSOR_PORT = 52999, 52998
GET_BODY = b"\x18\x00"
# Read-only queries verified on One-series firmware by github.com/georgehorrell/xreal-one-cli.
SAFE_GETS = {
    "firmware_version": 0x271D,
    "dsp_version": 0x272D,
    "serial_number": 0x2729,
    "factory_config": 0x271F,
    "display_config": 0x275E,
}
SCRIPT = [  # (seconds, prompt, marker)
    (6, "Recording. Look straight ahead and keep your head still.", "still_center"),
    (7, "Slowly turn your head to the left, then back to the center.", "yaw_left"),
    (7, "Slowly turn your head to the right, then back to the center.", "yaw_right"),
    (6, "Slowly look up, then back to the center.", "pitch_up"),
    (6, "Slowly look down at the keyboard, then back to the center.", "pitch_down"),
    (7, "Tilt your head toward your left shoulder, then toward your right shoulder, then straight.", "roll"),
    (5, "Nod yes three times.", "nod"),
    (5, "Shake your head no three times.", "shake"),
    (6, "Quick glance left, quick glance right, then back to the center.", "fast_yaw"),
    (12, "Now look around freely, as if checking several screens around you.", "free_look"),
    (9, "Press brightness up once, then brightness down once.", "buttons"),
    (12, "Take the glasses off, wait two seconds, and put them back on.", "wear_off_on"),
    (5, "Look straight ahead and hold still.", "still_end"),
]


def say(text):
    print(f"  🔊 {text}", flush=True)
    try:
        return subprocess.Popen(["say", "-r", "185", text])
    except FileNotFoundError:
        return None


class Writer:
    """Thread-safe JSONL writer for frames."""

    def __init__(self, path, t0):
        self.f = open(path, "w")
        self.t0 = t0
        self.lock = threading.Lock()

    def frame(self, port, direction, data):
        magic = struct.unpack(">H", data[:2])[0] if len(data) >= 2 else None
        rec = {"t_ns": time.monotonic_ns() - self.t0, "port": port, "dir": direction,
               "magic": f"0x{magic:04x}" if magic is not None else None, "len": len(data), "hex": data.hex()}
        with self.lock:
            self.f.write(json.dumps(rec) + "\n")
        return rec

    def close(self):
        with self.lock:
            self.f.close()


def split_frames(buf):
    """Frames are magic(2, BE) | length(4, BE) | payload(length). Returns (frames, rest)."""
    out = []
    while len(buf) >= 6:
        length = struct.unpack(">I", buf[2:6])[0]
        if length > 4 * 1024 * 1024:  # desynchronised stream: keep raw bytes, stop framing
            raise ValueError(f"implausible frame length {length}")
        if len(buf) < 6 + length:
            break
        out.append(buf[:6 + length])
        buf = buf[6 + length:]
    return out, buf


def reader(sock, port, writer, raw_path, stop, counts):
    buf = b""
    with open(raw_path, "wb") as raw:
        while not stop.is_set():
            try:
                chunk = sock.recv(65536)
            except socket.timeout:
                continue
            except OSError:
                break
            if not chunk:
                break
            raw.write(chunk)
            buf += chunk
            try:
                frames, buf = split_frames(buf)
            except ValueError as e:
                print(f"  ! port {port}: {e}; raw bytes still recorded", file=sys.stderr)
                buf = b""
                continue
            for fr in frames:
                rec = writer.frame(port, "rx", fr)
                counts[(port, rec["magic"])] += 1


def static_queries(host, writer):
    results = {}
    with socket.create_connection((host, CONTROL_PORT), timeout=3) as s:
        s.settimeout(3)
        buf = b""
        for txid, (name, cmd) in enumerate(SAFE_GETS.items(), 1):
            req = struct.pack(">HII", cmd, len(GET_BODY) + 4, 0x80000000 | txid) + GET_BODY
            writer.frame(CONTROL_PORT, "tx", req)
            s.sendall(req)
            deadline = time.time() + 4
            reply = None
            while time.time() < deadline and reply is None:
                try:
                    chunk = s.recv(65536)
                except socket.timeout:
                    break
                if not chunk:
                    break
                buf += chunk
                frames, buf = split_frames(buf)
                for fr in frames:
                    writer.frame(CONTROL_PORT, "rx", fr)
                    magic = struct.unpack(">H", fr[:2])[0]
                    rtx = struct.unpack(">I", fr[6:10])[0] if len(fr) >= 10 else None
                    if magic == cmd and rtx == txid:
                        reply = fr[10:]
            results[name] = {"cmd": f"0x{cmd:04x}", "reply_hex": reply.hex() if reply is not None else None,
                             "reply_len": len(reply) if reply is not None else None}
            text = extract_string(reply) if reply else None
            if text and len(text) < 200:
                results[name]["string"] = text
            status = text if text and len(text) < 60 else (f"{len(reply)} bytes" if reply else "no reply")
            print(f"  {name:<17} {status}")
    return results


def extract_string(reply):
    """Response root 0x22 wraps a nested message; tag 0x12 carries a length-delimited string."""
    try:
        i = reply.index(0x12)
        n, shift, j = 0, 0, i + 1
        while True:
            b = reply[j]; j += 1
            n |= (b & 0x7F) << shift; shift += 7
            if not b & 0x80:
                break
        return reply[j:j + n].decode("utf-8")
    except (ValueError, IndexError, UnicodeDecodeError):
        return None


def summarize(out_dir, counts, meta):
    imu_ts = []
    max_gyro = 0.0
    with open(os.path.join(out_dir, "frames.jsonl")) as f:
        for line in f:
            r = json.loads(line)
            if r["port"] != SENSOR_PORT:
                continue
            fr = bytes.fromhex(r["hex"])
            # Layout per github.com/kevindurb/xreal-linux: u64 timestamp @14, u32 kind @30, 6×f32 gyro+accel @34.
            if len(fr) >= 58 and struct.unpack_from("<I", fr, 30)[0] == 0x0B:
                imu_ts.append(r["t_ns"])
                g = struct.unpack_from("<3f", fr, 34)
                max_gyro = max(max_gyro, sum(x * x for x in g) ** 0.5)
    span = (imu_ts[-1] - imu_ts[0]) / 1e9 if len(imu_ts) > 1 else 0
    summary = {
        **meta,
        "frames_by_port_and_magic": {f"{p}:{m}": c for (p, m), c in sorted(counts.items())},
        "imu_frames": len(imu_ts),
        "imu_rate_hz": round(len(imu_ts) / span, 1) if span else None,
        "max_gyro_rad_s": round(max_gyro, 3),
    }
    with open(os.path.join(out_dir, "summary.json"), "w") as f:
        json.dump(summary, f, indent=2)
    return summary


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="169.254.2.1")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "captures"))
    args = ap.parse_args()

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    out_dir = os.path.abspath(os.path.join(args.out, stamp))
    os.makedirs(out_dir)
    t0 = time.monotonic_ns()
    writer = Writer(os.path.join(out_dir, "frames.jsonl"), t0)
    meta = {"started_utc": datetime.now(timezone.utc).isoformat(), "host": args.host}

    print("1/2 Safe GET queries on the control channel")
    meta["static"] = static_queries(args.host, writer)
    with open(os.path.join(out_dir, "control_gets.json"), "w") as f:
        json.dump(meta["static"], f, indent=2)

    print("2/2 Guided head-movement session")
    stop, counts = threading.Event(), Counter()
    socks, threads = [], []
    for port in (CONTROL_PORT, SENSOR_PORT):
        s = socket.create_connection((args.host, port), timeout=3)
        s.settimeout(0.5)
        socks.append(s)
        th = threading.Thread(target=reader, args=(s, port, writer, os.path.join(out_dir, f"raw_{port}.bin"), stop, counts), daemon=True)
        th.start()
        threads.append(th)

    markers = []
    try:
        for seconds, prompt, marker in SCRIPT:
            markers.append({"t_ns": time.monotonic_ns() - t0, "marker": marker, "prompt": prompt, "seconds": seconds})
            p = say(prompt)
            time.sleep(seconds)
            if p:
                p.wait()
        markers.append({"t_ns": time.monotonic_ns() - t0, "marker": "end"})
        say("Done. Thank you.")
    except KeyboardInterrupt:
        markers.append({"t_ns": time.monotonic_ns() - t0, "marker": "interrupted"})
    finally:
        stop.set()
        for s in socks:
            s.close()
        for th in threads:
            th.join(timeout=2)
        writer.close()

    with open(os.path.join(out_dir, "markers.jsonl"), "w") as f:
        f.writelines(json.dumps(m) + "\n" for m in markers)
    meta["static"] = {k: {kk: vv for kk, vv in v.items() if kk != "reply_hex"} for k, v in meta["static"].items()}
    summary = summarize(out_dir, counts, meta)
    print(json.dumps({k: summary[k] for k in ("frames_by_port_and_magic", "imu_frames", "imu_rate_hz", "max_gyro_rad_s")}, indent=2))
    print(f"Saved to {out_dir}")


if __name__ == "__main__":
    main()
