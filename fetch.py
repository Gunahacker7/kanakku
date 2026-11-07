#!/usr/bin/env python3
"""Fetch a maven artifact (pom + jar/aar + module metadata) into ~/local-maven.
Usage: fetch.py group:artifact:version [group:artifact:version ...]
Tries plugin portal m2, google maven, maven central — via curl (which can
cross the sandbox egress proxy, unlike Java's TLS stack)."""
import os
import re
import subprocess
import sys

REPO = os.path.expanduser("~/local-maven")
BASES = [
    "https://plugins.gradle.org/m2",
    "https://dl.google.com/dl/android/maven2",
    "https://repo.maven.apache.org/maven2",
    "https://storage.googleapis.com/download.flutter.io",
    "https://storage.googleapis.com/flutter_infra_release/flutter",
]


def fetch(url, dest):
    if os.path.exists(dest) and os.path.getsize(dest) > 0:
        return True
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    r = subprocess.run(
        ["curl", "-sSL", "-f", "-o", dest, "--max-time", "120", url],
        capture_output=True,
    )
    if r.returncode != 0:
        if os.path.exists(dest):
            os.remove(dest)
        return False
    return True


def fetch_parent_poms(pom_path, depth=0):
    """A fetched POM often declares a <parent> POM; grab the whole chain
    now instead of spending one gradle iteration per parent."""
    if depth > 6 or not os.path.exists(pom_path):
        return
    try:
        text = open(pom_path, encoding="utf-8", errors="ignore").read()
    except OSError:
        return
    m = re.search(r"<parent>(.*?)</parent>", text, re.S)
    if not m:
        return
    block = m.group(1)
    def tag(t):
        mm = re.search(rf"<{t}>([^<]+)</{t}>", block)
        return mm.group(1).strip() if mm else None
    g, a, v = tag("groupId"), tag("artifactId"), tag("version")
    if not (g and a and v) or "${" in v:
        return
    path = f"{g.replace('.', '/')}/{a}/{v}"
    dest = os.path.join(REPO, path, f"{a}-{v}.pom")
    if os.path.exists(dest):
        return
    for base in BASES:
        if fetch(f"{base}/{path}/{a}-{v}.pom", dest):
            print("PARENT", f"{g}:{a}:{v}")
            fetch_parent_poms(dest, depth + 1)
            return


def main(coords_list):
    for coords in coords_list:
        parts = coords.split(":")
        if len(parts) != 3:
            print(f"SKIP malformed: {coords}")
            continue
        g, a, v = parts
        path = f"{g.replace('.', '/')}/{a}/{v}"
        got_any = False
        for base in BASES:
            dest_dir = os.path.join(REPO, path)
            ok_pom = fetch(f"{base}/{path}/{a}-{v}.pom", f"{dest_dir}/{a}-{v}.pom")
            if not ok_pom:
                continue
            fetch_parent_poms(f"{dest_dir}/{a}-{v}.pom")
            # module metadata is optional but preferred by Gradle when present
            fetch(f"{base}/{path}/{a}-{v}.module", f"{dest_dir}/{a}-{v}.module")
            for ext in ("jar", "aar"):
                if fetch(f"{base}/{path}/{a}-{v}.{ext}", f"{dest_dir}/{a}-{v}.{ext}"):
                    got_any = True
                    break
            if ok_pom:
                got_any = True
                break
        print(("OK  " if got_any else "MISS"), coords)


def fetch_file(coords, filename):
    g, a, v = coords.split(":")
    path = f"{g.replace('.', '/')}/{a}/{v}"
    dest = os.path.join(REPO, path, filename)
    for base in BASES:
        if fetch(f"{base}/{path}/{filename}", dest):
            print("OK  ", coords, filename)
            return
    print("MISS", coords, filename)


if __name__ == "__main__":
    if len(sys.argv) >= 4 and sys.argv[1] == "--file":
        fetch_file(sys.argv[2], sys.argv[3])
    else:
        main(sys.argv[1:])
