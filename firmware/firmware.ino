#include <WiFi.h>
#include <WebServer.h>
#include <Preferences.h>
#include <PubSubClient.h>
#include <ArduinoJson.h>
#include <BLEDevice.h>
#include <BLEUtils.h>
#include <BLEServer.h>
#include <BLE2902.h>
#include <Adafruit_NeoPixel.h>

// ===================================================================
// Board: ESP32-C3 Super Mini
// Pin layout papan (kiri atas -> bawah): 5V, G, 3.3, 4, 3, 2, 1, 0
// Pin layout papan (kanan atas -> bawah): 5, 6, 7, 8, 9, 10, 20, 21
// GPIO 2, 8, 9 SENGAJA TIDAK DIPAKAI:
//   - GPIO9 = tombol BOOT onboard (strapping pin, jangan dipakai)
//   - GPIO8 = LED onboard
//   - GPIO2 = strapping pin
// ===================================================================

// ===== KONFIGURASI =====
const char* ap_ssid = "ESP32-Config";
const char* ap_password = "12345678";
const char* mqtt_server = "broker.emqx.io";
const int mqtt_port = 1883;

// ===== ID UNIK PER PERANGKAT =====
// Diambil dari MAC address chip (efuse), beda-beda otomatis di tiap unit ESP32.
// Dipakai supaya BANYAK unit bisa jalan bareng tanpa tumbukan: tiap unit
// punya nama Bluetooth sendiri dan "jalur" MQTT sendiri (bukan topic global).
String deviceId;        // contoh: "A1B2C3"
String bleName;          // contoh: "ESP32-Cooler-A1B2C3"
String command_topic;    // contoh: "cooler/A1B2C3/command"
String status_topic;     // contoh: "cooler/A1B2C3/status"
String mqttClientId;     // contoh: "ESP32Cooler-A1B2C3" (biar tidak saling nendang di broker)

String computeDeviceId() {
  uint64_t mac = ESP.getEfuseMac();
  char buf[7];
  // Ambil 3 byte terakhir dari MAC supaya pendek tapi tetap unik antar unit
  snprintf(buf, sizeof(buf), "%06X", (unsigned int)(mac & 0xFFFFFF));
  return String(buf);
}

// ===== PIN DECOY BOARD (PD3.1 QC3.0 Trigger, output "A") =====
// Pad "1" di board decoy -> pilih 9V saat dihubungkan ke GND
// Pad "2" di board decoy -> pilih 12V saat dihubungkan ke GND
// Pad "3" di board decoy -> pilih 15V saat dihubungkan ke GND
// Tidak ada pad yang disolder = default 5V (jangan sambungkan pad 4)
#define PIN_SEL_9V  6
#define PIN_SEL_12V 7
#define PIN_SEL_15V 5

// ===== LED STRIP WS2812B/SK6812 (3 kabel: hitam=GND, merah=5V, kuning=Data) =====
// Beda dari LED auto-cycle sebelumnya: strip ini dikontrol digital per-LED,
// jadi warna & efek "berjalan" dikerjakan ESP32 lewat library Adafruit NeoPixel.
// Wiring: kuning (Data) -> GPIO4 (idealnya lewat resistor seri 330-470 ohm),
// hitam (GND) -> GND yang sama dengan ESP32, merah (5V) -> sumber 5V terpisah
// (JANGAN dari pin 5V ESP32 kalau LED banyak, arusnya bisa jauh lebih besar
// dari yang sanggup disuplai ESP32).
#define PIN_LED_DATA 4
#define NUM_LEDS 30   // <-- GANTI sesuai JUMLAH LED ASLI di strip kamu (hitung manual)
Adafruit_NeoPixel strip(NUM_LEDS, PIN_LED_DATA, NEO_GRB + NEO_KHZ800);
String ledMode = "off"; // "off" | "static" | "running" | "disco" | "bounce"
String lastLedEffect = "running"; // efek terakhir dipilih, dipakai saat tombol ON ditekan
unsigned long lastLedStep = 0;
uint16_t rainbowStep = 0;
int bouncePos = 0;
int bounceDir = 1;

Preferences preferences;
WebServer server(80);
WiFiClient espClient;
PubSubClient mqttClient(espClient);

float currentSetVoltage = 5.0;
unsigned long startMillis = 0;
unsigned long lastPublish = 0;

