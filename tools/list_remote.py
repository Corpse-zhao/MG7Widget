#!/usr/bin/env python3
"""列出远端仓库全部文件路径，用于核验多余/缺失文件。"""
import os, json, urllib.request, urllib.error

TOKEN = os.environ.get("GH_TOKEN", "")
API = "https://api.github.com"
REPO = "Corpse-zhao/MG7Widget"


def req(path):
    r = urllib.request.Request(API + path)
    r.add_header("Authorization", "Bearer " + TOKEN)
    r.add_header("Accept", "application/vnd.github+json")
    r.add_header("User-Agent", "mg7-ci")
    with urllib.request.urlopen(r, timeout=60) as resp:
        return json.loads(resp.read())


if __name__ == "__main__":
    tree = req(f"/repos/{REPO}/git/trees/main?recursive=1")
    print(f"truncated={tree.get('truncated')}")
    for t in sorted(tree["tree"], key=lambda x: x["path"]):
        if t["type"] == "blob":
            print(f"{t.get('size', 0):>8}  {t['path']}")
