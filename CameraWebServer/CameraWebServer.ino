#include "esp_camera.h"
#include <WiFi.h>
#include <Preferences.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>

// ===================
// Camera model
// ===================
#define CAMERA_MODEL_AI_THINKER
#include "camera_pins.h"

// ===========================
// WiFi credentials
// ===========================
const char *ssid = "Asif";
const char *password = "asifFoisal";

// ===========================
// Firebase (REST API)
// ===========================
const char *firebaseHost = "https://babymonitor-9ea16-default-rtdb.firebaseio.com/"; // Replace with your Firebase Realtime Database URL
const char *firebaseAuth = "6A6CJJ2qkzdUdLkrdSl7AOdkwQt895ZpmBI4nx7t";               // Replace with database secret or auth token
const char *firebaseDevicePath = "/devices/esp32cam";                                // Location to store the latest IP

// ===========================
// Sound Sensor
// ===========================
const int soundPin = 14; // Connect DO pin of sensor to GPIO14

// ===========================
// Web server
// ===========================
#include <WebServer.h>
WebServer server(80);

// ===========================
// WiFi configuration portal
// ===========================
constexpr char AP_SSID[] = "ESP32CAM-Setup";
constexpr char AP_PASSWORD[] = "configure"; // 8 chars min
constexpr uint8_t WIFI_RETRY_LIMIT = 5;

enum RunMode
{
  MODE_CAMERA,
  MODE_CONFIG
};

RunMode runMode = MODE_CONFIG;
String storedSsid;
String storedPassword;

// ===========================
// Function prototypes
// ===========================
void handleRoot();
void handleStream();
void setupCamera();
void startSimpleServer();
void setupLedFlash(int pin);
void startConfigPortal();
void handleConfigRoot();
void handleConfigSave();
bool connectToWiFi(const char *targetSsid, const char *targetPassword, uint8_t maxRetries = WIFI_RETRY_LIMIT);
void loadStoredCredentials();
void saveCredentials(const String &ssidValue, const String &passwordValue);
void publishIpToFirebase(const IPAddress &ip);

void setup()
{
  Serial.begin(115200);
  Serial.println();
  Serial.println("Starting ESP32-CAM...");

  // Initialize sound sensor pin
  pinMode(soundPin, INPUT); // DO is digital output

  loadStoredCredentials();

  bool connected = false;

  if (storedSsid.length() > 0)
  {
    Serial.print("Found stored WiFi credentials for SSID: ");
    Serial.println(storedSsid);
    connected = connectToWiFi(storedSsid.c_str(), storedPassword.c_str());
  }

  if (!connected && strlen(ssid) > 0)
  {
    Serial.println("Falling back to compiled WiFi credentials.");
    connected = connectToWiFi(ssid, password);
    if (connected)
    {
      storedSsid = ssid;
      storedPassword = password;
      saveCredentials(storedSsid, storedPassword);
    }
  }

  if (connected)
  {
    runMode = MODE_CAMERA;
    setupCamera();
    startSimpleServer();
    publishIpToFirebase(WiFi.localIP());
  }
  else
  {
    Serial.println("No valid WiFi credentials available; starting configuration portal.");
    startConfigPortal();
  }
}

void loop()
{
  server.handleClient();

  // Sound sensor monitoring
  int soundState = digitalRead(soundPin);

  if (soundState == HIGH)
  {
    Serial.println("Sound detected!");
  }

  delay(100); // Small delay to avoid flooding Serial
}

