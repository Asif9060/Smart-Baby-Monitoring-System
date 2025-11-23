#include <DHT.h>
#include <WiFi.h>
#include <Preferences.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <math.h>
#include <WebServer.h>
#if defined(ESP32)
#include <esp32-hal-adc.h>
#endif

// Pin assignments and sensor configuration
#define DHTPIN 13
#define DHTTYPE DHT22
const int PIR_PIN = 14;
const int SOUND_ANALOG = 34;
const int LED_PIN = 2;

// Sound detection tuning
const int SOUND_THRESHOLD = 700;       // Upper clamp for adaptive trigger
const int SOUND_MIN_THRESHOLD = 420;   // Never drop below this value
const int SOUND_TRIGGER_MARGIN = 60;   // Margin added on top of rolling baseline
const uint8_t SOUND_SAMPLE_COUNT = 12; // More samples for finer granularity
const unsigned long SOUND_SNAPSHOT_INTERVAL_MS = 3000;
const int SOUND_LEVEL_CHANGE_DELTA = 35;

// Comfort range targets
const float TEMP_MIN = 22.0f;
const float TEMP_MAX = 28.0f;
const float HUMID_MIN = 40.0f;
const float HUMID_MAX = 60.0f;

// DHT sampling cadence
const unsigned long DHT_INTERVAL_MS = 2000;
const unsigned long STATUS_UPDATE_INTERVAL_MS = 60000;

// WiFi credentials
constexpr char DEFAULT_WIFI_SSID[] = "Asif";
constexpr char DEFAULT_WIFI_PASS[] = "asifFoisal";
constexpr uint8_t WIFI_RETRY_LIMIT = 5;
const unsigned long WIFI_RECONNECT_INTERVAL_MS = 30000;

// AP mode configuration
const char *AP_SSID = "BabyMonitor_Config";
const char *AP_PASSWORD = "12345678";
const unsigned long AP_TIMEOUT_MS = 300000; // 5 minutes

// Firebase configuration
const char *firebaseHost = "https://babymonitor-9ea16-default-rtdb.firebaseio.com/";
const char *firebaseAuth = "6A6CJJ2qkzdUdLkrdSl7AOdkwQt895ZpmBI4nx7t";
const char *firebaseDevicePath = "/devices/baby_monitor";
const char *firebaseReadingsPath = "/devices/baby_monitor/readings";
const char *firebaseStatusPath = "/devices/baby_monitor/status";
const char *firebaseEventsPath = "/devices/baby_monitor/events";

enum class FirebaseMethod : uint8_t
{
    Post,
    Patch,
    Put
};

enum class SoundCategory : uint8_t
{
    Silent,
    Quiet,
    Moderate,
    Loud,
    Extreme
};

DHT dht(DHTPIN, DHTTYPE);

bool lastMotionState = false;
bool motionState = false;
bool soundAboveThreshold = false;
bool previousSoundAboveThreshold = false;
int lastSoundLevel = 0;
SoundCategory lastSoundCategory = SoundCategory::Silent;
unsigned long lastSoundSnapshotPublish = 0;
unsigned long lastSoundLog = 0;
int lastPublishedSoundLevel = -1;
int soundBaseline = 0;
bool soundBaselineValid = false;
int adaptiveSoundTrigger = SOUND_THRESHOLD;
float lastTemperature = NAN;
float lastHumidity = NAN;
unsigned long lastDhtSample = 0;
unsigned long lastWiFiReconnectAttempt = 0;
unsigned long lastStatusPublish = 0;
String storedSsid;
String storedPassword;
WebServer server(80);
bool httpServerStarted = false;
bool apModeActive = false;
unsigned long apModeStartTime = 0;

