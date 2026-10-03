#!/usr/bin/env python3
"""下载 CI artifact（手动处理 302 跳转，跳转后不带 Authorization）。"""
import os, sys, json, zipfile, io, urllib.request, urllib.error

TOKEN = os.environ.get("GH_TOKEN", "")
API = "https://api.github.com"
REPO = "Corpse-zhao/MG7Widget"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "artifacts")
OUT = os.path.abspath(OUT)
os.makedirs(OUT, exist_ok=True)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, msg, headers, fp)


def req(path):
    r = urllib.request.Request(API + path)
    r.add_header("Authorization", "Bearer " + TOKEN)
    r.add_header("Accept", "application/vnd.github+json")
    r.add_header("User-Agent", "mg7-ci")
    with urllib.request.urlopen(r, timeout=60) as resp:
        return json.loads(resp.read())


def download(url):
    opener = urllib.request.build_opener(NoRedirect)
    r = urllib.request.Request(url)
    r.add_header("Authorization", "Bearer " + TOKEN)
    r.add_header("User-Agent", "mg7-ci")
    try:
        opener.open(r, timeout=60)
        raise SystemExit("期望 302，却直接返回")
    except urllib.error.HTTPError as e:
        if e.code not in (301, 302, 307, 308):
            raise
        loc = e.headers.get("Location")
        r2 = urllib.request.Request(loc)
        r2.add_header("User-Agent", "mg7-ci")
        with urllib.request.urlopen(r2, timeout=300) as resp:
            return resp.read()


if __name__ == "__main__":
    run = req(f"/repos/{REPO}/actions/runs?per_page=1")["workflow_runs"][0]
    print(f"run #{run['run_number']} {run['status']}/{run['conclusion']}")
    arts = req(f"/repos/{REPO}/actions/runs/{run['id']}/artifacts")["artifacts"]
    for a in arts:
        print(f"下载 {a['name']} ({a['size_in_bytes']} bytes) ...")
        raw = download(a["archive_download_url"])
        # artifact 本身是个 zip，里面装着我们的文件
        zf = zipfile.ZipFile(io.BytesIO(raw))
        for n in zf.namelist():
            data = zf.read(n)
            dst = os.path.join(OUT, os.path.basename(n))
            with open(dst, "wb") as f:
                f.write(data)
            print(f"  -> {dst}  ({len(data)} bytes)")
