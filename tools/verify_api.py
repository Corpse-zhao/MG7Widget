#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
MGLiveWidget - P0 接口验证脚本 v2
按 2026-10-03 真实抓包（Stream, MG Live 2.1.7 iOS）校准：
  - token 头名就叫 token，值以 -prod_SAIC 结尾
  - 请求体格式 application/x-www-form-urlencoded
  - 路径前缀 /app-mp/
  - 带 userid / sign / timestamp 等头

用法：填好 CONFIG，python verify_api.py
"""

import json
import sys
import time
import urllib.request
import urllib.error
import urllib.parse

# ============ 填写区 ============
ACCESS_TOKEN = "7a35805fd3f04937ac1b0e0c8e20dd08-prod_SAIC"
USER_ID      = "15100000062021"
VIN          = "LSJW4W90SZ187922"
# ================================

DOMAIN_APP  = "https://mp.ebanma.com"
DOMAIN_CAPI = "https://capi-pv.saicmotor.com"
TIMEOUT = 20

# 按真实抓包复刻的头部
def base_headers():
    return {
        "User-Agent":    "MGProject_PD/2.1.7 (iPhone; iOS 16.6; Scale/3.00)",
        "token":         ACCESS_TOKEN,
        "userid":        USER_ID,
        "channelID":     "MG",
        "X-client-id":   "App",
        "app-type":      "mgapp",
        "os":            "iOS",
        "versionCode":   "2.1.7",
        "Model":         "ehs",
        "brandcode":     "2",
        "Accept-Language": "zh-cn",
        "Accept":        "*/*",
        "watch-man-check-type": "IOS",
    }


def req(url, method="GET", form=None, extra_headers=None):
    """发请求。form: dict → urlencoded body"""
    h = base_headers()
    data = None
    if form is not None:
        data = urllib.parse.urlencode(form).encode()
        h["Content-Type"] = "application/x-www-form-urlencoded"
    if extra_headers:
        h.update(extra_headers)
    r = urllib.request.Request(url, data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(r, timeout=TIMEOUT) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:
        return -1, f"[异常] {type(e).__name__}: {e}"


def pretty(text, limit=2500):
    try:
        obj = json.loads(text)
        s = json.dumps(obj, ensure_ascii=False, indent=2)
    except Exception:
        s = text
    if len(s) > limit:
        s = s[:limit] + f"\n... [截断，共 {len(s)} 字符]"
    return s


def check_config():
    ok = True
    if not ACCESS_TOKEN:
        print("✗ ACCESS_TOKEN 未填"); ok = False
    elif not ACCESS_TOKEN.endswith("-prod_SAIC"):
        print("⚠ token 未以 -prod_SAIC 结尾，请核对")
    if not USER_ID:
        print("⚠ USER_ID 未填（抓包 userid 头）")
    if not VIN:
        print("✗ VIN 未填（LSJ 开头 17 位）"); ok = False
    elif not (VIN.startswith("LSJ") and len(VIN) == 17):
        print(f"⚠ VIN 格式可疑: {VIN} ({len(VIN)}位)")
    return ok


def main():
    print("=" * 62)
    print(" MGLiveWidget · P0 接口验证 v2（按真实抓包校准）")
    print("=" * 62)
    if not check_config():
        print("\n先补全 CONFIG。参见 docs/01-抓包教程.md")
        sys.exit(1)

    print(f"token  : ...{ACCESS_TOKEN[-20:]}")
    print(f"userid : {USER_ID or '(未填)'}")
    print(f"VIN    : {VIN}")
    print()

    results = {}

    # --- [1] 已知可用接口：getWeather（连通性 sanity check）---
    print("[1] getWeather（抓包已知接口，验证 token/格式是否畅通）")
    data_json = json.dumps({
        "appid": "MG", "timestamp": int(time.time() * 1000),
        "vehicle": VIN, "token": ACCESS_TOKEN,
    }, separators=(",", ":"))
    st, tx = req(f"{DOMAIN_APP}/app-mp/facade/1.0/getWeather?data={urllib.parse.quote(data_json)}")
    results["getWeather"] = (st, tx)
    print(f"    HTTP {st}")
    print("    " + pretty(tx, 600).replace("\n", "\n    "))
    print()

    # --- [2] 用户信息（验 token 有效性）---
    print("[2] fetchCcmUserInfoV2（验证 token）")
    st, tx = req(f"{DOMAIN_CAPI}/app-mp/uais/1.1/fetchCcmUserInfoV2")
    results["userinfo"] = (st, tx)
    print(f"    HTTP {st}")
    print("    " + pretty(tx, 900).replace("\n", "\n    "))
    print()

    # --- [3] 车况接口探测（facade 风格 + 直接路径）---
    print("[3] 车况接口探测")
    ts = str(int(time.time() * 1000))

    def facade(path):
        d = json.dumps({"appid": "MG", "timestamp": int(time.time() * 1000),
                        "vehicle": VIN, "token": ACCESS_TOKEN},
                       separators=(",", ":"))
        return f"{DOMAIN_APP}/app-mp/facade/1.0/{path}?data={urllib.parse.quote(d)}"

    candidates = [
        ("GET",  facade("getVehicleStatus"), None),
        ("GET",  facade("vehicleStatus"), None),
        ("GET",  facade("getCarStatus"), None),
        ("GET",  facade("getVehicleInfo"), None),
        ("GET",  facade("getVehicleList"), None),
        ("GET",  f"{DOMAIN_APP}/app-mp/vehicle/{VIN}/status", None),
        ("POST", f"{DOMAIN_APP}/app-mp/vehicle/status", {"vin": VIN}),
    ]
    for method, url, form in candidates:
        st, tx = req(url, method=method, form=form,
                     extra_headers={"timestamp": ts})
        mark = "✓" if st == 200 else "·"
        print(f"    [{mark}] HTTP {st}  {method} {url.split('/app-mp/')[-1][:70]}")
        if st == 200:
            results[url] = (st, tx)
            print("    " + pretty(tx, 1800).replace("\n", "\n    "))
    print()

    # --- [3] 汇总 ---
    print("=" * 62)
    hit = [u for u, (s, _) in results.items() if s == 200]
    if hit:
        print(f"命中 {len(hit)} 个接口：")
        for u in hit:
            print(f"  - {u}")
        print("\n请把本脚本全部输出发给板栗仁，用于校准字段映射。")
    else:
        print("未命中 200。可能原因：")
        print("  1. 车况接口路径不在猜测列表里 → 抓包确认真实路径")
        print("  2. sign 头被服务端强校验 → 需逆向签名算法（见下）")
        print("  3. token 时效已过 → 重新抓一次")
    print("=" * 62)


if __name__ == "__main__":
    main()
