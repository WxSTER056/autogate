#include <WiFi.h>
#include <HTTPClient.h>
#include <WiFiClientSecure.h>
#include <ELECHOUSE_CC1101_SRC_DRV.h>
#include <RCSwitch.h>

// ================= 1. Wi-Fi 設定 =================
#define WIFI_SSID "Wong_wifi 2.4Ghz"
#define WIFI_PASSWORD "wong77033109"

// ================= 2. Firebase 直連 REST 網址 =================
const char* FIREBASE_URL = "https://wong-autogate-default-rtdb.asia-southeast1.firebasedatabase.app/door_control.json";

// ================= 3. CC1101 射頻設定 =================
#define CC1101_GDO0_PIN 2   // 對應 ESP32 上的 G2 引腳
#define RF_CODE 21487477    // 你的門鎖遙控解碼數值
#define RF_BIT_LENGTH 25    // 位元長度
#define RF_PULSE_DELAY 580  // 脈衝時長 (us)
#define RF_PROTOCOL 5       // 協議編號

RCSwitch mySwitch = RCSwitch();
WiFiClientSecure client;
HTTPClient http;
unsigned long lastCheckTime = 0;

// 發射射頻信號函式 (完全按照你原本可正常開門的原始寫法)
void triggerDoorRF() {
  Serial.println("\n[RF] >>> 正在發射 330MHz 射頻訊號開/關門...");
  
  // 啟動 CC1101 發射模式
  ELECHOUSE_cc1101.SetTx();
  mySwitch.enableTransmit(CC1101_GDO0_PIN);
  
  // 發射信號 (數值, 位元長度)
  mySwitch.send(RF_CODE, RF_BIT_LENGTH);
  
  Serial.println("[RF] >>> 射頻信號發射完成！");
}

void setup() {
  Serial.begin(115200);
  delay(1000);

  Serial.println("\n==========================================");
  Serial.println("=== AutoGate 門控系統已啟動 ===");
  Serial.println("==========================================");

  // --- 初始化 CC1101 ---
  ELECHOUSE_cc1101.Init();
  if (ELECHOUSE_cc1101.getCC1101()) {
    Serial.println("[CC1101] 晶片連線成功！");
  } else {
    Serial.println("[CC1101] 錯誤：找不到晶片，請檢查線路！");
    while (1) delay(1000);
  }

  // 設定 330MHz 與射頻參數
  ELECHOUSE_cc1101.setMHZ(330.00);
  mySwitch.setProtocol(RF_PROTOCOL);
  mySwitch.setPulseLength(RF_PULSE_DELAY);
  mySwitch.setRepeatTransmit(10); // 重複發射 10 次確保門機能收到

  // --- 連接 Wi-Fi ---
  Serial.print("[WiFi] 正在連接: ");
  Serial.println(WIFI_SSID);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
  }
  Serial.println("\n[WiFi] 連線成功！IP 位址: " + WiFi.localIP().toString());

  // 設置安全客戶端為免證書快速連線
  client.setInsecure();

  Serial.println("[系統就緒] 正在即時監聽手機開門指令...\n");
}

void loop() {
  if (WiFi.status() != WL_CONNECTED) {
    delay(100);
    return;
  }

  // 每 300ms 檢查一次 Firebase 狀態
  if (millis() - lastCheckTime > 300) {
    lastCheckTime = millis();

    http.begin(client, FIREBASE_URL);
    int httpCode = http.GET();

    if (httpCode == 200) {
      String payload = http.getString();

      // 檢查是否收到開門指令
      if (payload.indexOf("\"trigger\":true") > 0 || payload.indexOf("\"trigger\": true") > 0) {
        Serial.println("\n⚡ [指令觸發] 收到手機開門信號！");

        // 1. 立即發射 CC1101 射頻信號開門
        triggerDoorRF();

        // 2. 將 Firebase 狀態復位為 trigger: false
        http.begin(client, FIREBASE_URL);
        http.addHeader("Content-Type", "application/json");
        int patchCode = http.PATCH("{\"trigger\":false,\"status\":\"action_completed\"}");

        if (patchCode == 200) {
          Serial.println("✔️ [Firebase] 成功重置狀態為 action_completed");
        } else {
          Serial.printf("❌ [Firebase] 重置失敗，HTTP 代碼: %d\n", patchCode);
        }

        Serial.println(">>> 開門完成，等待下一次指令...\n");
      }
    }
    http.end();
  }
}
