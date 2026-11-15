#!/usr/bin/env python3
"""Reads the unified log of Interspace and prints timing statistics of real swipes.

Usage:
  /usr/bin/log show --predicate 'subsystem == "com.cnrad.interspace"' --info --debug --last 3d --style compact > applog.txt
  python3 analyze_logs.py applog.txt [--pid N] [--speed 0.9]

It changes nothing and needs no permission: the app writes these lines itself.
"""
import re, sys, math, statistics as st
from datetime import datetime
from collections import Counter, defaultdict

path = sys.argv[1]
only_pid = int(sys.argv[sys.argv.index("--pid") + 1]) if "--pid" in sys.argv else None
speed = float(sys.argv[sys.argv.index("--speed") + 1]) if "--speed" in sys.argv else 1.0

LINE = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3}) (\w+)\s+(?:[Ii]nterspace|SpaceGlide)\[(\d+):\w+\] \[com\.cnrad\.(?:interspace|spaceglide):(\w+)\] (.*)$")
events = []
for raw in open(path, errors="replace"):
    m = LINE.match(raw.rstrip("\n"))
    if not m:
        continue
    t = datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S.%f").timestamp()
    pid = int(m.group(3))
    if only_pid and pid != only_pid:
        continue
    events.append((t, pid, m.group(4), m.group(5)))

def pct(values, p):
    if not values:
        return float("nan")
    s = sorted(values)
    k = (len(s) - 1) * p / 100
    f, c = math.floor(k), math.ceil(k)
    return s[f] + (s[c] - s[f]) * (k - f)

def describe(name, values, unit="ms"):
    if not values:
        print(f"  {name}: no data")
        return
    print(f"  {name}: n={len(values)}  min {min(values):.0f}  p50 {pct(values,50):.0f}  p90 {pct(values,90):.0f}  "
          f"p99 {pct(values,99):.0f}  max {max(values):.0f} {unit}")

def spring_time(start, velocity, speed, hz=120.0, response=0.19, stop=0.0015):
    """Milliseconds until the picture is `stop` from rest: the earliest moment the fade can start."""
    omega = 2 * math.pi / response * speed
    k, c = omega * omega, 2 * omega
    p, v, t = start, max(min(velocity, 8), -8), 0.0
    while t < 3:
        remaining = 1 / hz
        while remaining > 1e-12:
            step = min(remaining, 0.002)
            v += (-k * p - c * v) * step
            p += v * step
            remaining -= step
        t += 1 / hz
        if abs(p) < stop:
            return t * 1000
    return float("nan")

print(f"{len(events)} log lines" + (f" of pid {only_pid}" if only_pid else "") +
      f", {len(set(e[1] for e in events))} launches, spring speed assumed {speed}")
if not events:
    sys.exit(0)
print(f"from {datetime.fromtimestamp(events[0][0])} to {datetime.fromtimestamp(events[-1][0])}\n")

END = re.compile(r"end: progress (-?[\d.e-]+) velocity (-?[\d.e-]+) target (-?\d+) overlay (\w+) captureFinished (\w+) captureFailed (\w+)")
FADE = re.compile(r"(fade|cut) starts (-?\d+) ms after release, from (-?[\d.e-]+); Dock showed the new space after (-?\d+) ms")
CAUGHT = re.compile(r"begin: caught the overlay in phase (\w+) at progress (-?[\d.e-]+)")
KEY_IN = re.compile(r"key: direction (-?\d+) in phase (\w+)")
DRAG = re.compile(r"drag: (\d+) frames in (-?\d+) ms, longest gap ([\d.]+) ms, first picture (-?\d+) ms after touch down")
SNAP = re.compile(r"snap: (\d+) frames, longest gap ([\d.]+) ms, lost (\d+), frame time ([\d.]+) ms")
SLOW_UNPACK = re.compile(r"unpacked an image in the transition: (\d+) ms")
VISIT_START = re.compile(r"visit start: (\d+) spaces, on index (\d+), route \[(.*)\]")

ends, fades = [], []
switch_fade, cancel_fade, cut = [], [], []
dock, overhead, overhead_rows = [], [], []
no_overlay_release = late_snapshot = failed = 0
caught = Counter()
key_starts = key_in_flight = 0
no_overlay_switch = 0
problems = Counter()
visits, launches = [], defaultdict(dict)
last_end = {}
visit_open = {}
switch_times = []          # (time, pid, target) of committed switches
refreshes = 0

drag_gaps, first_pictures, snap_gaps, snap_lost, snap_frames, slow_unpacks = [], [], [], [], [], []

