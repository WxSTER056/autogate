# Wong AutoGate 🚪⚡

AI 语音与手机远程控制电动门系统（基于 Flutter + Firebase Realtime Database + ESP32 + CC1101 330MHz RF）。

---

## 📱 1. Android APK 下载与安装

- **直接下载路径**：本项目根目录下的 [`autogate_file/autogate.apk`](./autogate_file/autogate.apk)
- **GitHub Release 下载**：[Releases 页面](https://github.com/WxSTER056/autogate/releases)
- **应用名称**：Wong AutoGate

### 从源码编译

凭据不再写死在代码里，编译时注入：

```bash
flutter build apk --release \
  --dart-define=FIREBASE_PROJECT_ID=<你的项目ID> \
  --dart-define=FIREBASE_API_KEY=<Web API Key> \
  --dart-define=FIREBASE_DATABASE_URL=https://<你的项目>-default-rtdb.<区域>.firebasedatabase.app
```

不传 `--dart-define` 也能编译运行，只是 Firebase 显示「未设定」，需要用户在
App 内「设置」中手动填写（语音功能不受影响）。ESP32 的 Wi-Fi 与签名密钥走
`esp32/secrets.h`，同样不入库。

---

## 🔐 2. 安全：签署触发指令（重要）

> ⚠️ **本仓库是公开的。** 历史提交中已出现过 Firebase 数据库地址与 Wi-Fi 密码，请务必先执行下面的轮换清单。

### 原本的风险

固件只要看到数据库里出现 `"trigger": true` 就会发射射频。而这个 Realtime Database **匿名可读写**（`GET /door_control.json` 返回 200），所以任何人发一个未认证的请求就能开门：

```
PATCH https://<你的数据库>.json
{"trigger": true}
```

单纯收紧数据库规则解决不了 —— ESP32 目前是匿名连接，规则一收紧它就读不到任何东西了。

### 采用的方案：HMAC 签署 + 固件校验

检查必须放在**唯一能真正开门的组件**（固件）里：

1. App 不再写 `trigger: true`，改为写入 `/door_control/trigger_v2`
2. 内容为 `{ "sig": <hex>, "ts": <秒级时间戳>, "n": <随机数>, "action": "toggle" | "half_open" }`
3. `sig = HMAC-SHA256(共享密钥, "<ts>:<n>:<action>")`，小写 hex
4. 固件用同一把密钥重算并**定长比较**，同时要求 `|当前时间 - ts| ≤ 30 秒`（防重播），全部通过才发射

> `action` 也纳入签名，因此一份被截获的「开门」指令无法被改写成「半开门」。

无签名、时间戳过期的触发会被打印到串口并丢弃。`n` 记录在 `lastConsumedNonce`，同一笔不会重复发射。

Dart 端实现在 [`lib/services/trigger_signer.dart`](./lib/services/trigger_signer.dart)，固件端实现在 [`esp32/esp32_autogate.ino`](./esp32/esp32_autogate.ino)（`hmacSha256Hex` / `verifyTrigger`）。两边用同一组已知答案向量在测试里锁定一致性。

### 启用步骤

安全模式**默认关闭**，所以新 APK 配旧固件照常可用。刷完固件再打开：

1. 复制 `esp32/secrets.h.example` 为 `esp32/secrets.h`，填入 Wi-Fi、数据库地址，并生成一把随机密钥：
   ```bash
   openssl rand -hex 24
   ```
2. 用 Arduino IDE 打开 `esp32/esp32_autogate.ino` 并烧录
3. 打开串口监视器（115200），启动时会印出一组已知答案 HMAC，可与 App 端对照
4. 在 App「设定」里把 **安全模式** 打开，并把同一把密钥填进 **Trigger Shared Secret**
5. 点「签名自检」确认通过

> `esp32/secrets.h` 已加入 `.gitignore`，请不要再提交。

### 必须轮换的东西

| 项目 | 原因 |
| :--- | :--- |
| **Wi-Fi 密码** | 曾硬编码在固件里，且已进入公开仓库历史 —— **请立刻更换** |
| Firebase 数据库地址 | 公开可写，这是本次漏洞的根因 |
| Realtime Database 安全规则 | 建议 `.read: false`、`.write: false`，只靠固件签名放行（ESP32 用 REST 匿名读取会受影响，需配合 Admin SDK 才能锁规则） |

### 诚实的局限

共享密钥必须同时存在于 App 和固件中，因此**有能力逆向 APK 的人可以取出密钥并伪造指令**。这套方案挡的是「随手扫描互联网就能开门」这类现实威胁，彻底方案是 App 端接入 Firebase Auth + ESP32 改用 Admin SDK + 服务端规则，属于后续迁移（需要 Console 权限和重新刷机）。

---

## 🗣️ 3. 语音引擎说明

语音识别使用 `speech_to_text`（Android 上底层就是系统自带的 Google 语音识别服务 `SpeechRecognizer`）。

**为什么麦克风之前会一直“开—关—开—关”？**

Android 的识别器只支持单次、有时限的会话（静音几秒后系统就会主动结束）。要做“持续聆听”就必须反复开启新会话。旧代码里 `notListening`、`done`、错误回调 **各自** 都会挂一个不可取消的 `Future.delayed` 重启定时器；而 `listen()` 返回后要等平台回报 `listening` 才会把 `isListening` 置为 true，这个窗口里多个定时器会同时通过“是否已在聆听”的判断，于是同一个原生识别器被连续调用多次 `listen()`，互相打断并抛出 busy 错误，再触发下一轮重启 —— 麦克风就一直闪，指令也会漏。

**现在的做法（`lib/services/speech_service.dart`）：**

| 机制 | 说明 |
| :--- | :--- |
| 单一重启调度器 | 全局只有一个重启 `Timer`，新调度必定取消旧的；`_sessionToken` 会丢弃过期的回调 |
| 会话边界 | `listenFor: 10s` / `pauseFor: 4s`，由插件自己决定何时收尾，不再被系统随机掐断 |
| 命中即关 | 一旦识别到关键字**立刻** `cancel()` 关掉麦克风并执行指令，1.5 秒后再重新开启 —— 避免门机运转声被当成下一条指令 |
| 防重入 | `_sessionActive` 与 `_listenInFlight` 双保险，杜绝并发 `listen()` |
| 空闲退避 | 连续几轮没有识别到字时，重启间隔按 350ms → 2s → 5s → 10s 递增，识别到字后立刻复位，保证说完话马上能用 |
| 错误退避 | 报错后按 600ms → 2s → 4s → 8s 退避；遇到 permanent 错误（如权限被拒）直接停止，不再空转 |
| 只认最终结果 | 门控指令只在 `finalResult` 时匹配，避免 partial “open” 先触发一次、最终结果再触发一次 |
| 动作词 + 目标词 | 必须同时出现动作词和门/闸（`open the door`、`开门`、`关闸`…），并排除 `open the app`、`close the browser` 这类别的 App 指令 |
| 半开门优先 | `half open the door` / `半开门` 同时含有 “open” 与 “门”，所以半开门规则排在开关门之前判定 |
| 前后台感知 | `HomeScreen` 转发 `AppLifecycleState`，退到后台立即 `cancel()`，回前台再恢复 |

---

## 🚪 3.5 动作与发送次数

`lib/services/gate_command.dart` 定义了 App 与固件共用的动作枚举，固件据此决定发射几次射频：

| `action` | 名称 | 射频次数 | 间隔 |
| :--- | :--- | :--- | :--- |
| `toggle` | 一键开关门 | 1 次 | — |
| `half_open` | 半开门 | 2 次 | 3 秒 |

触发方式：

- **按钮**：首页两个并排按钮 ——「一键开关门」与「半开门」
- **语音**：`open the door` / `close the door` / `开门` / `关门` / `开闸` / `关闸` → 单次
  `half open the door` / `open halfway` / `half open` / `半开门` / `开一半` / `开门一半` → 两次
- **实体遥控器**：`trigger` 按钮照旧为单次

> ⚠️ 半开门的「发两次、间隔 3 秒」逻辑写在 **ESP32 固件**里（`performAction`），
> App 只发一条指令、附带 `action` 字段。因此需要先烧录新版固件才能真正双发；
> 未烧录时 App 会照常工作，只是半开门会退化成单次开启。
> 把间隔放在固件是为了避免 App 被系统杀掉或网络抖动导致第二次讯号发不出去。


---

## 🛠️ 4. 项目架构

1. **Flutter App**：
   - 支持打开即自动语音监听（支持 "Open the door", "Close the door", "Open gate", "Close gate", "开门", "关门", "开闸", "关闸"）。
   - 指令需同时包含“动作词 + 门/闸”，可避免 “open the app” 等误触发（详见第 3 节）。
   - 备用触控大按钮：手动一键开关门。
   - 实时监听 Firebase 节点状态与 ESP32 回执响应。
2. **Firebase Realtime Database**：
   - 节点 `/door_control/trigger` (布尔值，旧固件)
   - 节点 `/door_control/trigger_v2` (签名对象，新固件，详见第 2 节)
   - 节点 `/door_control/status` (状态字串)
3. **ESP32 + CC1101 射频模块**：
   - 每 300ms 轮询 Firebase `/door_control`。
   - 优先读取 `trigger_v2` 并校验 HMAC-SHA256 签名与时间戳，通过后发射 330MHz (Protocol 5, 25-bit, Code 21487477) 射频信号；未通过则丢弃并打印串口日志。
   - 源码位于：[`esp32/esp32_autogate.ino`](./esp32/esp32_autogate.ino)

---

## 🎨 5. 应用图标

图标由 [`tool/make_icons.py`](./tool/make_icons.py) 生成（需要 Python + Pillow）：

```bash
python tool/make_icons.py
```

会一次产出：

- Android 传统图标 `mipmap-*/ic_launcher.png`（自带圆角）
- Android 自适应图标前景层 `ic_launcher_foreground.png`（自动收进 66dp 安全圆）+ 渐变背景层
- Android 13+ 主题图标 `ic_launcher_monochrome.png`（纯色剪影，由系统着色）
- iOS 全套尺寸（含 1024×1024 商店图）
- 母版 [`assets/icon_master.png`](./assets/icon_master.png)

改完设计后重跑脚本即可，脚本会自动重新居中并按各平台安全区缩放。


---

## 🔌 6. ESP32 接线指南

| CC1101 引脚 | ESP32 GPIO | 说明 |
| :--- | :--- | :--- |
| **VCC** | **3.3V** | ⚠️ 严禁接 5V |
| **GND** | **GND** | 共地 |
| **SCK** | **GPIO 18** | SPI 时钟 |
| **MISO** | **GPIO 19** | SPI 主机输入 |
| **MOSI** | **GPIO 23** | SPI 主机输出 |
| **CSN** | **GPIO 5** | SPI 片选 |
| **GDO0** | **GPIO 2** | 射频开关信号 |

源码位于：[`esp32/esp32_autogate.ino`](./esp32/esp32_autogate.ino)
