#include <WiFi.h>
#include <WebServer.h>
#include <Preferences.h>
#include <PubSubClient.h>
#include <ArduinoJson.h>
#include <NimBLEDevice.h>
#include <Adafruit_NeoPixel.h>

const char* ap_ssid = "ESP32-Config";
const char* ap_password = "12345678";
const char* mqtt_server = "broker.emqx.io";
const int mqtt_port = 1883;

String deviceId;
String bleName;
String command_topic;
String status_topic;
String mqttClientId;

String currentMode = "ble";

String computeDeviceId() {
  uint64_t mac = ESP.getEfuseMac();
  char buf[7];

  snprintf(buf, sizeof(buf), "%06X", (unsigned int)(mac & 0xFFFFFF));
  return String(buf);
}

#define PIN_SEL_9V  6
#define PIN_SEL_12V 7
#define PIN_SEL_15V 5

#define PIN_LED_DATA 4
#define NUM_LEDS 30
Adafruit_NeoPixel strip(NUM_LEDS, PIN_LED_DATA, NEO_GRB + NEO_KHZ800);
String ledMode = "off";
String lastLedEffect = "running";
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

#define SERVICE_UUID "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define CHARACTERISTIC_UUID "beb5483e-36e1-4688-b7f5-ea07361b26a8"
NimBLEServer* pServer = NULL;
NimBLECharacteristic* pCharacteristic = NULL;
bool deviceConnected = false;
String bleCommand = "";

class MyServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* pServer, NimBLEConnInfo& connInfo) { deviceConnected = true; }
  void onDisconnect(NimBLEServer* pServer, NimBLEConnInfo& connInfo, int reason) {
    deviceConnected = false;

    pServer->getAdvertising()->start();
  }
};

class MyCharacteristicCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* pCharacteristic, NimBLEConnInfo& connInfo) {
    String value = pCharacteristic->getValue().c_str();
    if (value.length() > 0) bleCommand = value;
  }
};

void applyVoltage(float volt) {

  if (volt >= 13.5) volt = 15.0;
  else if (volt >= 10.5) volt = 12.0;
  else if (volt >= 7.0) volt = 9.0;
  else volt = 5.0;

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

  currentSetVoltage = volt;
}

void applyLedMode(String mode) {
  if (mode != "off" && mode != "static" && mode != "running" &&
      mode != "disco" && mode != "bounce") return;

  ledMode = mode;
  if (mode != "off") lastLedEffect = mode;

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

}

uint32_t wheelColor(byte pos) {
  pos = 255 - pos;
  if (pos < 85) return strip.Color(255 - pos * 3, 0, pos * 3);
  if (pos < 170) { pos -= 85; return strip.Color(0, pos * 3, 255 - pos * 3); }
  pos -= 170;
  return strip.Color(pos * 3, 255 - pos * 3, 0);
}

void handleLedAnimation() {
  if (ledMode == "running") {
    if (millis() - lastLedStep < 20) return;
    lastLedStep = millis();
    for (int i = 0; i < NUM_LEDS; i++) {
      int hue = ((i * 256 / NUM_LEDS) + rainbowStep) & 255;
      strip.setPixelColor(i, wheelColor(hue));
    }
    strip.show();
    rainbowStep += 3;
    if (rainbowStep >= 256) rainbowStep = 0;

  } else if (ledMode == "disco") {
    if (millis() - lastLedStep < 120) return;
    lastLedStep = millis();
    for (int i = 0; i < NUM_LEDS; i++) {
      strip.setPixelColor(i, strip.Color(random(0, 256), random(0, 256), random(0, 256)));
    }
    strip.show();

  } else if (ledMode == "bounce") {
    if (millis() - lastLedStep < 30) return;
    lastLedStep = millis();
    strip.clear();
    const int tailLen = 4;
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

}

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

void clearModuleCache() {
  applyVoltage(5.0);
  startMillis = millis();
  publishStatus();
}

unsigned long lastMqttAttempt = 0;
void reconnectMQTTNonBlocking() {
  if (mqttClient.connected()) return;
  if (millis() - lastMqttAttempt < 5000) return;
  lastMqttAttempt = millis();
  if (mqttClient.connect(mqttClientId.c_str())) {
    mqttClient.subscribe(command_topic.c_str());
  }
}

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

  if (currentMode == "wifi" && mqttClient.connected()) {
    mqttClient.publish(status_topic.c_str(), jsonStr.c_str());
  }
  if (currentMode == "ble" && deviceConnected && pCharacteristic != NULL) {
    pCharacteristic->setValue(jsonStr.c_str());
    pCharacteristic->notify();
  }
}

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

void handleForgetWiFi() {
  preferences.begin("wifi", false);
  preferences.clear();
  preferences.end();
  server.send(200, "text/plain", "OK, restart ke mode Bluetooth setup...");
  delay(1000);
  ESP.restart();
}

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

void handleDeviceInfo() {
  StaticJsonDocument<128> doc;
  doc["deviceId"] = deviceId;
  doc["bleName"] = bleName;
  doc["mode"] = currentMode;
  String jsonStr;
  serializeJson(doc, jsonStr);
  server.send(200, "application/json", jsonStr);
}

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