// Function prototypes
void handleDht(unsigned long now);
void handleMotion(unsigned long now);
void handleSound(unsigned long now);
bool connectToWiFi(const char *targetSsid, const char *targetPassword, uint8_t maxRetries = WIFI_RETRY_LIMIT);
void maintainWiFiConnection(unsigned long now);
void loadStoredCredentials();
void saveCredentials(const String &ssidValue, const String &passwordValue);
void publishStatusHeartbeat(unsigned long now);
void publishDeviceStatus(const IPAddress &ip, unsigned long timestamp, bool online);
void publishSensorData(unsigned long timestamp, float temperature, float humidity, bool tempOK, bool humidOK);
void publishMotionEvent(unsigned long timestamp);
void publishSoundEvent(unsigned long timestamp, int level);
void publishSoundSnapshot(unsigned long timestamp, int level, bool thresholdExceeded);
bool firebaseSend(const String &path, const String &payload, FirebaseMethod method);
void setupHttpServer();
String buildStatusJson();
void handleStatusPage();
void handleStatusJson();
SoundCategory determineSoundCategory(int level);
const char *soundCategoryLabel(SoundCategory category);
void startConfigPortal();
void setupConfigPortal();
void handleConfigPage();
void handleWifiSave();
void handleWifiScan();

void setup()
{
    Serial.begin(115200);
    dht.begin();

    pinMode(PIR_PIN, INPUT);
    pinMode(LED_PIN, OUTPUT);
    pinMode(SOUND_ANALOG, INPUT);
#if defined(ESP32)
    analogReadResolution(12);
    analogSetPinAttenuation(SOUND_ANALOG, ADC_11db);
#endif

    Serial.println("Integrated Environment Monitor ready.");
    Serial.println("DHT22 on GPIO 13 | PIR on GPIO 14 | Sound sensor on GPIO 34 (ADC1_CH6)");
    Serial.println("Ideal range: Temp 22-28 C | Humidity 40-60 %");
    Serial.println("Sound sensor input pin: GPIO 34 (ADC1_CH6) - connect analog OUT here.");

    loadStoredCredentials();

    bool connected = false;

    if (storedSsid.length() > 0)
    {
        Serial.print("Connecting with stored WiFi credentials for SSID: ");
        Serial.println(storedSsid);
        connected = connectToWiFi(storedSsid.c_str(), storedPassword.c_str());
    }

    if (!connected && DEFAULT_WIFI_SSID[0] != '\0')
    {
        Serial.println("Falling back to compiled WiFi credentials.");
        connected = connectToWiFi(DEFAULT_WIFI_SSID, DEFAULT_WIFI_PASS);
        if (connected)
        {
            storedSsid = DEFAULT_WIFI_SSID;
            storedPassword = DEFAULT_WIFI_PASS;
            saveCredentials(storedSsid, storedPassword);
        }
    }

    if (connected)
    {
        publishDeviceStatus(WiFi.localIP(), millis(), true);
        setupHttpServer();
    }
    else
    {
        Serial.println("No WiFi connection available. Starting configuration portal...");
        startConfigPortal();
    }
}

void loop()
{
    const unsigned long now = millis();

    // Handle AP mode timeout
    if (apModeActive && (now - apModeStartTime > AP_TIMEOUT_MS))
    {
        Serial.println("AP mode timeout. Restarting...");
        ESP.restart();
    }

    if (!apModeActive)
    {
        maintainWiFiConnection(now);
        publishStatusHeartbeat(now);
        handleMotion(now);
        handleSound(now);
        handleDht(now);
    }

    if (httpServerStarted)
    {
        server.handleClient();
    }

    delay(10);
}