for t, pid, cat, msg in events:
    m = DRAG.match(msg)
    if m:
        drag_gaps.append(float(m.group(3)))
        if int(m.group(4)) >= 0:
            first_pictures.append(int(m.group(4)))
        continue
    m = SNAP.match(msg)
    if m:
        snap_frames.append(int(m.group(1)))
        # In frame times, so displays of 60 Hz and 120 Hz compare.
        snap_gaps.append(float(m.group(2)) / max(float(m.group(4)), 0.1))
        snap_lost.append(int(m.group(3)))
        continue
    m = SLOW_UNPACK.match(msg)
    if m:
        slow_unpacks.append(int(m.group(1)))
        continue
    m = END.match(msg)
    if m:
        progress, velocity, target = float(m.group(1)), float(m.group(2)), int(m.group(3))
        overlay, finished, fail = m.group(4) == "true", m.group(5) == "true", m.group(6) == "true"
        ends.append((t, progress, velocity, target))
        last_end[pid] = (t, progress, velocity, target)
        if not overlay:
            no_overlay_release += 1
        if not finished:
            late_snapshot += 1
        if fail:
            failed += 1
        if target != 0:
            switch_times.append((t, pid, target))
        continue
    m = FADE.match(msg)
    if m:
        kind, ms, start, dock_ms = m.group(1), int(m.group(2)), float(m.group(3)), int(m.group(4))
        fades.append((t, kind, ms, start, dock_ms))
        if kind == "cut":
            cut.append(ms)
        # Only a release that is the direct cause of this fade (no key press or catch between) has a known velocity.
        end = last_end.get(pid)
        if dock_ms >= 0:
            dock.append(dock_ms)
            switch_fade.append(ms)
        else:
            cancel_fade.append(ms)
        if end and abs((t - ms / 1000) - end[0]) < 0.03 and kind == "fade":
            ideal = spring_time(start, end[2], speed)
            if not math.isnan(ideal):
                overhead.append(ms - ideal)
                overhead_rows.append((ms - ideal, ms, ideal, start, end[2], dock_ms, t))
        continue
    m = CAUGHT.match(msg)
    if m:
        caught[m.group(1)] += 1
        continue
    m = KEY_IN.match(msg)
    if m:
        key_in_flight += 1
        switch_times.append((t, pid, int(m.group(1))))
        continue
    if msg.startswith("key: start"):
        key_starts += 1
        d = re.search(r"direction (-?\d+)", msg)
        if d:
            switch_times.append((t, pid, int(d.group(1))))
        continue
    if msg.startswith("switch with no overlay"):
        no_overlay_switch += 1
        continue
    m = VISIT_START.match(msg)
    if m:
        visit_open[pid] = (t, int(m.group(1)), len([x for x in m.group(3).split(",") if x.strip()]))
        launches[pid].setdefault("visit_start", t)
        continue
    if msg.startswith("visit end"):
        if pid in visit_open:
            start, spaces, hops = visit_open.pop(pid)
            visits.append({"start": start, "end": t, "spaces": spaces, "hops": hops, "pid": pid, "uncover": None})
            launches[pid].setdefault("visit_end", t)
        continue
    if msg.startswith("opens at login"):
        launches[pid].setdefault("first_log", t)
        continue
    if msg.startswith("active="):
        if "active=true" in msg:
            launches[pid].setdefault("active", t)
        continue
    if msg.startswith("refreshed the image"):
        refreshes += 1
        continue
    for needle in ("did not reach", "reset with the overlay visible", "replaced the overlay window",
                   "list of spaces changed", "stopped reporting", "still changing", "open at login:"):
        if needle in msg:
            problems[needle] += 1

# The cover of a visit goes away at the first fade or cut after `visit end`.
for visit in visits:
    for t, kind, ms, start, dock_ms in fades:
        if t >= visit["end"] and t - visit["end"] < 3:
            visit["uncover"] = t
            visit["kind"] = kind
            break

print("== Swipes ==")
committed = [e for e in ends if e[3] != 0]
print(f"  releases: {len(ends)}  ({len(committed)} switched, {len(ends) - len(committed)} snapped back)")
print(f"  keyboard: {key_starts} started a transition, {key_in_flight} pressed during one")
print(f"  release with no overlay on screen yet: {no_overlay_release}   release before the snapshot was ready: {late_snapshot}"
      f"   snapshot failed: {failed}   switched with no transition at all: {no_overlay_switch}")
print(f"  caught in flight by a new swipe: {sum(caught.values())}  {dict(caught)}")

