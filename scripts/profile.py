#!/usr/bin/env python3
"""Profile generated local mail. No provider or account access."""
import argparse
import json
import pathlib
import subprocess
import time
import ctypes
import os
import signal
import plistlib
import shutil

parser = argparse.ArgumentParser()
parser.add_argument("--app", type=pathlib.Path, required=True)
parser.add_argument("--data", type=pathlib.Path, required=True)
parser.add_argument("--output", type=pathlib.Path, required=True)
parser.add_argument("--runs", type=int, default=3)
parser.add_argument("--html", action="store_true")
parser.add_argument("--html-idle", action="store_true")
parser.add_argument("--stress", action="store_true")
parser.add_argument("--heap", action="store_true")
parser.add_argument("--visible-only", action="store_true")
parser.add_argument("--calendar", action="store_true")
parser.add_argument("--media-fixture", type=pathlib.Path)
parser.add_argument("--calendar-actions", action="store_true")
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
results = []
# Diagnostic lookup only. The shipping app uses no private APIs.
responsible = ctypes.CDLL(None).responsibility_get_pid_responsible_for_pid
responsible.argtypes = [ctypes.c_int]
responsible.restype = ctypes.c_int

def process_family(pid):
    family = [pid]
    listing = subprocess.check_output(["ps", "-ww", "-axo", "pid=,comm="], text=True)
    for line in listing.splitlines():
        candidate, _, name = line.strip().partition(" ")
        if int(candidate) != pid and responsible(int(candidate)) == pid:
            family.append(int(candidate))
    return family

for run in range(args.runs):
    # Isolate LaunchServices identity and saved state from the user's running app.
    bundle = args.output.resolve() / f"probe-{run + 1}-{time.time_ns()}.app"
    shutil.copytree(args.app.resolve().parents[2], bundle)
    info_path = bundle / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info["CFBundleIdentifier"] = f"com.finwarman.squaremail.probe.{time.time_ns()}"
    info_path.write_bytes(plistlib.dumps(info))
    subprocess.run(["codesign", "--force", "--sign", "-", str(bundle)], capture_output=True, check=True)
    run_app = bundle / "Contents/MacOS" / info["CFBundleExecutable"]
    report = args.output / f"run-{run + 1}.json"
    report.unlink(missing_ok=True)
    log_path = (args.output / f"run-{run + 1}.log").resolve()
    before = {int(line.split()[0]) for line in subprocess.check_output(["ps", "-ww", "-axo", "pid="], text=True).splitlines()}
    app_pid = None
    with log_path.open("w") as log:
        start = time.monotonic()
        flags = (["--perf-html"] if args.html else []) + (["--perf-html-idle"] if args.html_idle else []) + (["--perf-stress"] if args.stress else []) + (["--perf-visible-only"] if args.visible_only else []) + (["--perf-calendar"] if args.calendar else [])
        if args.calendar_actions:
            flags += ["--check-calendar-actions", "--preview-calendar-actions", "--perf-actions"]
        if args.media_fixture:
            flags += ["--check-media", str(args.media_fixture.resolve()), "--preview-media", "--perf-media"]
        process = subprocess.Popen(["/usr/bin/open", "-n", "-W", "--stdout", str(log_path), "--stderr", str(log_path),
                                    str(bundle), "--args", "--data-dir", str(args.data.resolve()),
                                    "--perf-report", str(report.resolve()), "--layer-report"] + flags, stdout=log, stderr=log)
        try:
            deadline = start + (120 if args.stress else 60)
            ready = None
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError(f"App exited before completing measurements: {process.returncode}")
                if report.exists():
                    result = json.loads(report.read_text())
                    app_pid = result.get("pid")
                    if app_pid is None:
                        listing = subprocess.check_output(["ps", "-ww", "-axo", "pid=,comm="], text=True)
                        matches = [int(line.split()[0]) for line in listing.splitlines()
                                   if str(run_app) in line and int(line.split()[0]) not in before]
                        if len(matches) != 1:
                            raise RuntimeError("Could not identify the owned native benchmark process")
                        app_pid = matches[0]
                    if ready is None:
                        ready = (time.monotonic() - start) * 1000
                    if result["measurement_complete"]:
                        break
                time.sleep(0.005)
            else:
                raise TimeoutError("Native benchmark exceeded 60 seconds")
            # Sample after startup autorelease pools and redraws have settled.
            time.sleep(2)
            rss = subprocess.check_output(["ps", "-o", "rss=", "-p", str(app_pid)], text=True)
            family = process_family(app_pid)
            targets = [arg for pid in family for arg in ("-p", str(pid))]
            footprint = subprocess.run(["footprint"] + targets + ["-j",
                                        str(args.output / f"footprint-{run + 1}.json")], capture_output=True, text=True, check=True)
            (args.output / f"footprint-{run + 1}.log").write_text(footprint.stdout + footprint.stderr)
            result["launcher_observed_ready_ms"] = ready
            result["steady_rss_mib"] = int(rss.strip()) / 1024
            memory = json.loads((args.output / f"footprint-{run + 1}.json").read_text())
            result["family_footprint_mib"] = sum(item["footprint"] for item in memory["processes"]) / 1048576
            result["app_owned_helpers"] = len(family) - 1
            names = subprocess.check_output(["ps", "-o", "comm=", "-p", ",".join(map(str, family))], text=True)
            result["webkit_helpers"] = sum("WebKit" in name for name in names.splitlines())
            if args.heap:
                heap = subprocess.run(["heap", "-sortBySize", str(app_pid)], capture_output=True, text=True, timeout=30)
                (args.output / f"heap-{run + 1}.log").write_text(heap.stdout + heap.stderr)
            results.append(result)
        finally:
            if app_pid is None:
                listing = subprocess.check_output(["ps", "-ww", "-axo", "pid=,comm="], text=True)
                matches = [int(line.split()[0]) for line in listing.splitlines()
                           if str(run_app) in line and int(line.split()[0]) not in before]
                if len(matches) == 1:
                    app_pid = matches[0]
            if app_pid is not None:
                try:
                    os.kill(app_pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            else:
                process.terminate()
            process.wait(timeout=10)
(args.output / "summary.json").write_text(json.dumps(results, indent=2))
print(json.dumps(results, indent=2))
