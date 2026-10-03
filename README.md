# MGLiveWidget

名爵 MG7 车况桌面小组件 —— iPhone 14 Pro Max / iOS 16.6 / roothide 隐根。

## 目标形态

**独立控制 App + WidgetKit 桌面小组件**（板栗仁署名，中文 UI）

- 基础车况：续航、油量/电量、门锁状态、车内温度
- 位置寻车：GPS、停车位置、地址
- 健康数据：四轮胎压、12V 电瓶、动力电池健康度、里程
- 控车按钮：解锁/锁车/开空调（需二次确认）

## 目录

```
MGLiveWidget/
├── docs/
│   ├── 01-抓包教程.md      ← 从这里开始
│   └── 02-技术架构.md      ← 三件套架构说明
├── tools/
│   └── verify_api.py       ← P0 接口验证脚本
├── ios/
│   ├── MGWidgetHost/       ← 宿主 App（Xcode 编译）
│   │   ├── SharedStore.swift   共享数据层
│   │   └── SAICClient.swift    SAIC 接口客户端
│   ├── MGWidgetExt/        ← WidgetKit 小组件（待做）
│   └── MGHelperTweak/      ← 越狱辅助工具（Theos 编译）
│       ├── main.m              自动捞 token
│       ├── Makefile
│       ├── control             Version 0.1.0
│       └── mghelper.entitlements
├── ci/
│   └── build.yml           ← GitHub Actions (macOS)
└── README.md
```

## 核心难点（已想清）

| 难点 | 解法 |
|---|---|
| WidgetKit 必须 Xcode 编译 | 走 GitHub Actions macos-latest |
| Widget Ext 与宿主 App 进程隔离 | 固定路径共享文件 |
| roothide 下 App Group 失效 | 用 `/var/mobile/Library/MGLiveWidget/` |
| Widget Ext **不能联网** | 联网由宿主 App 做，结果写快照文件 |
| token 手动抓很烦 | MGHelper 越狱工具自动从 MG Live 沙盒捞 |

## 分期

- [x] **P0** 工程骨架 + 抓包教程 + 验证脚本  ← 当前
- [ ] P1 接口验证通过，字段名确定
- [ ] P2 宿主 App：网络层 + 车况 UI
- [ ] P3 WidgetKit Extension
- [ ] P4 MGHelper 自动捞 token
- [ ] P5 控车按钮

## 当前待办

**用户正在抓包**（见 docs/01-抓包教程.md），拿到后：
1. 填 `tools/verify_api.py` 的 CONFIG 区
2. 跑脚本，把输出发我
3. 我据此校准 `SAICClient.swift` 的路径与字段映射

## 版本约定

每次改动都要升 `control` 的 Version + 设置面板页脚版本号（用户铁律）。
