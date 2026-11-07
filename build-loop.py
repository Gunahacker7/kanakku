#!/usr/bin/env python3
"""Build loop: run gradle, harvest missing artifact coords, curl-fetch them
into ~/local-maven, repeat until the build succeeds or stalls."""
import os
import re
import subprocess
import sys

APP_ANDROID = os.path.expanduser("~/workspace/kanakku-project/app/android")
FETCH = os.path.expanduser("~/workspace/kanakku-project/fetch.py")
ENV = dict(
    os.environ,
    JAVA_HOME=os.path.expanduser("~/jdk"),
    ANDROID_HOME=os.path.expanduser("~/android-sdk"),
    GRADLE_USER_HOME=os.path.expanduser("~/.gradle"),
    TAR_OPTIONS="--no-same-owner",
)
PATTERNS = [
    re.compile(r"could not resolve plugin artifact '([\w.\-]+:[\w.\-]+:[\w.\-]+)'", re.I),
    re.compile(r"Could not resolve ([\w.\-]+:[\w.\-]+:[\w.\-]+)\.", re.I),
    re.compile(r"Could not find ([\w.\-]+:[\w.\-]+:[\w.\-]+)\.", re.I),
    re.compile(r"Could not resolve ([\w.\-]+:[\w.\-]+:[\w.\-]+)\s", re.I),
    re.compile(r"Could not download [\w.\-]+ \(([\w.\-]+:[\w.\-]+:[\w.\-]+(?::[\w.\-]+)?)\)", re.I),
    re.compile(r"no cached version of ([\w.\-]+:[\w.\-]+:[\w.\-]+)", re.I),
    re.compile(r"Could not parse POM [^\n]*\n[^\n]*Could not resolve ([\w.\-]+:[\w.\-]+:[\w.\-]+)", re.I),
    re.compile(r"Could not find ([\w.\-]+\.(?:jar|aar|pom)) \(([\w.\-]+:[\w.\-]+:[\w.\-]+)\)", re.I),
]

seen = set()
# Clear stale daemons + journal lock from earlier manual runs; lingering
# daemons (3h idle timeout) otherwise block every new build.
subprocess.run([sys.executable, os.path.expanduser("~/kill-gradle.py")], capture_output=True)
import time
time.sleep(2)
_lock = os.path.expanduser("~/.gradle/caches/journal-1/journal-1.lock")
if os.path.exists(_lock):
    os.remove(_lock)
for i in range(60):
    p = subprocess.run(
        ["./gradlew", "assembleDebug", "--refresh-dependencies"],
        cwd=APP_ANDROID, env=ENV, capture_output=True, text=True, timeout=900,
    )
    out = p.stdout + p.stderr
    if p.returncode == 0:
        print(f"[{i}] BUILD SUCCESS")
        sys.exit(0)
    coords = set()
    files = set()
    for pat in PATTERNS:
        for m in pat.findall(out):
            if isinstance(m, tuple):
                files.add(m)  # (filename, coords)
            else:
                coords.add(m.rstrip("."))
    coords = {c for c in coords if c not in seen}
    files = {f for f in files if f"{f[1]}|{f[0]}" not in seen}
    print(f"[{i}] build failed; new missing: {sorted(coords)}; files: {sorted(files)}")
    if not coords and not files:
        tail = "\n".join(out.splitlines()[-25:])
        print("NO NEW COORDS — failure tail:\n", tail)
        sys.exit(1)
    seen.update(coords)
    seen.update(f"{c}|{fn}" for fn, c in files)
    if coords:
        r = subprocess.run([sys.executable, FETCH, *sorted(coords)], capture_output=True, text=True)
        print(r.stdout.strip())
    for fn, c in sorted(files):
        r = subprocess.run([sys.executable, FETCH, "--file", c, fn], capture_output=True, text=True)
        print(r.stdout.strip())
print("iteration cap reached")
sys.exit(1)