void handleSetVoltageHttp() {
  if (server.hasArg("voltage")) {
    applyVoltage(server.arg("voltage").toFloat());
    server.send(200, "application/json", "{\"status\":\"ok\",\"setVoltage\":" + String(currentSetVoltage) + "}");
  } else {
    server.send(400, "text/plain", "Missing voltage");
  }
}

void handleSetLedHttp() {
  if (server.hasArg("mode")) {
    applyLedMode(server.arg("mode"));
    server.send(200, "application/json", "{\"status\":\"ok\",\"ledMode\":\"" + ledMode + "\"}");
  } else {
    server.send(400, "text/plain", "Missing mode");
  }
}

void setupHttpRoutes() {
  server.on("/", handleRootConfig);
  server.on("/setwifi", handleSetWiFi);
  server.on("/scanwifi", handleScanWiFi);
  server.on("/api/set", handleSetVoltageHttp);
  server.on("/api/led", handleSetLedHttp);
  server.on("/api/info", handleDeviceInfo);
  server.on("/api/forgetwifi", handleForgetWiFi);
  server.begin();
}

void startBleMode() {
  currentMode = "ble";
  NimBLEDevice::init(bleName.c_str());
  pServer = NimBLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());
  NimBLEService *pService = pServer->createService(SERVICE_UUID);
  pCharacteristic = pService->createCharacteristic(
    CHARACTERISTIC_UUID,
    NIMBLE_PROPERTY::READ |
    NIMBLE_PROPERTY::WRITE |
    NIMBLE_PROPERTY::NOTIFY
  );

  pCharacteristic->setCallbacks(new MyCharacteristicCallbacks());
  pService->start();
  pServer->getAdvertising()->start();
  Serial.println("=== Tahap A: Mode BLE (setup/pairing) aktif ===");
  Serial.println("BLE name: " + bleName);
  startMillis = millis();
}

void startWifiMode(String savedSSID, String savedPass) {
  currentMode = "wifi";

  WiFi.mode(WIFI_STA);
  WiFi.begin(savedSSID.c_str(), savedPass.c_str());
  int tries = 0;
  while (WiFi.status() != WL_CONNECTED && tries < 20) {
    delay(500);
    Serial.print(".");
    tries++;
  }

  if (WiFi.status() == WL_CONNECTED) {

    Serial.println("\n=== Tahap B: Mode WiFi (STA) aktif ===");
    Serial.println("WiFi terhubung! IP: " + WiFi.localIP().toString());
    mqttClient.setServer(mqtt_server, mqtt_port);
    mqttClient.setCallback(mqttCallback);
    setupHttpRoutes();
    startMillis = millis();
  } else {

    WiFi.mode(WIFI_AP_STA);
    WiFi.softAP(ap_ssid, ap_password);
    Serial.println("\n=== Tahap C: Mode AP fallback (web config) aktif ===");
    Serial.println("AP Mode aktif: " + String(ap_ssid) + " IP: 192.168.4.1");
    setupHttpRoutes();
    startMillis = millis();
  }
}

void handleBleCommand() {
  if (bleCommand.length() == 0) return;

  StaticJsonDocument<192> doc;
  if (!deserializeJson(doc, bleCommand)) {

    if (doc.containsKey("wifi_ssid") && doc.containsKey("wifi_pass")) {
      String ssid = String((const char*)doc["wifi_ssid"]);
      String pass = String((const char*)doc["wifi_pass"]);
      preferences.begin("wifi", false);
      preferences.putString("ssid", ssid);
      preferences.putString("pass", pass);
      preferences.end();
      Serial.println("WiFi diterima lewat BLE, restart ke mode WiFi...");
      bleCommand = "";
      delay(500);
      ESP.restart();
      return;
    }
    if (doc.containsKey("voltage")) applyVoltage(doc["voltage"]);
    if (doc.containsKey("ledMode")) applyLedMode(String((const char*)doc["ledMode"]));
    if (doc.containsKey("action") && String((const char*)doc["action"]) == "clear_cache") {
      clearModuleCache();
    }
  }
  bleCommand = "";
}

void setup() {
  Serial.begin(115200);
  randomSeed(esp_random());

  deviceId = computeDeviceId();
  bleName = "ESP32-Cooler-" + deviceId;
  command_topic = "cooler/" + deviceId + "/command";
  status_topic = "cooler/" + deviceId + "/status";
  mqttClientId = "ESP32Cooler-" + deviceId;
  Serial.println("=== ID Perangkat: " + deviceId + " ===");

  applyVoltage(5.0);

  strip.begin();
  strip.setBrightness(80);
  strip.show();
  applyLedMode("off");

  preferences.begin("wifi", false);
  String savedSSID = preferences.getString("ssid", "");
  String savedPass = preferences.getString("pass", "");
  preferences.end();

  if (savedSSID != "") {

    startWifiMode(savedSSID, savedPass);
  } else {

    startBleMode();
  }
}

void loop() {
  if (currentMode == "ble") {

    handleBleCommand();
    handleLedAnimation();

  } else {

    server.handleClient();
    handleLedAnimation();
    if (WiFi.status() == WL_CONNECTED) {
      reconnectMQTTNonBlocking();
      mqttClient.loop();
    }
  }

  if (millis() - lastPublish > 3000) {
    publishStatus();
    lastPublish = millis();
  }

  delay(10);
}
