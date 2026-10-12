#include <WiFi.h>
#include <HTTPClient.h>
#include <WiFiClientSecure.h>
#include <ELECHOUSE_CC1101_SRC_DRV.h>
#include <RCSwitch.h>
#include <mbedtls/md.h>
#include <string.h>
#include <time.h>

#include "secrets.h"  // Wi-Fi / Firebase URL / GATE_TRIGGER_SECRET (git-ignored)

// ================= 1. 安全觸發驗證 =================
// 資料庫是公開可寫的，所以不能只靠 "trigger": true 就發射射頻。
// App 會改寫 /door_control/trigger_v2 = { "sig", "ts", "n" }，
// 這裡用與 App 端相同的 HMAC-SHA256 驗證；驗不過就直接丟棄。
#define TRIGGER_V2_ENABLED 1      // 刷完新固件後請確認 App 端也開啟安全模式
#define TRIGGER_REPLAY_WINDOW 30  // 秒；時間戳超出此範圍視為重播攻擊

// ================= 2. CC1101 射頻設定 =================
#define CC1101_GDO0_PIN 2   // 對應 ESP32 上的 G2 引腳
#define RF_CODE 21487477    // 你的門鎖遙控解碼數值
#define RF_BIT_LENGTH 25    // 位元長度
#define RF_PULSE_DELAY 580  // 脈衝時長 (us)
#define RF_PROTOCOL 5       // 協議編號

RCSwitch mySwitch = RCSwitch();
WiFiClientSecure client;
HTTPClient http;
unsigned long lastCheckTime = 0;
long lastConsumedNonce = -1;   // 避免同一筆簽名指令被重複發射
int rejectCount = 0;

// ---------- 小工具：不需要 ArduinoJson 的最小 JSON 解析 ----------

// 取出 "key":"value" 的字串內容，成功回傳 true
bool jsonFindString(const String& json, const char* key, String& out) {
  String needle = "\"";
  needle += key;
  needle += "\":\"";
  int start = json.indexOf(needle);
  if (start < 0) return false;
  start += needle.length();
  int end = json.indexOf('"', start);
  if (end < 0) return false;
  out = json.substring(start, end);
  return out.length() > 0;
}

// 取出 "key":123 的整數值，成功回傳 true
bool jsonFindInt(const String& json, const char* key, long& out) {
  String needle = "\"";
  needle += key;
  needle += "\":";
  int start = json.indexOf(needle);
  if (start < 0) return false;
  start += needle.length();

  long value = 0;
  int digits = 0;
  while (start < json.length() && isDigit(json[start])) {
    value = value * 10 + (json[start] - '0');
    start++;
    digits++;
    if (digits > 12) return false;  // 避免溢出
  }
  if (digits == 0) return false;
  out = value;
  return true;
}

// ---------- HMAC-SHA256 ----------
String hmacSha256Hex(const String& secret, const String& message) {
  const mbedtls_md_info_t* md = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
  if (md == NULL) return "";

  byte digest[32];
  const byte* key = (const byte*)secret.c_str();
  const byte* msg = (const byte*)message.c_str();

  int rc = mbedtls_md_hmac(md, key, secret.length(), msg, message.length(),
                           digest, 0);
  if (rc != 0) return "";

  static const char* hex = "0123456789abcdef";
  String out;
  out.reserve(64);
  for (int i = 0; i < 32; i++) {
    out += hex[(digest[i] >> 4) & 0x0F];
    out += hex[digest[i] & 0x0F];
  }
  return out;
}

// 長度無關的固定時間比較，避免用時間差做側通道
bool constantTimeEquals(const String& a, const String& b) {
  if (a.length() != b.length()) return false;
  byte diff = 0;
  for (size_t i = 0; i < a.length(); i++) {
    diff |= (byte)(a[i] ^ b[i]);
  }
  return diff == 0;
}

// 驗證簽章；通過回傳 true，actionOut 帶出要執行的動作
bool verifyTrigger(const String& payload, long& nonceOut, String& actionOut) {
  String sig;
  long ts = 0;
  long nonce = 0;

  if (!jsonFindString(payload, "sig", sig) ||
      !jsonFindInt(payload, "ts", ts) ||
      !jsonFindInt(payload, "n", nonce)) {
    Serial.println("  ✗ 觸發資料格式不符（缺少 sig / ts / n）");
    return false;
  }

  // 重播視窗：App 與 ESP32 的時鐘必須大致同步（相差 < 30 秒）
  long now = (long)time(nullptr);
  long drift = now > ts ? now - ts : ts - now;
  if (drift > TRIGGER_REPLAY_WINDOW) {
    Serial.printf("  ✗ 時間戳過期或時鐘不同步（drift=%lds, limit=%ds）\n",
                  drift, TRIGGER_REPLAY_WINDOW);
    return false;
  }

  if (strcmp(GATE_TRIGGER_SECRET, "在此貼上你的金鑰") == 0) {
    Serial.println("  ✗ GATE_TRIGGER_SECRET 尚未設定，拒絕發射");
    return false;
  }

  // 動作欄位：App 目前一律送 "toggle"。半開門由 App 送兩次觸發實現，
  // 所以這裡保留解析僅供除錯，實際上每次觸發只發一次射頻。
  String action = "toggle";
  jsonFindString(payload, "action", action);
  if (action.length() == 0) action = "toggle";

  String expected = hmacSha256Hex(
      GATE_TRIGGER_SECRET, String(ts) + ":" + String(nonce) + ":" + action);
  if (expected.length() == 0) {
    Serial.println("  ✗ HMAC 計算失敗");
    return false;
  }

  if (!constantTimeEquals(expected, sig)) {
    Serial.println("  ✗ 簽章不符 —— 可能有人嘗試伪造觸發，已拒絕");
    Serial.printf("     期望: %s\n     收到: %s\n",
                  expected.substring(0, 16).c_str(),
                  sig.substring(0, 16).c_str());
    rejectCount++;
    return false;
  }

  nonceOut = nonce;
  actionOut = action;
  return true;
}

