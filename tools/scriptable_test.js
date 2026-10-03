// MG7 车况小组件 — Scriptable 版
// 用途：先验证「iPhone 上能否调通接口」，通了直接就能当小组件用
// 用法：填入 token → 在 Scriptable 里运行 → 看弹窗/日志

const CONFIG = {
  token: "在这里填抓包拿到的 token（-prod_SAIC 结尾）",
  vin:   "LSJWJ4W90SZ187922",
};

// —— 接口（来自 MG Linker 源码 + iOS 抓包证实）——
const EP   = "https://mp.ebanma.com/app-mp/vp/1.2/getVehicleStatus";
const EP11 = "https://mp.ebanma.com/app-mp/vp/1.1/getVehicleStatus";

/**
 * 通用请求。tryBoth=true 时先试 1.2(facade)，失败再试 1.1(平铺)
 */
async function fetchStatus(vin, token, useV11) {
  let url, headers = {
    "User-Agent":
      "MGProject_PD/2.1.7 (iPhone; iOS 16.6; Scale/3.00)",
    "Accept": "*/*",
    "Accept-Language": "zh-cn",
    "userid": "15100000062021",
    "channelID": "MG",
    "X-client-id": "App",
    "app-type": "mgapp",
    "os": "iOS",
    "versionCode": "2.1.7",
    "Model": "ehs",
    "brandcode": "2",
    "token": token,
  };
  if (useV11) {
    const ts = Math.floor(Date.now() / 1000);
    url = `${EP11}?timestamp=${ts}&token=${token}&vin=${vin}`;
  } else {
    const data = { appid: "MG", timestamp: Date.now(), vin: vin, token: token };
    url = `${EP}?data=${encodeURIComponent(JSON.stringify(data))}`;
  }
  const req = new Request(url);
  req.headers = headers;
  req.timeoutInterval = 15;
  try {
    const txt = await req.loadString();
    return { ok: true, body: txt };
  } catch (e) {
    return { ok: false, body: String(e) };
  }
}

// —— 主流程 ——
let report = "";
let hit = null;
for (const [label, v11] of [["vp/1.2 facade", false], ["vp/1.1 平铺", true]]) {
  const r = await fetchStatus(CONFIG.vin, CONFIG.token, v11);
  const isErr = r.body.includes("err_resp");
  report += `${isErr ? "×" : "✓"} ${label}: ${r.body.slice(0, 90)}\n\n`;
  if (r.ok && !isErr && !hit) hit = { label, body: r.body };
}

if (hit) {
  // 成功！解析并展示
  try {
    const j = JSON.parse(hit.body);
    const v = j.data?.vehicle_value || {};
    const s = j.data?.vehicle_state || {};
    const lines = [
      `✅ 成功（${hit.label}）`,
      `续航: ${v.driving_range ?? "?"} km`,
      `油量: ${v.fuel_level_prc ?? "?"} %`,
      `油续航: ${v.fuel_range ?? "?"} km`,
      `锁车: ${s.lock ? "已锁" : "未锁"}`,
      `车温: ${v.interior_temperature ?? "?"}℃`,
      `胎压: ${v.front_left_tyre_pressure ?? "?"}/${v.front_right_tyre_pressure ?? "?"}/${v.rear_left_tyre_pressure ?? "?"}/${v.rear_right_tyre_pressure ?? "?"} kPa`,
      `电瓶: ${v.vehicle_battery ? (v.vehicle_battery / 10).toFixed(1) : "?"} V`,
      `里程: ${v.odometer ?? "?"} km`,
    ];
    report += lines.join("\n");
    // 保存原始数据供小组件用
    const fm = FileManager.local();
    const p = fm.joinPath(fm.documentsDirectory(), "mg7_snapshot.json");
    fm.writeString(p, hit.body);
  } catch (e) {
    report += `解析失败: ${e}\n原始: ${hit.body.slice(0, 300)}`;
  }
}

// 展示结果（Alert 便于截图）
const a = new Alert();
a.title = "MG7 接口测试";
a.message = report;
a.addAction("复制结果");
a.addCancelAction("关闭");
const idx = await a.present();
if (idx === 0) Pasteboard.copy(report);