void handleDht(unsigned long now)
{
    if (now - lastDhtSample < DHT_INTERVAL_MS)
    {
        return;
    }
    lastDhtSample = now;

    float humidity = dht.readHumidity();
    float temperature = dht.readTemperature();

    if (isnan(humidity) || isnan(temperature))
    {
        Serial.println("Sensor read error from DHT22.");
        return;
    }

    lastHumidity = humidity;
    lastTemperature = temperature;

    const bool tempOK = (temperature >= TEMP_MIN) && (temperature <= TEMP_MAX);
    const bool humidOK = (humidity >= HUMID_MIN) && (humidity <= HUMID_MAX);

    // Temperature categorization
    String tempCategory;
    if (temperature >= 28.0f)
    {
        tempCategory = "High";
    }
    else if (temperature >= 20.0f)
    {
        tempCategory = "Medium";
    }
    else
    {
        tempCategory = "Cold";
    }

    Serial.printf("Temp: %.2f C (%s) | Humidity: %.2f %%\n", temperature, tempCategory.c_str(), humidity);

    if (tempOK && humidOK)
    {
        Serial.println("Conditions are ideal.");
    }
    else
    {
        Serial.println("Warning: Conditions are outside ideal range.");
        if (!tempOK)
        {
            Serial.println(temperature < TEMP_MIN ? "  -> Temperature is too low." : "  -> Temperature is too high.");
        }
        if (!humidOK)
        {
            Serial.println(humidity < HUMID_MIN ? "  -> Humidity is too low." : "  -> Humidity is too high.");
        }
    }

    publishSensorData(now, temperature, humidity, tempOK, humidOK);
    Serial.println();
}

void handleMotion(unsigned long now)
{
    const bool currentState = digitalRead(PIR_PIN) == HIGH;
    motionState = currentState;

    if (currentState && !lastMotionState)
    {
        Serial.println("Motion detected.");
        if (WiFi.status() == WL_CONNECTED)
        {
            publishMotionEvent(now);
        }
        else
        {
            Serial.println("  -> WiFi not connected, motion event not sent to Firebase.");
        }
    }

    lastMotionState = currentState;
}

void handleSound(unsigned long now)
{
    int sampleSum = 0;
    for (uint8_t i = 0; i < SOUND_SAMPLE_COUNT; ++i)
    {
        sampleSum += analogRead(SOUND_ANALOG);
        delayMicroseconds(150);
    }
    lastSoundLevel = sampleSum / SOUND_SAMPLE_COUNT;

    if (!soundBaselineValid)
    {
        soundBaseline = lastSoundLevel;
        soundBaselineValid = true;
    }
    else
    {
        // Smooth baseline tracking so clap spikes stand out clearly
        soundBaseline = ((soundBaseline * 7) + lastSoundLevel) / 8;
    }

    adaptiveSoundTrigger = constrain(soundBaseline + SOUND_TRIGGER_MARGIN, SOUND_MIN_THRESHOLD, SOUND_THRESHOLD);

    soundAboveThreshold = lastSoundLevel >= adaptiveSoundTrigger;
    lastSoundCategory = determineSoundCategory(lastSoundLevel);
    const char *categoryLabel = soundCategoryLabel(lastSoundCategory);

    digitalWrite(LED_PIN, soundAboveThreshold ? HIGH : LOW);

    const bool shouldLog = (now - lastSoundLog >= SOUND_SNAPSHOT_INTERVAL_MS) ||
                           (lastPublishedSoundLevel < 0) ||
                           (abs(lastSoundLevel - lastPublishedSoundLevel) >= SOUND_LEVEL_CHANGE_DELTA);

    if (shouldLog)
    {
        Serial.printf(
            "Sound level: %d (%s) | baseline %d -> trigger %d%s\n",
            lastSoundLevel,
            categoryLabel,
            soundBaseline,
            adaptiveSoundTrigger,
            soundAboveThreshold ? " [ALERT]" : "");
        lastSoundLog = now;
    }

    if (soundAboveThreshold && !previousSoundAboveThreshold)
    {
        if (WiFi.status() == WL_CONNECTED)
        {
            publishSoundEvent(now, lastSoundLevel);
        }
        else
        {
            Serial.println("  -> WiFi not connected, sound event not sent to Firebase.");
        }
    }

    const bool shouldPublishSnapshot = (now - lastSoundSnapshotPublish >= SOUND_SNAPSHOT_INTERVAL_MS) ||
                                       (lastPublishedSoundLevel < 0) ||
                                       (abs(lastSoundLevel - lastPublishedSoundLevel) >= SOUND_LEVEL_CHANGE_DELTA);

    if (shouldPublishSnapshot)
    {
        if (WiFi.status() == WL_CONNECTED)
        {
            publishSoundSnapshot(now, lastSoundLevel, soundAboveThreshold);
        }
        else
        {
            Serial.println("  -> WiFi not connected, sound snapshot not sent to Firebase.");
        }
        lastSoundSnapshotPublish = now;
        lastPublishedSoundLevel = lastSoundLevel;
    }

    previousSoundAboveThreshold = soundAboveThreshold;
}

