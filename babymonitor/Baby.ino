#include <DHT.h>
#include <WiFi.h>
#include <Preferences.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <math.h>
#include <WebServer.h>

// Pin assignments and sensor configuration
#define DHTPIN 13
#define DHTTYPE DHT22
const int PIR_PIN = 14;
const int SOUND_ANALOG = 34;
const int LED_PIN = 2;

// Sound detection tuning
const int SOUND_THRESHOLD = 800;

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

DHT dht(DHTPIN, DHTTYPE);

bool lastMotionState = false;
bool motionState = false;
bool soundAboveThreshold = false;
bool previousSoundAboveThreshold = false;
int lastSoundLevel = 0;
float lastTemperature = NAN;
float lastHumidity = NAN;
unsigned long lastDhtSample = 0;
unsigned long lastWiFiReconnectAttempt = 0;
unsigned long lastStatusPublish = 0;
String storedSsid;
String storedPassword;
WebServer server(80);
bool httpServerStarted = false;

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
bool firebaseSend(const String &path, const String &payload, FirebaseMethod method);
void setupHttpServer();
String buildStatusJson();
void handleStatusPage();
void handleStatusJson();

void setup()
{
    Serial.begin(115200);
    dht.begin();

    pinMode(PIR_PIN, INPUT);
    pinMode(LED_PIN, OUTPUT);

    Serial.println("Integrated Environment Monitor ready.");
    Serial.println("DHT22 on GPIO 13 | PIR on GPIO 14 | Sound sensor on GPIO 34");
    Serial.println("Ideal range: Temp 22-28 C | Humidity 40-60 %");

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
        Serial.println("WiFi connection not available. Firebase updates will resume after reconnect.");
    }
}

void loop()
{
    const unsigned long now = millis();

    maintainWiFiConnection(now);
    publishStatusHeartbeat(now);
    handleMotion(now);
    handleSound(now);
    handleDht(now);

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

    Serial.printf("Temp: %.2f C | Humidity: %.2f %%\n", temperature, humidity);

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
        publishMotionEvent(now);
    }

    lastMotionState = currentState;
}

void handleSound(unsigned long now)
{
    lastSoundLevel = analogRead(SOUND_ANALOG);
    soundAboveThreshold = lastSoundLevel > SOUND_THRESHOLD;

    if (soundAboveThreshold)
    {
        Serial.println("Sound detected.");
        digitalWrite(LED_PIN, HIGH);
    }
    else
    {
        digitalWrite(LED_PIN, LOW);
    }

    if (soundAboveThreshold && !previousSoundAboveThreshold)
    {
        publishSoundEvent(now, lastSoundLevel);
    }

    previousSoundAboveThreshold = soundAboveThreshold;
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

    if (!firebaseSend(String(firebaseEventsPath), payload, FirebaseMethod::Post))
    {
        Serial.println("Failed to publish motion event to Firebase.");
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

    if (!firebaseSend(String(firebaseEventsPath), payload, FirebaseMethod::Post))
    {
        Serial.println("Failed to publish sound event to Firebase.");
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
        Serial.printf("Firebase HTTP %d\n", httpCode);
        http.end();
        return false;
    }

    http.end();
    return true;
}
