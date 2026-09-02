#!/usr/bin/env python3
"""maven_install.json に載っている jar を derived/maven へ取ってくる。

compile.sh は derived/maven と derived/jars から classpath を組むが、その二つは
dist archive にしか無い。derived/maven の中身は //:maven-srcs という pkg_tar が
作るもので、それを作るには bazel が要る — つまり bazel を建てるのに要る jar を
bazel でしか作れない。

代わりの経路が一つだけある。maven_install.json は artifact と版と sha256 を
全部持っているので、Maven Central から直に取れる。bazel も dist archive も
要らない。

    python3 fetch-maven.py <木の根> [<置き場>]
"""
import hashlib
import json
import os
import sys
import urllib.request

REPOS = [
    "https://repo1.maven.org/maven2",
    "https://maven.google.com",
]


def coordinates(name, version):
    group, artifact = name.split(":", 1)
    path = group.replace(".", "/")
    return f"{path}/{artifact}/{version}/{artifact}-{version}.jar"


def fetch(rel, want, out):
    for repo in REPOS:
        url = f"{repo}/{rel}"
        try:
            with urllib.request.urlopen(url, timeout=60) as r:
                blob = r.read()
        except Exception:
            continue
        got = hashlib.sha256(blob).hexdigest()
        if want and got != want:
            print(f"  sha が合わない {rel}\n    want {want}\n    got  {got}")
            return False
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with open(out, "wb") as fh:
            fh.write(blob)
        return True
    return False


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    dest = sys.argv[2] if len(sys.argv) > 2 else os.path.join(root, "derived", "maven")
    with open(os.path.join(root, "maven_install.json"), encoding="utf-8") as fh:
        data = json.load(fh)

    artifacts = data.get("artifacts", {})
    ok = skipped = failed = 0
    for name, info in sorted(artifacts.items()):
        sha = info.get("shasums", {}).get("jar")
        if not sha:
            # sources や aar しか無いものは classpath に要らない
            skipped += 1
            continue
        rel = coordinates(name, info["version"])
        out = os.path.join(dest, rel)
        if os.path.exists(out):
            ok += 1
            continue
        if fetch(rel, sha, out):
            ok += 1
        else:
            print(f"  取れない {name} {info['version']}")
            failed += 1
    print(f"maven: {ok} 個 取れた / {skipped} 個 jar 無し / {failed} 個 失敗")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
