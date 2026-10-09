#include <WiFi.h>
#include <FirebaseESP32.h>
#include <ELECHOUSE_CC1101_SRC_DRV.h>
#include <RCSwitch.h>
#include "soc/soc.h"
#include "soc/rtc_cntl_reg.h"

// ================= 1. Wi-Fi 設定 =================
#define WIFI_SSID "Wong_wifi 2.4Ghz"
#define WIFI_PASSWORD "wong77033109"

// ================= 2. Firebase 設定 =================
#define FIREBASE_API_KEY "AIzaSyBCv87FCAqupLdMydOxvVm6M-Z_ZfYXMBU"

// ⚠️ 重要關鍵：FirebaseESP32 函式庫規定，網址「不能」帶 https:// 也不要有結尾斜線 /
// 必須純粹是 host 網域名稱：
#define FIREBASE_DATABASE_URL "wong-autogate-default-rtdb.asia-southeast1.firebasedatabase.app"

// ================= 3. CC1101 射頻設定 =================
#define CC1101_GDO0_PIN 2   // 對應 ESP32 上的 G2 引腳
#define RF_CODE 21487477    // 你的門鎖遙控解碼數值
#define RF_BIT_LENGTH 25    // 位元長度
#define RF_PULSE_DELAY 580  // 脈衝時長 (us)
#define RF_PROTOCOL 5       // 協議編號

// 物件初始化
RCSwitch mySwitch = RCSwitch();
FirebaseData fbdo;
FirebaseAuth auth;
FirebaseConfig config;

unsigned long lastCheckTime = 0;

// 發射射頻信號函式
void triggerDoorRF() {
  Serial.println("\n[RF] >>> 正在發射射頻訊號開/關門...");
  
  // 啟動 CC1101 發射模式
  ELECHOUSE_cc1101.SetTx();
  mySwitch.enableTransmit(CC1101_GDO0_PIN);
  
  // 發射信號 (數值, 位元長度)
  mySwitch.send(RF_CODE, RF_BIT_LENGTH);
  
  // 發射完成後將晶片切回待機(Sidle)，避免持續耗電或發熱導致 ESP32 重啟
  ELECHOUSE_cc1101.setSidle();
  
  Serial.println("[RF] >>> 信號發射完成！");
}

void setup() {
  // 關閉 ESP32 欠壓重啟保護(Brownout detector)，防止 Wi-Fi 與射頻瞬間電流過大導致開發板不斷重啟
  WRITE_PERI_REG(RTC_CNTL_BROWNOUT_REG, 0);

  Serial.begin(115200);
  delay(1000);

  Serial.println("\n==================================");
  Serial.println("=== AutoGate ESP32 系統啟動中 ===");
  Serial.println("==================================");

  // --- 初始化 CC1101 ---
  ELECHOUSE_cc1101.Init();
  if (ELECHOUSE_cc1101.getCC1101()) {
    Serial.println("[CC1101] 晶片連線成功！");
  } else {
    Serial.println("[CC1101] 警告：未偵測到 CC1101 晶片，請檢查線路 (SCK=18, MISO=19, MOSI=23, CSN=5, GDO0=2)！");
  }

  // 設定 330MHz 與參數
  ELECHOUSE_cc1101.setMHZ(330.00);
  mySwitch.setProtocol(RF_PROTOCOL);
  mySwitch.setPulseLength(RF_PULSE_DELAY);
  mySwitch.setRepeatTransmit(10); // 發射 10 次確保門機能接收到
  ELECHOUSE_cc1101.setSidle();

  // --- 連接 Wi-Fi ---
  Serial.print("[WiFi] 正在連接: ");
  Serial.println(WIFI_SSID);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  
  int wifiRetries = 0;
  while (WiFi.status() != WL_CONNECTED && wifiRetries < 40) {
    delay(500);
    Serial.print(".");
    wifiRetries++;
  }
  
  if (WiFi.status() == WL_CONNECTED) {
    Serial.println("\n[WiFi] 連線成功！IP 位址: " + WiFi.localIP().toString());
  } else {
    Serial.println("\n[WiFi] 連線超時，請檢查密碼與 2.4G 頻段！");
  }

  // --- 初始化 Firebase ---
  Serial.println("[Firebase] 正在初始化連線...");
  config.api_key = FIREBASE_API_KEY;
  config.database_url = FIREBASE_DATABASE_URL;

  // 設置超時時間與緩存，避免看門狗重啟
  fbdo.setResponseSize(1024);
  
  Firebase.begin(&config, &auth);
  Firebase.reconnectWiFi(true);

  Serial.println("[Firebase] 初始化完成，進入主監聽循環！\n");
}

void loop() {
  // 每 400ms 檢查一次 Firebase 狀態
  if (millis() - lastCheckTime > 400) {
    lastCheckTime = millis();

    if (Firebase.ready()) {
      // 讀取 /door_control/trigger 節點
      if (Firebase.getBool(fbdo, "/door_control/trigger")) {
        if (fbdo.dataType() == "boolean") {
          bool triggerVal = fbdo.boolData();

          if (triggerVal == true) {
            Serial.println("\n⚡ [Firebase] 收到開/關門指令 (trigger = true)！");

            // 1. 發射射頻信號
            triggerDoorRF();

            // 2. 將狀態重置為 false
            if (Firebase.setBool(fbdo, "/door_control/trigger", false)) {
              Serial.println("✔️ [Firebase] 成功重置 trigger 為 false");
            } else {
              Serial.print("❌ [Firebase] 重置 trigger 失敗: ");
              Serial.println(fbdo.errorReason());
            }

            // 3. 更新 status 節點
            Firebase.setString(fbdo, "/door_control/status", "action_completed");
          }
        }
      } else {
        // 如果讀取失敗，印出具體錯誤原因
        static unsigned long lastErrPrint = 0;
        if (millis() - lastErrPrint > 5000) {
          lastErrPrint = millis();
          Serial.print("[Firebase] 讀取失敗 原因: ");
          Serial.println(fbdo.errorReason());
        }
      }
    } else {
      static unsigned long lastWaitPrint = 0;
      if (millis() - lastWaitPrint > 5000) {
        lastWaitPrint = millis();
        Serial.println("[Firebase] 等待 Firebase 連線就緒 (Ready)...");
      }
    }
  }
}
