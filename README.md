# AutoGate Voice Controller 🚪⚡

AI 语音与手机远程控制电动门系统（基于 Flutter + Firebase Realtime Database + ESP32 + CC1101 330MHz RF）。

---

## 📱 1. Android APK 下载与安装

- **直接下载路径**：本项目根目录下的 [`autogate_file/autogate.apk`](./autogate_file/autogate.apk)
- **GitHub Release 下载**：[Releases 页面](https://github.com/WxSTER056/autogate/releases)

---

## 🛠️ 2. 项目架构

1. **Flutter App**：
   - 支持打开即自动语音监听（支持 "Open the door", "Close the door", "Open gate", "Close gate", "开门", "关门"）。
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

## 🔌 3. ESP32 接线指南

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