// ===========================
// Camera setup
// ===========================
void setupCamera()
{
  camera_config_t config;
  config.ledc_channel = LEDC_CHANNEL_0;
  config.ledc_timer = LEDC_TIMER_0;
  config.pin_d0 = Y2_GPIO_NUM;
  config.pin_d1 = Y3_GPIO_NUM;
  config.pin_d2 = Y4_GPIO_NUM;
  config.pin_d3 = Y5_GPIO_NUM;
  config.pin_d4 = Y6_GPIO_NUM;
  config.pin_d5 = Y7_GPIO_NUM;
  config.pin_d6 = Y8_GPIO_NUM;
  config.pin_d7 = Y9_GPIO_NUM;
  config.pin_xclk = XCLK_GPIO_NUM;
  config.pin_pclk = PCLK_GPIO_NUM;
  config.pin_vsync = VSYNC_GPIO_NUM;
  config.pin_href = HREF_GPIO_NUM;
  config.pin_sccb_sda = SIOD_GPIO_NUM;
  config.pin_sccb_scl = SIOC_GPIO_NUM;
  config.pin_pwdn = PWDN_GPIO_NUM;
  config.pin_reset = RESET_GPIO_NUM;
  config.xclk_freq_hz = 20000000;

  // GC2145 camera requires RGB565
  config.pixel_format = PIXFORMAT_RGB565;
  config.frame_size = FRAMESIZE_QVGA; // 320x240 for stability
  config.fb_count = psramFound() ? 2 : 1;
  config.grab_mode = CAMERA_GRAB_WHEN_EMPTY;
  config.fb_location = CAMERA_FB_IN_PSRAM;

  esp_err_t err = esp_camera_init(&config);
  if (err != ESP_OK)
  {
    Serial.printf("Camera init failed with error 0x%x\n", err);
    while (true)
      delay(1000); // Stop here
  }

  sensor_t *s = esp_camera_sensor_get();
  s->set_brightness(s, 1);
  s->set_saturation(s, -2);

#if defined(LED_GPIO_NUM)
  setupLedFlash(LED_GPIO_NUM);
#endif
}

// ===========================
// Web server setup
// ===========================
void startSimpleServer()
{
  server.on("/", handleRoot);
  server.on("/stream", handleStream);
  server.begin();
  Serial.println("Web server started.");
}

// ===========================
// Web page handlers
// ===========================
void handleRoot()
{
  String html = "<html><head><title>ESP32-CAM GC2145 Stream</title></head><body>";
  html += "<h1>ESP32-CAM RGB565 Stream</h1>";
  html += "<img src=\"/stream\" width=\"320\" height=\"240\" />";
  html += "</body></html>";
  server.send(200, "text/html", html);
}

void handleStream()
{
  WiFiClient client = server.client();
  client.println("HTTP/1.1 200 OK");
  client.println("Content-Type: multipart/x-mixed-replace; boundary=frame");
  client.println("Connection: close");
  client.println();

  while (client.connected())
  {
    camera_fb_t *fb = esp_camera_fb_get();
    if (!fb)
    {
      Serial.println("Camera capture failed");
      continue;
    }

    // Convert RGB565 to JPEG
    uint8_t *jpeg_buf = NULL;
    size_t jpeg_len = 0;
    bool jpeg_success = frame2jpg(fb, 80, &jpeg_buf, &jpeg_len);
    esp_camera_fb_return(fb);

    if (!jpeg_success)
    {
      Serial.println("JPEG conversion failed");
      continue;
    }

    client.printf("--frame\r\nContent-Type: image/jpeg\r\nContent-Length: %u\r\n\r\n", (uint32_t)jpeg_len);
    client.write(jpeg_buf, jpeg_len);
    client.write("\r\n");
    free(jpeg_buf);

    if (!client.connected())
      break;
  }
}

// ===========================
// LED flash (optional)
// ===========================
void myLedFlash(int pin)
{
  pinMode(pin, OUTPUT);
  digitalWrite(pin, LOW);
}

// ===========================
// WiFi helpers & captive portal
// ===========================
bool connectToWiFi(const char *targetSsid, const char *targetPassword, uint8_t maxRetries)
{
  if (!targetSsid || strlen(targetSsid) == 0)
  {
    return false;
  }

  WiFi.mode(WIFI_STA);
  WiFi.begin(targetSsid, targetPassword);
  WiFi.setSleep(false);
  Serial.print("Connecting to WiFi");

  uint8_t attempt = 0;
  while (WiFi.status() != WL_CONNECTED && attempt < maxRetries)
  {
    delay(500);
    Serial.print(".");
    attempt++;
  }

  if (WiFi.status() == WL_CONNECTED)
  {
    Serial.println("\nWiFi connected!");
    Serial.print("IP address: ");
    Serial.println(WiFi.localIP());
    return true;
  }

  Serial.println("\nFailed to connect to WiFi.");
  WiFi.disconnect(true);
  delay(200);
  return false;
}