// ===== BLE =====
#define SERVICE_UUID "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define CHARACTERISTIC_UUID "beb5483e-36e1-4688-b7f5-ea07361b26a8"
BLEServer* pServer = NULL;
BLECharacteristic* pCharacteristic = NULL;
bool deviceConnected = false;
String bleCommand = "";

class MyServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) { deviceConnected = true; }
  void onDisconnect(BLEServer* pServer) {
    deviceConnected = false;
    // Lanjut advertise lagi supaya app bisa reconnect
    pServer->getAdvertising()->start();
  }
};

class MyCharacteristicCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* pCharacteristic) {
    String value = pCharacteristic->getValue().c_str();
    if (value.length() > 0) bleCommand = value;
  }
};

// ===== FUNGSI SET VOLTASE (khusus board decoy 1-pad-select) =====
// Board ini BUKAN CH224K biner (CFG1/2/3 kombinasi). Board ini cuma
// boleh 1 pad aktif (LOW) dalam satu waktu, sisanya HARUS floating.
void applyVoltage(float volt) {
  // Snap ke nilai terdekat yang benar-benar disupport hardware: 5 / 9 / 12 / 15
  if (volt >= 13.5) volt = 15.0;
  else if (volt >= 10.5) volt = 12.0;
  else if (volt >= 7.0) volt = 9.0;
  else volt = 5.0;

  // Lepas semua pin dulu (floating = tidak menyolder pad apapun = default 5V)
  pinMode(PIN_SEL_9V, INPUT);
  pinMode(PIN_SEL_12V, INPUT);
  pinMode(PIN_SEL_15V, INPUT);

  if (volt == 9.0) {
    pinMode(PIN_SEL_9V, OUTPUT);
    digitalWrite(PIN_SEL_9V, LOW);
  } else if (volt == 12.0) {
    pinMode(PIN_SEL_12V, OUTPUT);
    digitalWrite(PIN_SEL_12V, LOW);
  } else if (volt == 15.0) {
    pinMode(PIN_SEL_15V, OUTPUT);
    digitalWrite(PIN_SEL_15V, LOW);
  }
  // volt == 5.0 -> ketiga pin dibiarkan floating (INPUT), tidak ada yang disolder

  currentSetVoltage = volt;
}

// ===== FUNGSI SET MODE LAMPU =====
// "off"     -> matikan semua LED
// "static"  -> gradient warna tetap, tidak bergerak (nyala diam)
// "running" -> pelangi berjalan 1 arah
// "disco"   -> warna acak berkedip cepat di semua LED
// "bounce"  -> titik cahaya bolak-balik sepanjang strip
void applyLedMode(String mode) {
  if (mode != "off" && mode != "static" && mode != "running" &&
      mode != "disco" && mode != "bounce") return;

  ledMode = mode;
  if (mode != "off") lastLedEffect = mode; // ingat efek terakhir buat tombol ON

  if (mode == "off") {
    strip.clear();
    strip.show();
  } else if (mode == "static") {
    for (int i = 0; i < NUM_LEDS; i++) {
      int hue = (i * 256 / NUM_LEDS) & 255;
      strip.setPixelColor(i, wheelColor(hue));
    }
    strip.show();
  } else if (mode == "bounce") {
    bouncePos = 0;
    bounceDir = 1;
  }
  // "running" & "disco" -> animasinya diproses tiap frame di handleLedAnimation()
}

// ===== FUNGSI BANTU: WARNA PELANGI DARI 1 ANGKA (0-255) =====
uint32_t wheelColor(byte pos) {
  pos = 255 - pos;
  if (pos < 85) return strip.Color(255 - pos * 3, 0, pos * 3);
  if (pos < 170) { pos -= 85; return strip.Color(0, pos * 3, 255 - pos * 3); }
  pos -= 170;
  return strip.Color(pos * 3, 255 - pos * 3, 0);
}

