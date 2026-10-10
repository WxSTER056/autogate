# AutoGate Voice Controller 🚪⚡

AI 语音与手机远程控制电动门系统（基于 Flutter + Firebase Realtime Database + ESP32 + CC1101 330MHz RF）。

---

## 📱 1. Android APK 下载与安装

- **直接下载路径**：本项目根目录下的 [`autogate_file/autogate.apk`](./autogate_file/autogate.apk)
- **GitHub Release 下载**：[Releases 页面](https://github.com/WxSTER056/autogate/releases)

---

## 🗣️ 2. 语音引擎说明

语音识别使用 `speech_to_text`（Android 上底层就是系统自带的 Google 语音识别服务 `SpeechRecognizer`）。

**为什么麦克风之前会一直“开—关—开—关”？**

Android 的识别器只支持单次、有时限的会话（静音几秒后系统就会主动结束）。要做“持续聆听”就必须反复开启新会话。旧代码里 `notListening`、`done`、错误回调 **各自** 都会挂一个不可取消的 `Future.delayed` 重启定时器；而 `listen()` 返回后要等平台回报 `listening` 才会把 `isListening` 置为 true，这个窗口里多个定时器会同时通过“是否已在聆听”的判断，于是同一个原生识别器被连续调用多次 `listen()`，互相打断并抛出 busy 错误，再触发下一轮重启 —— 麦克风就一直闪，指令也会漏。

**现在的做法（`lib/services/speech_service.dart`）：**

| 机制 | 说明 |
| :--- | :--- |
| 单一重启调度器 | 全局只有一个重启 `Timer`，新调度必定取消旧的；`_sessionToken` 会丢弃过期的回调 |
| 会话边界 | `listenFor: 12s` / `pauseFor: 4s`，由插件自己决定何时收尾，不再被系统随机掐断 |
| 防重入 | `_sessionActive` 与 `_listenInFlight` 双保险，杜绝并发 `listen()` |
| 空闲退避 | 连续几轮没有识别到字时，重启间隔按 350ms → 2s → 5s → 10s 递增，识别到字后立刻复位，保证说完话马上能用 |
| 错误退避 | 报错后按 600ms → 2s → 4s → 8s 退避；遇到 permanent 错误（如权限被拒）直接停止，不再空转 |
| 只认最终结果 | 门控指令只在 `finalResult` 时匹配，避免 partial “open” 先触发一次、最终结果再触发一次 |
| 动作词 + 目标词 | 必须同时出现动作词和门/闸（`open the door`、`开门`、`关闸`…），并排除 `open the app`、`close the browser` 这类别的 App 指令 |
| 前后台感知 | `HomeScreen` 转发 `AppLifecycleState`，退到后台立即 `cancel()`，回前台再恢复 |

---

## 🛠️ 3. 项目架构

1. **Flutter App**：
   - 支持打开即自动语音监听（支持 "Open the door", "Close the door", "Open gate", "Close gate", "开门", "关门", "开闸", "关闸"）。
   - 指令需同时包含“动作词 + 门/闸”，可避免 “open the app” 等误触发（详见第 2 节）。
   - 备用触控大按钮：手动一键开关门。
   - 实时监听 Firebase 节点状态与 ESP32 回执响应。
2. **Firebase Realtime Database**：
   - 节点 `/door_control/trigger` (布尔值)
   - 节点 `/door_control/status` (状态字串)
3. **ESP32 + CC1101 射频模块**：
   - 监听 Firebase `/door_control/trigger` 节点。
   - 收到 `true` 时，通过 CC1101 发射 330MHz (Protocol 5, 25-bit, Code 21487477) 射频信号。
   - 发射完成后复位为 `false`，状态更新为 `action_completed`。

---

## 🔌 4. ESP32 接线指南

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