SoundCategory determineSoundCategory(int level)
{
    const int trigger = max(adaptiveSoundTrigger, SOUND_MIN_THRESHOLD);
    if (level >= trigger + 350)
    {
        return SoundCategory::Extreme;
    }
    if (level >= trigger + 120)
    {
        return SoundCategory::Loud;
    }
    if (level >= trigger - 40)
    {
        return SoundCategory::Moderate;
    }
    if (level >= trigger - 160)
    {
        return SoundCategory::Quiet;
    }
    return SoundCategory::Silent;
}

const char *soundCategoryLabel(SoundCategory category)
{
    switch (category)
    {
    case SoundCategory::Extreme:
        return "Very loud";
    case SoundCategory::Loud:
        return "Loud";
    case SoundCategory::Moderate:
        return "Moderate";
    case SoundCategory::Quiet:
        return "Quiet";
    case SoundCategory::Silent:
    default:
        return "Silent";
    }
}

bool connectToWiFi(const char *targetSsid, const char *targetPassword, uint8_t maxRetries)
{
    if (!targetSsid || targetSsid[0] == '\0')
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
        Serial.print("\nWiFi connected. IP: ");
        Serial.println(WiFi.localIP());
        return true;
    }

    Serial.println("\nFailed to connect to WiFi.");
    WiFi.disconnect(true);
    delay(200);
    return false;
}

void maintainWiFiConnection(unsigned long now)
{
    if (WiFi.status() == WL_CONNECTED)
    {
        return;
    }

    if (now - lastWiFiReconnectAttempt < WIFI_RECONNECT_INTERVAL_MS)
    {
        return;
    }

    lastWiFiReconnectAttempt = now;
    Serial.println("WiFi disconnected. Attempting reconnect...");

    bool connected = false;

    if (storedSsid.length() > 0)
    {
        connected = connectToWiFi(storedSsid.c_str(), storedPassword.c_str());
    }

    if (!connected && DEFAULT_WIFI_SSID[0] != '\0')
    {
        connected = connectToWiFi(DEFAULT_WIFI_SSID, DEFAULT_WIFI_PASS);
        if (connected)
        {
            storedSsid = DEFAULT_WIFI_SSID;
            storedPassword = DEFAULT_WIFI_PASS;
            saveCredentials(storedSsid, storedPassword);
        }
    }

    if (connected)
    {
        publishDeviceStatus(WiFi.localIP(), millis(), true);
        setupHttpServer();
    }
}

void publishStatusHeartbeat(unsigned long now)
{
    if (WiFi.status() != WL_CONNECTED)
    {
        return;
    }

    if (now - lastStatusPublish < STATUS_UPDATE_INTERVAL_MS)
    {
        return;
    }

    lastStatusPublish = now;
    publishDeviceStatus(WiFi.localIP(), now, true);
}