void startConfigPortal()
{
  runMode = MODE_CONFIG;
  WiFi.mode(WIFI_AP);
  WiFi.softAP(AP_SSID, AP_PASSWORD);

  server.on("/", HTTP_GET, handleConfigRoot);
  server.on("/save", HTTP_POST, handleConfigSave);
  server.onNotFound(handleConfigRoot);
  server.begin();

  Serial.print("Config portal ready. Connect to SSID '");
  Serial.print(AP_SSID);
  Serial.print("' and browse to ");
  Serial.println(WiFi.softAPIP());
}

void handleConfigRoot()
{
  String html = "<!DOCTYPE html><html><head><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">";
  html += "<title>ESP32-CAM Setup</title></head><body style=\"font-family:Arial;margin:2em;\">";
  html += "<h2>Configure WiFi</h2>";
  html += "<form method=\"POST\" action=\"/save\">";
  html += "<label>SSID:<br><input name=\"ssid\" value=\"";
  html += storedSsid;
  html += "\" required></label><br><br>";
  html += "<label>Password:<br><input type=\"password\" name=\"password\" value=\"";
  html += storedPassword;
  html += "\" required></label><br><br>";
  html += "<button type=\"submit\">Save</button></form>";
  html += "<p>After saving, the device will reboot and attempt to join the configured network.</p>";
  html += "</body></html>";
  server.send(200, "text/html", html);
}

void handleConfigSave()
{
  if (!server.hasArg("ssid") || !server.hasArg("password"))
  {
    server.send(400, "text/plain", "Missing ssid or password parameters.");
    return;
  }

  storedSsid = server.arg("ssid");
  storedPassword = server.arg("password");

  saveCredentials(storedSsid, storedPassword);

  server.send(200, "text/html", "<html><body><h2>Saved! Restarting...</h2></body></html>");
  Serial.println("Credentials saved. Restarting to apply new WiFi settings.");
  delay(1000);
  ESP.restart();
}

void loadStoredCredentials()
{
  Preferences prefs;
  if (prefs.begin("wifi", true))
  { // read-only
    storedSsid = prefs.getString("ssid", "");
    storedPassword = prefs.getString("pass", "");
    prefs.end();
  }
  else
  {
    storedSsid = "";
    storedPassword = "";
  }
}

void saveCredentials(const String &ssidValue, const String &passwordValue)
{
  Preferences prefs;
  if (prefs.begin("wifi", false))
  { // read-write
    prefs.putString("ssid", ssidValue);
    prefs.putString("pass", passwordValue);
    prefs.end();
  }
}

void publishIpToFirebase(const IPAddress &ip)
{
  if (!firebaseHost || strlen(firebaseHost) == 0 || !firebaseAuth || strlen(firebaseAuth) == 0)
  {
    Serial.println("Firebase host/auth not configured; skipping IP publish.");
    return;
  }

  WiFiClientSecure client;
  client.setInsecure(); // Accept all certificates; replace with Firebase root CA for production use.

  HTTPClient http;
  String url = String(firebaseHost) + String(firebaseDevicePath) + ".json?auth=" + firebaseAuth;

  if (!http.begin(client, url))
  {
    Serial.println("Failed to initialise HTTP client for Firebase.");
    return;
  }

  String payload = String("{\"ip\":\"") + ip.toString() + "\"}";
  http.addHeader("Content-Type", "application/json");

  int httpCode = http.PUT(payload);
  if (httpCode > 0)
  {
    Serial.printf("Firebase update HTTP %d\n", httpCode);
  }
  else
  {
    Serial.printf("Firebase update failed: %s\n", http.errorToString(httpCode).c_str());
  }

  http.end();
}