// ===== ANIMASI LAMPU (dipanggil terus-menerus di loop()) =====
void handleLedAnimation() {
  if (ledMode == "running") {
    if (millis() - lastLedStep < 20) return; // kecepatan animasi (ms/frame)
    lastLedStep = millis();
    for (int i = 0; i < NUM_LEDS; i++) {
      int hue = ((i * 256 / NUM_LEDS) + rainbowStep) & 255;
      strip.setPixelColor(i, wheelColor(hue));
    }
    strip.show();
    rainbowStep += 3;
    if (rainbowStep >= 256) rainbowStep = 0;

  } else if (ledMode == "disco") {
    if (millis() - lastLedStep < 120) return; // kecepatan kedip disko
    lastLedStep = millis();
    for (int i = 0; i < NUM_LEDS; i++) {
      strip.setPixelColor(i, strip.Color(random(0, 256), random(0, 256), random(0, 256)));
    }
    strip.show();

  } else if (ledMode == "bounce") {
    if (millis() - lastLedStep < 30) return; // kecepatan gerak titik
    lastLedStep = millis();
    strip.clear();
    const int tailLen = 4; // panjang ekor cahaya
    for (int t = 0; t < tailLen; t++) {
      int pos = bouncePos - (bounceDir * t);
      if (pos >= 0 && pos < NUM_LEDS) {
        int fade = 255 - (t * (255 / tailLen));
        uint32_t c = wheelColor((bouncePos * 8) & 255);
        uint8_t r = (uint8_t)(((c >> 16) & 0xFF) * fade / 255);
        uint8_t g = (uint8_t)(((c >> 8) & 0xFF) * fade / 255);
        uint8_t b = (uint8_t)((c & 0xFF) * fade / 255);
        strip.setPixelColor(pos, strip.Color(r, g, b));
      }
    }
    strip.show();
    bouncePos += bounceDir;
    if (bouncePos >= NUM_LEDS - 1 || bouncePos <= 0) bounceDir = -bounceDir;
  }
  // "static" & "off" -> tidak perlu update tiap frame, sudah digambar sekali di applyLedMode()
}

// ===== MQTT CALLBACK =====
void mqttCallback(char* topic, byte* payload, unsigned int length) {
  String msg;
  for (unsigned int i = 0; i < length; i++) msg += (char)payload[i];
  StaticJsonDocument<128> doc;
  if (deserializeJson(doc, msg)) return;
  if (doc.containsKey("voltage")) applyVoltage(doc["voltage"]);
  if (doc.containsKey("ledMode")) applyLedMode(String((const char*)doc["ledMode"]));
  if (doc.containsKey("action") && String((const char*)doc["action"]) == "clear_cache") {
    clearModuleCache();
  }
}

// ===== BERSIHKAN "CACHE" MODUL =====
// ESP32 tidak punya cache aplikasi seperti HP, jadi tombol ini mereset
// state runtime yang tersimpan sementara di RAM: uptime dihitung ulang
// dari 0 dan voltase dikembalikan ke default 5V. Kredensial WiFi yang
// tersimpan di NVS (Preferences) TIDAK dihapus supaya ESP32 tidak
// kehilangan koneksi WiFi rumah kamu.
void clearModuleCache() {
  applyVoltage(5.0);
  startMillis = millis();
  publishStatus();
}

// ===== REKONEKSI MQTT (non-blocking, tidak nge-freeze BLE/HTTP) =====
unsigned long lastMqttAttempt = 0;
void reconnectMQTTNonBlocking() {
  if (mqttClient.connected()) return;
  if (millis() - lastMqttAttempt < 5000) return;
  lastMqttAttempt = millis();
  if (mqttClient.connect(mqttClientId.c_str())) {
    mqttClient.subscribe(command_topic.c_str());
  }
}

// ===== PUBLISH STATUS =====
void publishStatus() {
  unsigned long runtime = millis() - startMillis;
  long s = runtime / 1000, m = s / 60, h = m / 60;
  String uptime = String(h) + ":" + String(m % 60) + ":" + String(s % 60);

  StaticJsonDocument<256> doc;
  doc["deviceId"] = deviceId;
  doc["setVoltage"] = currentSetVoltage;
  doc["ledMode"] = ledMode;
  doc["uptime"] = uptime;
  String jsonStr;
  serializeJson(doc, jsonStr);

  if (mqttClient.connected()) {
    mqttClient.publish(status_topic.c_str(), jsonStr.c_str());
  }
  if (deviceConnected) {
    pCharacteristic->setValue(jsonStr.c_str());
    pCharacteristic->notify();
  }
}

