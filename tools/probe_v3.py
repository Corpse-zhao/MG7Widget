#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
P0 实验脚本 v3：
  A. capi-pv 头名发现（fetchCcmUserInfoV2 换不同 token 头名）
  B. 若 A 命中 → 在 capi-pv 上探车况接口
  C. 忠实重放 getWeather（带 sign/timestamp/watch-man 全套原始头）验证反重放强度
"""

import json, time, urllib.request, urllib.error, urllib.parse

ACCESS_TOKEN = "7a35805fd3f04937ac1b0e0c8e20dd08-prod_SAIC"
USER_ID      = "15100000062021"
VIN          = "LSJW4W90SZ187922"   # 16位，待用户确认

DOMAIN_APP  = "https://mp.ebanma.com"
DOMAIN_CAPI = "https://capi-pv.saicmotor.com"
T = 15

def req(url, headers, method="GET", form=None):
    h = dict(headers)
    data = None
    if form is not None:
        data = urllib.parse.urlencode(form).encode()
        h["Content-Type"] = "application/x-www-form-urlencoded"
    r = urllib.request.Request(url, data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(r, timeout=T) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:
        return -1, f"[异常] {type(e).__name__}: {e}"

def brief(tx, limit=500):
    try:
        o = json.loads(tx)
        return json.dumps(o, ensure_ascii=False)[:limit]
    except Exception:
        return tx[:limit]

BASE = {
    "User-Agent":  "MGProject_PD/2.1.7 (iPhone; iOS 16.6; Scale/3.00)",
    "channelID":   "MG",
    "X-client-id": "App",
    "app-type":    "mgapp",
    "os":          "iOS",
    "versionCode": "2.1.7",
    "Model":       "ehs",
    "brandcode":   "2",
    "Accept-Language": "zh-cn",
    "Accept":      "*/*",
}

print("=" * 62)
print(" A. capi-pv 头名发现")
print("=" * 62)
url_u = f"{DOMAIN_CAPI}/app-mp/uais/1.1/fetchCcmUserInfoV2"
win = None
for name in ["token", "access_token", "Access-Token", "accessToken",
             "Authorization", "access-token"]:
    h = dict(BASE); h[name] = ACCESS_TOKEN
    st, tx = req(url_u, h)
    hit = '"uid"' in tx or '"err_resp"' not in tx
    print(f"  [{'✓' if hit else '·'}] {name:14s} → HTTP {st}  {brief(tx, 160)}")
    if hit and win is None:
        win = name
print()
print(f"  ⇒ 命中头名: {win}")
print()

print("=" * 62)
print(" B. capi-pv 车况接口探测" + (f"（用 {win}）" if win else "（跳过：头名未命中）"))
print("=" * 62)
if win:
    ts = str(int(time.time() * 1000))
    paths = [
        "app-mp/vehicle/1.0/" + VIN + "/status",
        "app-mp/vehicle/status?vin=" + VIN,
        "app-mp/uais/1.1/vehicleStatus",
        "app-mp/vehicleInfo/" + VIN,
        "app-mp/car/status?vin=" + VIN,
    ]
    for p in paths:
        h = dict(BASE)
        h[win] = ACCESS_TOKEN
        h["userid"] = USER_ID
        h["timestamp"] = ts
        st, tx = req(f"{DOMAIN_CAPI}/{p}", h)
        ok = '"err_resp"' not in tx
        print(f"  [{'✓' if ok else '·'}] HTTP {st}  {p[:60]}")
        if ok:
            print("      " + brief(tx, 1500))
print()

print("=" * 62)
print(" C. 忠实重放 getWeather（全套原始头，验证反重放）")
print("=" * 62)
# 用户 20:12 抓包的原始请求，一字不改地重放
orig_url = (f"{DOMAIN_APP}/app-mp/facade/1.0/getWeather?data=%7B%22appid%22%3A%22MG%22%2C"
            f"%22timestamp%22%3A1791029484000%2C%22vehicle%22%3A%22{VIN}%22%2C"
            f"%22token%22%3A%27{ACCESS_TOKEN}%27%7D")
orig_headers = {
    **BASE,
    "Host": "mp.ebanma.com",
    "Geolocation": "121.24,31.00",
    "watch-man-check-flag": "T",
    "userid": USER_ID,
    "Uid": "318FE098-2FDD-43DD-906A-5CD3574B456D",
    "watch-man-mobile": "",
    "X-Tingyun": "c=A|bwHPoP8mfRQ;u=MTUxMDAwMDAwNjIwMjE=",
    "token": ACCESS_TOKEN,
    "sign": "b-D4RnTfhACFa1HKdByNT2yQ5d4M6Q9YKgv43YK394",
    "timestamp": "1791029484000",
    "watch-man-check-type": "IOS",
}
st, tx = req(orig_url, orig_headers)
print(f"  HTTP {st}")
print(f"  {brief(tx, 600)}")
print()
print("  判读：")
if '"err_resp"' not in tx:
    print("  ✓ 重放成功 → 服务器不校验 sign 时效，只要头全就能过")
elif "14101" in tx:
    print("  ✗ 仍是登录态失效 → sign/timestamp 已过期 或 token 已死 或有设备绑定")
print()
