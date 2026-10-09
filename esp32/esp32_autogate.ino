#include <WiFi.h>
#include <FirebaseESP32.h>
#include <ELECHOUSE_CC1101_SRC_DRV.h>
#include <RCSwitch.h>

// ================= 1. Wi-Fi Settings =================
// ESP32 supports 2.4GHz Wi-Fi only (do NOT use 5GHz Wi-Fi SSID)
#define WIFI_SSID "YOUR_2.4G_WIFI_SSID"
#define WIFI_PASSWORD "YOUR_WIFI_PASSWORD"

// ================= 2. Firebase Settings =================
// 1) FIREBASE_API_KEY:
//    Go to Firebase Console -> Project Settings (Gear icon) -> General tab -> Web API Key (starts with AIzaSy...)
#define FIREBASE_API_KEY "YOUR_FIREBASE_WEB_API_KEY"

// 2) FIREBASE_DATABASE_URL:
//    你的东南亚/新加坡节点实际通信网址：
#define FIREBASE_DATABASE_URL "https://wong-autogate-default-rtdb.asia-southeast1.firebasedatabase.app/"

// ================= 3. CC1101 RF Transmitter Settings =================
// CC1101 Standard SPI Pinout on ESP32:
// SCK  -> GPIO 18
// MISO -> GPIO 19
// MOSI -> GPIO 23
// CSN  -> GPIO 5
// GDO0 -> GPIO 2 (Defined below)
// VCC  -> 3.3V
// GND  -> GND
#define CC1101_GDO0_PIN 2   // Connect to CC1101 GDO0 pin
#define RF_CODE 21487477    // Your door remote RF decoded value
#define RF_BIT_LENGTH 25    // Bit length
#define RF_PULSE_DELAY 580  // Pulse duration (microseconds)
#define RF_PROTOCOL 5       // Protocol number

// Global Objects
RCSwitch mySwitch = RCSwitch();
FirebaseData fbdo;
FirebaseAuth auth;
FirebaseConfig config;

// RF Signal Transmission Function
void triggerDoorRF() {
  Serial.println("\n[RF] Transmitting RF signal to open/close gate...");
  
  // Set CC1101 to TX mode
  ELECHOUSE_cc1101.SetTx();
  mySwitch.enableTransmit(CC1101_GDO0_PIN);
  
  // Send RF code (code, bit length)
  mySwitch.send(RF_CODE, RF_BIT_LENGTH);
  
  Serial.println("[RF] RF Transmission completed!");
}

void setup() {
  Serial.begin(115200);
  delay(1000);

  Serial.println("\n=== AutoGate ESP32 Starting Up ===");

  // --- Initialize CC1101 ---
  ELECHOUSE_cc1101.Init();
  if (ELECHOUSE_cc1101.getCC1101()) {
    Serial.println("[CC1101] Chip connected successfully!");
  } else {
    Serial.println("[CC1101] ERROR: CC1101 chip not found, check wiring (SCK=18, MISO=19, MOSI=23, CSN=5, GDO0=2)!");
    while (1) delay(1000);
  }

  // Set 330MHz and RF parameters
  ELECHOUSE_cc1101.setMHZ(330.00);
  mySwitch.setProtocol(RF_PROTOCOL);
  mySwitch.setPulseLength(RF_PULSE_DELAY);
  mySwitch.setRepeatTransmit(10); // Transmit 10 times to ensure gate motor receiver picks it up

  // --- Connect to Wi-Fi ---
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  Serial.print("[WiFi] Connecting to " WIFI_SSID);
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
  }
  Serial.println("\n[WiFi] Connected! IP Address: " + WiFi.localIP().toString());

  // --- Initialize Firebase ---
  config.api_key = FIREBASE_API_KEY;
  config.database_url = FIREBASE_DATABASE_URL;
  Firebase.begin(&config, &auth);
  Firebase.reconnectWiFi(true);

  // Initialize database node states
  Firebase.setBool(fbdo, "/door_control/trigger", false);
  Firebase.setString(fbdo, "/door_control/status", "ready");

  Serial.println("[Firebase] Ready! Listening for Flutter App commands...");
}

void loop() {
  // Check Firebase Realtime Database node status
  if (Firebase.ready()) {
    if (Firebase.getBool(fbdo, "/door_control/trigger")) {
      if (fbdo.dataType() == "boolean" && fbdo.boolData() == true) {
        Serial.println("\n[Firebase] Received Open/Close command from Flutter App!");

        // 1. Transmit RF signal to gate
        triggerDoorRF();

        // 2. Reset trigger to false so it won't repeat
        Firebase.setBool(fbdo, "/door_control/trigger", false);
        Firebase.setString(fbdo, "/door_control/status", "action_completed");
        
        Serial.println("[Firebase] Status reset to false & action_completed");
      }
    }
  }
  delay(300); // Polling delay interval
}
