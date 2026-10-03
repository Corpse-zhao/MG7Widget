#!/usr/bin/env python3
"""CI 日志拉取工具：列出 run / job，拉取失败步骤日志（手动处理 302 跳转，跳转后不带 Authorization）"""
import os, sys, json, urllib.request, urllib.error

TOKEN = os.environ.get("GH_TOKEN", "")
if not TOKEN:
    # 从 git remote 兜底读取
    import subprocess
    try:
        url = subprocess.check_output(["git", "remote", "get-url", "origin"], text=True).strip()
        import re
        m = re.search(r"https://([^@]+)@", url)
        if m:
            TOKEN = m.group(1).split(":")[-1]
    except Exception:
        pass

API = "https://api.github.com"
REPO = "Corpse-zhao/MG7Widget"


def req(path, raw=False):
    r = urllib.request.Request(API + path)
    r.add_header("Authorization", "Bearer " + TOKEN)
    r.add_header("Accept", "application/vnd.github.raw" if raw else "application/vnd.github+json")
    r.add_header("User-Agent", "mg7-ci")
    with urllib.request.urlopen(r, timeout=60) as resp:
        data = resp.read()
    return data if raw else json.loads(data)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, msg, headers, fp)


def signed_get(path):
    """取日志：先拿 302 Location（带 Authorization 会被拒），再不带 Authorization 请求"""
    opener = urllib.request.build_opener(NoRedirect)
    r = urllib.request.Request(API + path)
    r.add_header("Authorization", "Bearer " + TOKEN)
    r.add_header("User-Agent", "mg7-ci")
    try:
        opener.open(r, timeout=60)
        return None
    except urllib.error.HTTPError as e:
        if e.code in (301, 302, 307, 308):
            loc = e.headers.get("Location")
            if loc:
                r2 = urllib.request.Request(loc)
                r2.add_header("User-Agent", "mg7-ci")
                with urllib.request.urlopen(r2, timeout=120) as resp:
                    return resp.read().decode("utf-8", "replace")
        raise


if __name__ == "__main__":
    runs = req(f"/repos/{REPO}/actions/runs?per_page=5")["workflow_runs"]
    for r in runs:
        print(f"run #{r['run_number']} {r['status']}/{r['conclusion']} id={r['id']} sha={r['head_sha'][:8]} {r['created_at']}")
    print("-" * 60)
    rid = runs[0]["id"]
    jobs = req(f"/repos/{REPO}/actions/runs/{rid}/jobs")["jobs"]
    for j in jobs:
        print(f"JOB {j['name']} {j['status']}/{j['conclusion']} id={j['id']}")
        for s in j["steps"]:
            print(f"   [{s['conclusion']}] {s['name']}")
        if j["conclusion"] == "failure":
            log = signed_get(f"/repos/{REPO}/actions/jobs/{j['id']}/logs")
            if log:
                p = os.path.join(os.path.dirname(__file__), "ci_log_run.txt")
                open(p, "w", encoding="utf-8").write(log)
                print(f"   日志已保存 -> {p} ({len(log)} chars)")
