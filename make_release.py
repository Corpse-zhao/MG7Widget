# -*- coding: utf-8 -*-
"""把 .tipa 发成 GitHub Release 直链（手机可直接下载）。
用法: python make_release.py <tag> "<release 名称>" [要上传的文件...]
"""
import json, os, sys, time, urllib.error, urllib.parse, urllib.request

TOKEN = os.environ.get("GH_TOKEN", "")
if not TOKEN:
    raise SystemExit("请设置环境变量 GH_TOKEN")
API = "https://api.github.com"
REPO = "Corpse-zhao/MG7Widget"

TAG = sys.argv[1] if len(sys.argv) > 1 else "v0.4.1"
NAME = sys.argv[2] if len(sys.argv) > 2 else "MG7 车况小组件 v0.4.1"
FILES = sys.argv[3:] or ["artifacts/MG7Widget-0.4.1.tipa"]

BODY = """## 安装方法（TrollStore）

1. 手机点下面的 `.tipa` 直链下载（Safari 会存到"文件"App）
2. 用 **TrollStore** 打开 → Install
3. 装完后到「设置 → 通用 → VPN与设备管理」信任（如需要）
4. 打开 App，填 token / VIN，再进「设置」填 user_id = `1510000062021`
5. 桌面长按 → 添加小组件 → 选 MG7

## 本版改动

- **控车请求头 100% 对齐 MG Live 实测**：补齐 `Uuid` / `Model=ehs` / `brandCode=2` /
  `Accept-Language` / `Accept-Encoding` / `osVersion` / `watch-man-mobile` /
  `watch-man-token`，`watch-man-check-type` 由 `ios` 改 `IOS`，
  `timestamp` 头改为**秒级取整**（MG Live 实测行为）
- 修复 Widget 目标 iOS 15 编译错误（`String.split` 需 iOS 16，改用 `range(of:)`）

> 控车仍建议填 `user_id`；若填了仍无效，就是 `sign` 头的问题，下一版处理。
"""


def call(method, path, payload=None, ok404=False):
    req = urllib.request.Request(API + path, method=method)
    req.add_header("Authorization", "token " + TOKEN)
    req.add_header("Accept", "application/vnd.github+json")
    data = None
    if payload is not None:
        data = json.dumps(payload).encode()
        req.add_header("Content-Type", "application/json")
    for _ in range(3):
        try:
            with urllib.request.urlopen(req, data=data, timeout=90) as r:
                return json.loads(r.read().decode() or "{}")
        except urllib.error.HTTPError as e:
            body = e.read().decode(errors="replace")
            if e.code in (404, 409, 422) and ok404:
                return {}
            print("HTTP", e.code, method, path, body[:300], file=sys.stderr)
            time.sleep(2)
    raise SystemExit("API 失败: " + path)


# 1) 建 / 取 release（幂等）
rel = call("POST", "/repos/%s/releases" % REPO,
           {"tag_name": TAG, "target_commitish": "main",
            "name": NAME, "body": BODY, "draft": False}, ok404=True)
if not rel.get("id"):
    rel = call("GET", "/repos/%s/releases/tags/%s" % (REPO, TAG))
RID = rel["id"]
print("release id:", RID, rel.get("html_url"))

# 2) 先删同名旧资产，避免出现 foo.tipa / foo-1.tipa 两个
#    ⚠️ GET /releases/{id}/assets 返回的是数组，不是 {"assets":[...]}
assets = call("GET", "/repos/%s/releases/%d/assets" % (REPO, RID))
if isinstance(assets, dict):
    assets = assets.get("assets", [])
for a in assets:
    call("DELETE", "/repos/%s/releases/assets/%d" % (REPO, a["id"]), ok404=True)
    print("已删旧资产:", a["name"])

# 3) 上传
for path in FILES:
    if not os.path.isfile(path):
        print("跳过(不存在):", path)
        continue
    fn = os.path.basename(path)
    with open(path, "rb") as f:
        blob = f.read()
    url = "https://uploads.github.com/repos/%s/releases/%d/assets?name=%s" % (
        REPO, RID, urllib.parse.quote(fn))
    req = urllib.request.Request(url, method="POST", data=blob)
    req.add_header("Authorization", "token " + TOKEN)
    req.add_header("Content-Type", "application/octet-stream")
    req.add_header("Content-Length", str(len(blob)))
    for _ in range(3):
        try:
            with urllib.request.urlopen(req, timeout=300) as r:
                up = json.loads(r.read().decode())
            print("已上传:", fn, up.get("size"), "->", up.get("browser_download_url"))
            break
        except urllib.error.HTTPError as e:
            print("上传失败", e.code, e.read().decode(errors="replace")[:200], file=sys.stderr)
            time.sleep(3)

# 4) 复核 release name（PATCH 常被 500 吞掉）
for _ in range(6):
    r = call("PATCH", "/repos/%s/releases/%d" % (REPO, RID), {"name": NAME, "body": BODY})
    if r.get("name") == NAME:
        break
    time.sleep(2)
final = call("GET", "/repos/%s/releases/%d" % (REPO, RID))
print("release name =", final.get("name"))
assert final.get("name") == NAME, "release name 未生效！"
print("RELEASE_OK")