// ===== API: SET WiFi =====
void handleSetWiFi() {
  if (server.hasArg("ssid") && server.hasArg("password")) {
    String ssid = server.arg("ssid");
    String pass = server.arg("password");
    preferences.begin("wifi", false);
    preferences.putString("ssid", ssid);
    preferences.putString("pass", pass);
    preferences.end();
    server.send(200, "text/plain", "OK");
    delay(1000);
    ESP.restart();
  } else {
    server.send(400, "text/plain", "Missing ssid or password");
  }
}

// ===== HALAMAN KONFIGURASI WiFi =====
void handleRootConfig() {
  String html = "<html><head><meta name='viewport' content='width=device-width'><title>WiFi Setup</title>"
                "<style>body{background:#0b0e14;color:#fff;font-family:sans-serif;text-align:center;padding:40px 20px;}"
                "input,button{padding:14px;width:80%;margin:10px;border-radius:12px;border:none;font-size:16px;}"
                "button{background:#00e5ff;color:#000;font-weight:bold;}</style></head>"
                "<body><h2>⚙️ Set WiFi</h2><p style='opacity:.6;font-size:13px'>ID Perangkat: " + deviceId + "</p><form action='/setwifi' method='GET'>"
                "<input name='ssid' placeholder='Nama WiFi' required><br>"
                "<input name='password' type='password' placeholder='Password' required><br>"
                "<button type='submit'>Simpan & Restart</button></form></body></html>";
  server.send(200, "text/html", html);
}

// ===== API: Info perangkat (ID unik, dipakai app buat verifikasi) =====
void handleDeviceInfo() {
  StaticJsonDocument<128> doc;
  doc["deviceId"] = deviceId;
  doc["bleName"] = bleName;
  String jsonStr;
  serializeJson(doc, jsonStr);
  server.send(200, "application/json", jsonStr);
}

// ===== API: Scan WiFi =====
// n == -2 -> scan belum pernah dimulai -> trigger scan, balas {"status":"scanning"}
// n == -1 -> scan sedang berjalan (BUKAN error!) -> balas {"status":"scanning"} juga,
//            biar app tahu harus coba lagi sebentar lagi, bukan berhenti dgn pesan error
// n == 0  -> scan selesai, tidak ada jaringan ditemukan -> balas array kosong []
// n > 0   -> scan selesai, ada hasil -> balas array hasil
void handleScanWiFi() {
  int n = WiFi.scanComplete();
  String json;
  if (n == -2) {
    WiFi.scanNetworks(true);
    json = "{\"status\":\"scanning\"}";
  } else if (n == -1) {
    json = "{\"status\":\"scanning\"}";
  } else {
    json = "[";
    for (int i = 0; i < n; ++i) {
      if (i) json += ",";
      json += "{\"ssid\":\"" + WiFi.SSID(i) + "\",\"rssi\":" + String(WiFi.RSSI(i)) + "}";
    }
    json += "]";
    if (n > 0) WiFi.scanDelete();
  }
  server.send(200, "application/json", json);
}

// ===== API: SET VOLTAGE via HTTP (fallback saat AP mode) =====
void handleSetVoltageHttp() {
  if (server.hasArg("voltage")) {
    applyVoltage(server.arg("voltage").toFloat());
    server.send(200, "application/json", "{\"status\":\"ok\",\"setVoltage\":" + String(currentSetVoltage) + "}");
  } else {
    server.send(400, "text/plain", "Missing voltage");
  }
}

// ===== API: SET MODE LAMPU via HTTP (fallback saat AP mode) =====
void handleSetLedHttp() {
  if (server.hasArg("mode")) {
    applyLedMode(server.arg("mode"));
    server.send(200, "application/json", "{\"status\":\"ok\",\"ledMode\":\"" + ledMode + "\"}");
  } else {
    server.send(400, "text/plain", "Missing mode");
  }
}