// ================= 3. 射頻發射 =================
void triggerDoorRF() {
  ELECHOUSE_cc1101.SetTx();
  mySwitch.enableTransmit(CC1101_GDO0_PIN);
  mySwitch.send(RF_CODE, RF_BIT_LENGTH);
}

// 一次觸發 = 一次射頻。
// 「半開門」不在這裡做二次發射：App 會自己隔 3 秒發兩次觸發，
// 因此任何版本的固件都能正確支援半開門，不需要為了這個功能重新燒錄。
void performAction() {
  Serial.println("\n[RF] >>> 正在發射 330MHz 射頻訊號開/關門...");
  triggerDoorRF();
  Serial.println("[RF] >>> 射頻信號發射完成！");
}
void writeStatus(const char* status) {
  http.begin(client, FIREBASE_URL);
  http.addHeader("Content-Type", "application/json");
  String body = "{\"status\":\"";
  body += status;
  body += "\",\"trigger\":false}";
  int code = http.PATCH(body);
  if (code == 200) {
    Serial.printf("✔️ [Firebase] 狀態更新為 %s\n", status);
  } else {
    Serial.printf("❌ [Firebase] 狀態更新失敗，HTTP 代碼: %d\n", code);
  }
  http.end();
}

void setup() {
  Serial.begin(115200);
  delay(1000);

  Serial.println("\n==========================================");
  Serial.println("=== Wong AutoGate 門控系統已啟動 ===");
  Serial.println("==========================================");

  ELECHOUSE_cc1101.Init();
  if (ELECHOUSE_cc1101.getCC1101()) {
    Serial.println("[CC1101] 晶片連線成功！");
  } else {
    Serial.println("[CC1101] 錯誤：找不到晶片，請檢查線路！");
    while (1) delay(1000);
  }

  ELECHOUSE_cc1101.setMHZ(330.00);
  mySwitch.setProtocol(RF_PROTOCOL);
  mySwitch.setPulseLength(RF_PULSE_DELAY);
  mySwitch.setRepeatTransmit(10);

  Serial.print("[WiFi] 正在連接: ");
  Serial.println(WIFI_SSID);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
  }
  Serial.println("\n[WiFi] 連線成功！IP 位址: " + WiFi.localIP().toString());

  client.setInsecure();

  // 開機自我檢查
  if (strcmp(GATE_TRIGGER_SECRET, "在此貼上你的金鑰") == 0) {
    Serial.println("[安全] ⚠️ 尚未設定 GATE_TRIGGER_SECRET，所有觸發都會被拒絕！");
    Serial.println("[安全]    請編輯 secrets.h 後重新燒錄。");
  } else {
    Serial.print("[安全] 觸發金鑰長度: ");
    Serial.println(strlen(GATE_TRIGGER_SECRET));
    // 印出一組已知答案，方便和 App 端對照確認兩邊演算法一致
    Serial.print("[安全] 自我測試 HMAC(\"1700000000:12345:toggle\") = ");
    Serial.println(hmacSha256Hex(GATE_TRIGGER_SECRET, "1700000000:12345:toggle"));
  }

  Serial.println("[系統就緒] 正在即時監聽手機開門指令...\n");
}

void loop() {
  if (WiFi.status() != WL_CONNECTED) {
    delay(100);
    return;
  }

  if (millis() - lastCheckTime <= 300) {
    return;
  }
  lastCheckTime = millis();

  http.begin(client, FIREBASE_URL);
  int httpCode = http.GET();

  if (httpCode != 200) {
    http.end();
    return;
  }

  String payload = http.getString();
  // 先關掉連線再動作：半開門要阻塞 3 秒，不能把 TLS 連線握在手裡。
  http.end();

#if TRIGGER_V2_ENABLED
  // --- 優先走簽章通道 ---
  if (payload.indexOf("\"sig\"") >= 0) {
    long nonce = 0;
    String action = "toggle";
    if (!verifyTrigger(payload, nonce, action)) {
      Serial.println("  （已拒絕此次觸發）");
      return;
    }
    if (nonce == lastConsumedNonce) {
      return;  // 同一筆指令已經執行過，忽略
    }
    Serial.printf("\n⚡ [已驗證觸發] nonce=%ld action=%s\n", nonce,
                  action.c_str());
    performAction();
    lastConsumedNonce = nonce;
    rejectCount = 0;
    writeStatus("action_completed");
    Serial.println(">>> 動作完成，等待下一次指令...\n");
    return;
  }
#endif

  // --- 舊的無簽章通道，僅在安全模式關閉時使用 ---
#if !TRIGGER_V2_ENABLED
  if (payload.indexOf("\"trigger\":true") > 0 ||
      payload.indexOf("\"trigger\": true") > 0) {
    Serial.println("\n⚡ [指令觸發] 收到手機開門信號！");
    performAction();
    writeStatus("action_completed");
    Serial.println(">>> 動作完成，等待下一次指令...\n");
  }
#endif
}
