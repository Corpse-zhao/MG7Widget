#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
控车接口验证脚本 —— 验证 mp.ebanma.com 的 mqttpublish 控车接口是否可用。

用法：
    python verify_control.py <token> <vin> <commandType> [userid] [aliClientId]

commandType 实测值：上锁车门 / 开启空调  （中文明文）
userid 实测：1510000062021
aliClientId 实测：GID_ios_mg@@@318FE098-2FDD-43DD-906A-5CD3574B456D

⚠️ 会真的下发控车指令（车会真的落锁/开空调），确认车在安全位置再跑。
"""
import json
import sys
import time
import urllib.parse
import urllib.request
import urllib.error

BASE = "https://mp.ebanma.com/app-mp/mqttpublish/1.0/mqttStatisticDataApi"


def build_data(command_type: str, vin: str, ali_client_id: str) -> str:
    now = int(time.time() * 1000)
    command_id = 2025 * 100_000_000 + (now % 100_000_000)
    # 内层 JSON —— 顺序与抓包实测一致
    inner = (
        '{"commandId":%d,'
        '"timestamp7":%d,'
        '"timestamp1":%d,'
        '"commandType":"%s",'
        '"vin":"%s",'
        '"aliClientId":"%s"}'
    ) % (command_id, now, now - 6000, command_type, vin, ali_client_id)
    # 外层：值是「被转义的 JSON 字符串」
    outer = {"MQTTStatisticsDataDTO": inner}
    return json.dumps(outer, ensure_ascii=False)


def send(token: str, vin: str, command_type: str,
         userid: str, ali_client_id: str, with_sign: bool = False):
    data = build_data(command_type, vin, ali_client_id)
    url = BASE + "?data=" + urllib.parse.quote(data, safe="")

    now = int(time.time() * 1000)
    headers = {
        "User-Agent": "MGProject_PD/2.1.7 (iPhone; iOS 16.6; Scale/3.00)",
        "X-Client-Id": "App",
        "app-type": "mgapp",
        "versionCode": "2.1.7",
        "channelID": "MG",
        "os": "iOS",
        "watch-man-check-type": "ios",
        "watch-man-check-flag": "T",
        "Accept": "*/*",
        "token": token,
        "userid": userid,
        "timestamp": str(now),
    }
    if with_sign:
        # 占位：真实 sign 需要 hook 或逆向算法，这里放个假值看服务端是否校验
        headers["sign"] = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

    print("\n" + "=" * 70)
    print("请求:", "GET", BASE)
    print("data(解码):", data)
    print("sign 头:", "有(假值)" if with_sign else "无")
    print("-" * 70)

    req = urllib.request.Request(url, headers=headers, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            body = r.read().decode("utf-8", "replace")
            print("HTTP", r.status)
            print("响应:", body)
            try:
                j = json.loads(body)
                if "err_resp" in j and j["err_resp"]:
                    print("❌ 业务错误:", j["err_resp"])
                elif "req_id" in j:
                    print("✅ 服务端已受理（data=null 表示执行结果走 MQTT 回报）")
            except Exception:
                pass
            return True
    except urllib.error.HTTPError as e:
        print("HTTP", e.code)
        print("响应:", e.read().decode("utf-8", "replace")[:500])
    except Exception as e:
        print("异常:", e)
    return False


if __name__ == "__main__":
    if len(sys.argv) < 4:
        print(__doc__)
        sys.exit(1)
    token = sys.argv[1]
    vin = sys.argv[2]
    cmd = sys.argv[3]
    userid = sys.argv[4] if len(sys.argv) > 4 else "1510000062021"
    cid = sys.argv[5] if len(sys.argv) > 5 else \
        "GID_ios_mg@@@318FE098-2FDD-43DD-906A-5CD3574B456D"

    print("指令:", cmd, "| VIN:", vin, "| userid:", userid)
    print("\n【测试 1】不带 sign —— 看服务端是否放行")
    ok1 = send(token, vin, cmd, userid, cid, with_sign=False)
    print("\n【测试 2】带假 sign —— 看服务端是否真的校验签名")
    ok2 = send(token, vin, cmd, userid, cid, with_sign=True)
    print("\n" + "=" * 70)
    print("结论:")
    if ok1:
        print("  ✅ 不带 sign 就通了 → App 可直接实现，无需逆签")
    elif ok2:
        print("  ⚠️ 带 sign 才通 → 需要逆向签名算法或走 hook")
    else:
        print("  ❌ 都不通 → 看错误码：14101=token 失效，其它见文档")