// ===== SETUP =====
void setup() {
  Serial.begin(115200);
  randomSeed(esp_random());

  // ===== HITUNG ID UNIK PERANGKAT (WAJIB paling awal, dipakai di semua tempat) =====
  deviceId = computeDeviceId();
  bleName = "ESP32-Cooler-" + deviceId;
  command_topic = "cooler/" + deviceId + "/command";
  status_topic = "cooler/" + deviceId + "/status";
  mqttClientId = "ESP32Cooler-" + deviceId;
  Serial.println("=== ID Perangkat: " + deviceId + " ===");
  Serial.println("BLE name: " + bleName);
  Serial.println("MQTT command topic: " + command_topic);

  // Voltage select pins: default floating (5V), belum ada yang disolder ke GND
  applyVoltage(5.0);

  // Lampu: mulai strip, batasi brightness biar arus aman, lalu matikan dulu
  strip.begin();
  strip.setBrightness(80); // 0-255; makin tinggi makin terang TAPI makin besar arusnya
  strip.show();
  applyLedMode("off");

  // ===== BACA WIFI TERSIMPAN =====
  preferences.begin("wifi", false);
  String savedSSID = preferences.getString("ssid", "");
  String savedPass = preferences.getString("pass", "");
  preferences.end();

  // ===== START BLE =====
  BLEDevice::init(bleName.c_str());
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());
  BLEService *pService = pServer->createService(SERVICE_UUID);
  pCharacteristic = pService->createCharacteristic(
    CHARACTERISTIC_UUID,
    BLECharacteristic::PROPERTY_READ |
    BLECharacteristic::PROPERTY_WRITE |
    BLECharacteristic::PROPERTY_NOTIFY
  );
  pCharacteristic->addDescriptor(new BLE2902());
  pCharacteristic->setCallbacks(new MyCharacteristicCallbacks());
  pService->start();
  pServer->getAdvertising()->start();
  Serial.println("BLE siap!");

  // ===== HTTP endpoints (dipakai baik di AP mode maupun WiFi mode) =====
  server.on("/", handleRootConfig);
  server.on("/setwifi", handleSetWiFi);
  server.on("/scanwifi", handleScanWiFi);
  server.on("/api/set", handleSetVoltageHttp);
  server.on("/api/led", handleSetLedHttp);
  server.on("/api/info", handleDeviceInfo);
  server.begin();

  // ===== COBA KONEK WIFI =====
  if (savedSSID != "") {
    WiFi.mode(WIFI_STA);
    WiFi.begin(savedSSID.c_str(), savedPass.c_str());
    int tries = 0;
    while (WiFi.status() != WL_CONNECTED && tries < 20) {
      delay(500);
      Serial.print(".");
      tries++;
    }
    if (WiFi.status() == WL_CONNECTED) {
      Serial.println("\nWiFi terhubung! IP: " + WiFi.localIP().toString());
      mqttClient.setServer(mqtt_server, mqtt_port);
      mqttClient.setCallback(mqttCallback);
      startMillis = millis();
      return;
    }
  }

  // ===== JIKA GAGAL -> AP MODE =====
  // PENTING: pakai WIFI_AP_STA (bukan WIFI_AP murni). Radio STA wajib aktif
  // supaya WiFi.scanNetworks() di handleScanWiFi() bisa jalan. Kalau cuma
  // WIFI_AP, scan WiFi sekitar akan selalu gagal/timeout (dikonfirmasi di
  // banyak laporan ESP32/ESP-IDF: scanning butuh interface STA aktif).
  WiFi.mode(WIFI_AP_STA);
  WiFi.softAP(ap_ssid, ap_password);
  Serial.println("AP Mode aktif: " + String(ap_ssid) + " IP: 192.168.4.1");
  startMillis = millis();
}

void loop() {
  // ===== Proses Perintah BLE =====
  if (bleCommand.length() > 0) {
    StaticJsonDocument<128> doc;
    if (!deserializeJson(doc, bleCommand)) {
      if (doc.containsKey("voltage")) applyVoltage(doc["voltage"]);
      if (doc.containsKey("ledMode")) applyLedMode(String((const char*)doc["ledMode"]));
      if (doc.containsKey("action") && String((const char*)doc["action"]) == "clear_cache") {
        clearModuleCache();
      }
    }
    bleCommand = "";
  }

  server.handleClient();

  // ===== Jalankan 1 frame animasi lampu (kalau mode running/disco/bounce) =====
  handleLedAnimation();

  // ===== Mode WiFi: MQTT =====
  if (WiFi.status() == WL_CONNECTED) {
    reconnectMQTTNonBlocking();
    mqttClient.loop();
  }

  // ===== Publish status berkala (WiFi & BLE) =====
  if (millis() - lastPublish > 3000) {
    publishStatus();
    lastPublish = millis();
  }

  delay(10);
}