print("\n== Release to hand-off (the overlay starts to go away) ==")
describe("after a switch", switch_fade)
describe("after a snap back", cancel_fade)
describe("Dock showed the new space after", dock)
print(f"  removed by a cut and not a fade (overlay was up > 0.8 s): {len(cut)} of {len(fades)}")
if switch_fade:
    for limit in (250, 300, 400, 600):
        share = sum(1 for v in switch_fade if v > limit) / len(switch_fade) * 100
        print(f"    slower than {limit} ms: {share:.1f}%")

print("\n== Wait on top of the spring (hand-off time minus the time the spring needs) ==")
describe("extra wait", overhead)
if overhead:
    for limit in (17, 50, 100, 200):
        share = sum(1 for v in overhead if v > limit) / len(overhead) * 100
        print(f"    more than {limit} ms: {share:.1f}%")
    print("  worst:")
    for row in sorted(overhead_rows, reverse=True)[:8]:
        print(f"    +{row[0]:.0f} ms  (hand-off {row[1]} ms, spring {row[2]:.0f} ms, from {row[3]:.2f}, velocity {row[4]:.1f}, "
              f"Dock {row[5]} ms)  {datetime.fromtimestamp(row[6]).strftime('%m-%d %H:%M:%S')}")

print("\n== Time between two switches (how old the image of the space you come back to is) ==")
# Position by dead reckoning per launch; age = time since that position was last left.
ages = []
by_pid = defaultdict(list)
for t, pid, target in sorted(switch_times):
    by_pid[pid].append((t, target))
for pid, steps in by_pid.items():
    position, left_at = 0, {}
    for t, target in steps:
        left_at[position] = t
        position += target
        if position in left_at:
            ages.append(t - left_at[position])
describe("age of the image shown for the destination", [a for a in ages], unit="s")
if ages:
    for limit in (5, 30, 120, 600):
        share = sum(1 for a in ages if a > limit) / len(ages) * 100
        print(f"    older than {limit} s: {share:.0f}%")
gaps = [b[0] - a[0] for a, b in zip(sorted(switch_times), sorted(switch_times)[1:]) if b[1] == a[1]]
quick = sum(1 for g in gaps if g < 0.4)
print(f"  switches less than 0.4 s after the one before: {quick} of {len(gaps)}")
print(f"  'refreshed the image' lines (info level, not kept on disk for long): {refreshes}")

print("\n== Visit of all spaces (the screen is a frozen picture during this) ==")
describe("visit start to visit end", [(v["end"] - v["start"]) * 1000 for v in visits])
describe("visit start to cover gone", [(v["uncover"] - v["start"]) * 1000 + 80 for v in visits if v["uncover"]])
per_hop = [(v["end"] - v["start"]) * 1000 / v["hops"] for v in visits if v["hops"]]
describe("per space switch", per_hop)
print(f"  cover removed by cut: {sum(1 for v in visits if v.get('kind') == 'cut')}, by fade: {sum(1 for v in visits if v.get('kind') == 'fade')}, "
      f"no hand-off line within 3 s: {sum(1 for v in visits if not v['uncover'])}")

print("\n== Launch ==")
rows = [l for l in launches.values() if "first_log" in l]
describe("first log line to 'active'", [(l["active"] - l["first_log"]) * 1000 for l in rows if "active" in l])
describe("first log line to visit start", [(l["visit_start"] - l["first_log"]) * 1000 for l in rows if "visit_start" in l])
describe("first log line to all spaces captured", [(l["visit_end"] - l["first_log"]) * 1000 for l in rows if "visit_end" in l])

print("\n== Stutter (frame timing in the app's own process) ==")
if drag_gaps or snap_gaps:
    describe("drag: longest time between two touch frames, per swipe", drag_gaps)
    late = sum(1 for v in drag_gaps if v > 25)
    print(f"    swipes with a gap over 25 ms under the fingers: {late} of {len(drag_gaps)}")
    describe("touch down to the first picture", first_pictures)
    describe("snap: longest time between two frames, per snap", snap_gaps, unit="frame times")
    with_loss = sum(1 for v in snap_lost if v > 0)
    print(f"    snaps that lost a frame: {with_loss} of {len(snap_lost)}   frames lost: {sum(snap_lost)} of {sum(snap_frames)}")
    print(f"    images unpacked on the main thread in a transition: {len(slow_unpacks)}"
          + (f" (longest {max(slow_unpacks)} ms)" if slow_unpacks else ""))
else:
    print("  no 'drag:' or 'snap:' lines: this build of the app does not write them yet")

print("\n== Fault lines ==")
if problems:
    for needle, count in problems.most_common():
        print(f"  {count:4d}  {needle}")
else:
    print("  none")