void loadStoredCredentials()
{
    Preferences prefs;
    if (prefs.begin("wifi", true))
    {
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
    {
        prefs.putString("ssid", ssidValue);
        prefs.putString("pass", passwordValue);
        prefs.end();
    }
}

void publishDeviceStatus(const IPAddress &ip, unsigned long timestamp, bool online)
{
    String payload = "{";
    payload += "\"ip\":\"";
    payload += ip.toString();
    payload += "\",\"online\":";
    payload += online ? "true" : "false";
    payload += ",\"lastSeenMs\":";
    payload += String(timestamp);
    payload += ",\"lastSoundLevel\":";
    payload += String(lastSoundLevel);
    payload += ",\"soundBaseline\":";
    payload += String(soundBaseline);
    payload += ",\"soundTriggerLevel\":";
    payload += String(adaptiveSoundTrigger);
    payload += ",\"motionActive\":";
    payload += motionState ? "true" : "false";
    payload += ",\"soundCategory\":\"";
    payload += soundCategoryLabel(lastSoundCategory);
    payload += "\"";
    if (!isnan(lastTemperature))
    {
        payload += ",\"temperatureC\":";
        payload += String(lastTemperature, 2);
    }
    if (!isnan(lastHumidity))
    {
        payload += ",\"humidityPct\":";
        payload += String(lastHumidity, 2);
    }
    payload += "}";

    if (!firebaseSend(String(firebaseStatusPath), payload, FirebaseMethod::Patch))
    {
        Serial.println("Failed to publish device status to Firebase.");
    }
}

void publishSensorData(unsigned long timestamp, float temperature, float humidity, bool tempOK, bool humidOK)
{
    String payload = "{";
    payload += "\"timestampMs\":";
    payload += String(timestamp);
    payload += ",\"temperatureC\":";
    payload += String(temperature, 2);
    payload += ",\"humidityPct\":";
    payload += String(humidity, 2);
    payload += ",\"temperatureIdeal\":";
    payload += tempOK ? "true" : "false";
    payload += ",\"humidityIdeal\":";
    payload += humidOK ? "true" : "false";
    payload += ",\"motionActive\":";
    payload += motionState ? "true" : "false";
    payload += ",\"soundLevel\":";
    payload += String(lastSoundLevel);
    payload += ",\"soundThresholdExceeded\":";
    payload += soundAboveThreshold ? "true" : "false";
    payload += ",\"soundCategory\":\"";
    payload += soundCategoryLabel(lastSoundCategory);
    payload += "\"";
    payload += ",\"soundBaseline\":";
    payload += String(soundBaseline);
    payload += ",\"soundTriggerLevel\":";
    payload += String(adaptiveSoundTrigger);
    payload += "}";

    if (!firebaseSend(String(firebaseReadingsPath), payload, FirebaseMethod::Post))
    {
        Serial.println("Failed to publish sensor data to Firebase.");
    }
}

void publishMotionEvent(unsigned long timestamp)
{
    String payload = "{";
    payload += "\"timestampMs\":";
    payload += String(timestamp);
    payload += ",\"type\":\"motion\"";
    if (!isnan(lastTemperature))
    {
        payload += ",\"temperatureC\":";
        payload += String(lastTemperature, 2);
    }
    if (!isnan(lastHumidity))
    {
        payload += ",\"humidityPct\":";
        payload += String(lastHumidity, 2);
    }
    payload += "}";

    Serial.println("Sending motion event to Firebase...");
    if (firebaseSend(String(firebaseReadingsPath), payload, FirebaseMethod::Post))
    {
        Serial.println("  -> Motion event successfully sent to Firebase.");
    }
    else
    {
        Serial.println("  -> Failed to publish motion event to Firebase.");
    }
}

void publishSoundSnapshot(unsigned long timestamp, int level, bool thresholdExceeded)
{
    String payload = "{";
    payload += "\"timestampMs\":";
    payload += String(timestamp);
    payload += ",\"type\":\"soundSnapshot\"";
    payload += ",\"soundLevel\":";
    payload += String(level);
    payload += ",\"soundThresholdExceeded\":";
    payload += thresholdExceeded ? "true" : "false";
    payload += ",\"soundCategory\":\"";
    payload += soundCategoryLabel(lastSoundCategory);
    payload += "\"";
    payload += ",\"soundBaseline\":";
    payload += String(soundBaseline);
    payload += ",\"soundTriggerLevel\":";
    payload += String(adaptiveSoundTrigger);
    payload += ",\"motionActive\":";
    payload += motionState ? "true" : "false";
    if (!isnan(lastTemperature))
    {
        payload += ",\"temperatureC\":";
        payload += String(lastTemperature, 2);
    }
    if (!isnan(lastHumidity))
    {
        payload += ",\"humidityPct\":";
        payload += String(lastHumidity, 2);
    }
    payload += "}";

    Serial.println("Publishing sound snapshot to Firebase...");
    if (firebaseSend(String(firebaseReadingsPath), payload, FirebaseMethod::Post))
    {
        Serial.println("  -> Sound snapshot successfully sent to Firebase.");
    }
    else
    {
        Serial.println("  -> Failed to publish sound snapshot to Firebase.");
    }
}

void publishSoundEvent(unsigned long timestamp, int level)
{
    String payload = "{";
    payload += "\"timestampMs\":";
    payload += String(timestamp);
    payload += ",\"type\":\"sound\"";
    payload += ",\"soundLevel\":";
    payload += String(level);
    payload += ",\"soundCategory\":\"";
    payload += soundCategoryLabel(lastSoundCategory);
    payload += "\"";
    payload += ",\"soundBaseline\":";
    payload += String(soundBaseline);
    payload += ",\"soundTriggerLevel\":";
    payload += String(adaptiveSoundTrigger);
    if (!isnan(lastTemperature))
    {
        payload += ",\"temperatureC\":";
        payload += String(lastTemperature, 2);
    }
    if (!isnan(lastHumidity))
    {
        payload += ",\"humidityPct\":";
        payload += String(lastHumidity, 2);
    }
    payload += "}";

    Serial.println("Sending sound event to Firebase...");
    if (firebaseSend(String(firebaseReadingsPath), payload, FirebaseMethod::Post))
    {
        Serial.println("  -> Sound event successfully sent to Firebase.");
    }
    else
    {
        Serial.println("  -> Failed to publish sound event to Firebase.");
    }
}

void setupHttpServer()
{
    if (httpServerStarted)
    {
        return;
    }

    server.on("/", handleStatusPage);
    server.on("/status.json", handleStatusJson);
    server.begin();
    httpServerStarted = true;
    Serial.println("HTTP status server started on port 80.");
}

String buildStatusJson()
{
    String json = "{";
    json += "\"ip\":\"";
    json += WiFi.localIP().toString();
    json += "\",\"online\":";
    json += WiFi.status() == WL_CONNECTED ? "true" : "false";
    json += ",\"lastSeenMs\":";
    json += String(millis());
    json += ",\"lastSoundLevel\":";
    json += String(lastSoundLevel);
    json += ",\"soundThresholdExceeded\":";
    json += soundAboveThreshold ? "true" : "false";
    json += ",\"motionActive\":";
    json += motionState ? "true" : "false";
    if (!isnan(lastTemperature))
    {
        json += ",\"temperatureC\":";
        json += String(lastTemperature, 2);
    }
    if (!isnan(lastHumidity))
    {
        json += ",\"humidityPct\":";
        json += String(lastHumidity, 2);
    }
    json += "}";
    return json;
}

void handleStatusPage()
{
    String html = "<!DOCTYPE html><html><head><meta charset='utf-8'><title>Baby Monitor Status</title>";
    html += "<style>body{font-family:Arial,Helvetica,sans-serif;margin:16px;background:#f4f4f4;color:#202020;}";
    html += "h1{margin-bottom:0;}small{color:#606060;}section{margin-top:18px;}";
    html += "pre{background:#111;color:#0f0;padding:16px;border-radius:6px;overflow:auto;}";
    html += "button{padding:6px 12px;border:0;border-radius:4px;background:#0069d9;color:#fff;cursor:pointer;}";
    html += "button:hover{background:#0052af;}";
    html += "</style></head><body><h1>Baby Monitor Status</h1><small>Auto-refresh every 2&nbsp;s</small>";
    html += "<section><pre id='payload'>{\"status\":\"loading\"}</pre>";
    html += "<button onclick='refresh()'>Refresh now</button></section>";
    html += "<script>async function refresh(){try{const r=await fetch('/status.json',{cache:'no-store'});";
    html += "const data=await r.json();document.getElementById('payload').textContent=JSON.stringify(data,null,2);}";
    html += "catch(e){document.getElementById('payload').textContent='{\\\"error\\\":\\\"'+e+'\\\"}';}}";
    html += "refresh();setInterval(refresh,2000);</script></body></html>";
    server.send(200, "text/html", html);
}

void handleStatusJson()
{
    server.send(200, "application/json", buildStatusJson());
}

void startConfigPortal()
{
    Serial.println("Starting WiFi configuration portal...");

    WiFi.mode(WIFI_AP);
    WiFi.softAP(AP_SSID, AP_PASSWORD);

    IPAddress apIP = WiFi.softAPIP();
    Serial.print("AP started. SSID: ");
    Serial.println(AP_SSID);
    Serial.print("Password: ");
    Serial.println(AP_PASSWORD);
    Serial.print("IP Address: ");
    Serial.println(apIP);
    Serial.println("Connect to this network and navigate to http://192.168.4.1");

    apModeActive = true;
    apModeStartTime = millis();

    setupConfigPortal();
}

void setupConfigPortal()
{
    server.on("/", handleConfigPage);
    server.on("/scan", handleWifiScan);
    server.on("/save", HTTP_POST, handleWifiSave);
    server.begin();
    httpServerStarted = true;
    Serial.println("Configuration portal web server started.");
}

void handleConfigPage()
{
    String html = "<!DOCTYPE html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>";
    html += "<title>Baby Monitor WiFi Setup</title>";
    html += "<style>body{font-family:Arial,sans-serif;margin:0;padding:20px;background:#f0f0f0;}";
    html += ".container{max-width:500px;margin:0 auto;background:white;padding:30px;border-radius:10px;box-shadow:0 2px 10px rgba(0,0,0,0.1);}";
    html += "h1{color:#333;margin-top:0;}input,select{width:100%;padding:10px;margin:8px 0;border:1px solid #ddd;border-radius:4px;box-sizing:border-box;}";
    html += "button{width:100%;padding:12px;margin:10px 0;border:0;border-radius:4px;background:#007bff;color:white;font-size:16px;cursor:pointer;}";
    html += "button:hover{background:#0056b3;}button.scan{background:#28a745;}button.scan:hover{background:#218838;}";
    html += ".info{background:#e7f3ff;padding:10px;border-radius:4px;margin-bottom:20px;color:#004085;}";
    html += "#networks{margin:10px 0;}#networks div{padding:10px;background:#f8f9fa;margin:5px 0;border-radius:4px;cursor:pointer;}";
    html += "#networks div:hover{background:#e9ecef;}</style></head><body><div class='container'>";
    html += "<h1>🍼 Baby Monitor WiFi Setup</h1>";
    html += "<div class='info'>Connect your Baby Monitor to your WiFi network</div>";
    html += "<button class='scan' onclick='scanNetworks()'>Scan for Networks</button>";
    html += "<div id='networks'></div>";
    html += "<form action='/save' method='POST'>";
    html += "<label>WiFi SSID:</label><input type='text' name='ssid' id='ssid' required placeholder='Enter WiFi name'>";
    html += "<label>Password:</label><input type='password' name='password' placeholder='Enter WiFi password'>";
    html += "<button type='submit'>Save & Connect</button></form>";
    html += "<script>function scanNetworks(){fetch('/scan').then(r=>r.json()).then(data=>{";
    html += "let html='';data.networks.forEach(n=>{html+=`<div onclick=\"document.getElementById('ssid').value='${n.ssid}'\">`+";
    html += "`${n.ssid} (${n.rssi} dBm) ${n.secure?'🔒':''}</div>`;});document.getElementById('networks').innerHTML=html;});}";
    html += "</script></div></body></html>";
    server.send(200, "text/html", html);
}

void handleWifiScan()
{
    Serial.println("Scanning for WiFi networks...");
    int n = WiFi.scanNetworks();
    String json = "{\"networks\":[";

    for (int i = 0; i < n; i++)
    {
        if (i > 0)
            json += ",";
        json += "{";
        json += "\"ssid\":\"" + WiFi.SSID(i) + "\"";
        json += ",\"rssi\":" + String(WiFi.RSSI(i));
        json += ",\"secure\":" + String(WiFi.encryptionType(i) != WIFI_AUTH_OPEN ? "true" : "false");
        json += "}";
    }

    json += "]}";
    server.send(200, "application/json", json);
    Serial.printf("Found %d networks\n", n);
}

void handleWifiSave()
{
    String ssid = server.arg("ssid");
    String password = server.arg("password");

    Serial.print("Received WiFi credentials. SSID: ");
    Serial.println(ssid);

    // Save credentials
    saveCredentials(ssid, password);

    String html = "<!DOCTYPE html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>";
    html += "<title>WiFi Saved</title><style>body{font-family:Arial,sans-serif;margin:0;padding:20px;background:#f0f0f0;}";
    html += ".container{max-width:500px;margin:0 auto;background:white;padding:30px;border-radius:10px;box-shadow:0 2px 10px rgba(0,0,0,0.1);text-align:center;}";
    html += "h1{color:#28a745;}</style></head><body><div class='container'><h1>✓ WiFi Credentials Saved!</h1>";
    html += "<p>The device will restart and connect to <strong>" + ssid + "</strong></p>";
    html += "<p>This page will close automatically...</p></div>";
    html += "<script>setTimeout(()=>{window.close();},3000);</script></body></html>";

    server.send(200, "text/html", html);

    delay(2000);
    Serial.println("Restarting to connect to new WiFi...");
    ESP.restart();
}

bool firebaseSend(const String &path, const String &payload, FirebaseMethod method)
{
    if (!firebaseHost || firebaseHost[0] == '\0' || !firebaseAuth || firebaseAuth[0] == '\0')
    {
        return false;
    }

    if (WiFi.status() != WL_CONNECTED)
    {
        return false;
    }

    WiFiClientSecure client;
    client.setInsecure();

    HTTPClient http;
    String url = String(firebaseHost) + path + ".json?auth=" + firebaseAuth;

    if (!http.begin(client, url))
    {
        Serial.println("Unable to initialise HTTP client for Firebase.");
        return false;
    }

    http.addHeader("Content-Type", "application/json");

    int httpCode = 0;
    switch (method)
    {
    case FirebaseMethod::Post:
        httpCode = http.POST(payload);
        break;
    case FirebaseMethod::Patch:
        httpCode = http.PATCH(payload);
        break;
    case FirebaseMethod::Put:
        httpCode = http.PUT(payload);
        break;
    }

    if (httpCode < 0)
    {
        String error = http.errorToString(httpCode);
        Serial.printf("Firebase request failed: %s\n", error.c_str());
        http.end();
        return false;
    }

    if (httpCode >= 400)
    {
        Serial.printf("Firebase HTTP error: %d\n", httpCode);
        String response = http.getString();
        if (response.length() > 0)
        {
            Serial.printf("Response: %s\n", response.c_str());
        }
        http.end();
        return false;
    }

    // Success - log the response for debugging
    if (httpCode == 200)
    {
        String response = http.getString();
        Serial.printf("Firebase response (HTTP %d): %s\n", httpCode, response.c_str());
    }

    http.end();
    return true;
}
