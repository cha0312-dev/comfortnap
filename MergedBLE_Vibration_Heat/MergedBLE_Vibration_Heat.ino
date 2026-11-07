#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <OneWire.h>
#include <DallasTemperature.h>

// ======================================================
// BLE
// ======================================================
#define SERVICE_UUID        "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHARACTERISTIC_TX   "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHARACTERISTIC_RX   "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"

BLECharacteristic *txCharacteristic;
BLECharacteristic *rxCharacteristic;
volatile bool deviceConnected = false;

// ======================================================
// PIN CONFIGURATION
// ======================================================
const int MOTOR_PIN_1   = 25;   // Vibration motor
const int MOTOR_PIN_2   = 26;   // Vibration motor
const int RPWM_PIN      = 14;   // BTS7960 RPWM (heater)
const int DS18B20_PIN   = 32;   // Temperature sensor

// ======================================================
// PWM CONFIGURATION (ESP32 Arduino core 2.x API)
// ======================================================
const int PWM_FREQ        = 5000;
const int PWM_RESOLUTION  = 8;

const int MOTOR_CHANNEL_1 = 0;
const int MOTOR_CHANNEL_2 = 1;
const int HEATER_CHANNEL  = 2;  // separate channel so it doesn't clash with the motor

// ======================================================
// MOTOR STATE
// ======================================================
volatile bool motorEnabled = false;
volatile int  motorLevel   = 150;   // 0-255

// ======================================================
// HEATER / TEMPERATURE
// ======================================================
OneWire oneWire(DS18B20_PIN);
DallasTemperature sensors(&oneWire);

const float TARGET_25  = 35.0;
const float TARGET_50  = 40.0;
const float TARGET_75  = 45.0;
const float TARGET_100 = 50.0;

const float SAFETY_MAX_TEMP = 55.0;
const float SAFETY_RECOVERY_TEMP = 45.0;
const int SAFE_READINGS_TO_RECOVER = 3;
bool heaterFaultActive = false;
const char *heaterFaultCode = nullptr;
int consecutiveSafeReadings = 0;

// DEFAULT = 0 (heater OFF until the phone sends a value)
int heatLevel  = 0;
int currentPWM = 0;

// Level requested by the phone (-1 = nothing pending).
// Written in the BLE callback, applied in loop().
volatile int pendingHeatLevel = -1;

// Non-blocking temperature reading
const unsigned long TEMP_INTERVAL      = 1000;  // request every 1 s
const unsigned long TEMP_CONVERSION_MS = 800;   // DS18B20 12-bit needs ~750 ms
unsigned long lastTempRequest = 0;
bool tempRequested = false;

// ======================================================
// HEATER FUNCTIONS
// ======================================================
float getTargetTemperature(int level) {
  switch (level) {
    case 25:  return TARGET_25;
    case 50:  return TARGET_50;
    case 75:  return TARGET_75;
    case 100: return TARGET_100;
    default:  return 0.0;
  }
}

void heaterOff() {
  currentPWM = 0;
  ledcWrite(HEATER_CHANNEL, 0);
}

void sendHeaterSafetyFaultBLE(const char *fault);

void setHeatLevel(int level) {
  if (level != 0 && level != 25 && level != 50 &&
      level != 75 && level != 100) {
    Serial.println("Invalid heat level. Use: 0, 25, 50, 75, or 100");
    return;
  }

  if (level != 0 && heaterFaultActive) {
    Serial.println("Heating disabled until temperature sensor readings are safe.");
    sendHeaterSafetyFaultBLE(
      heaterFaultCode == nullptr ? "SAFETY_ACTIVE" : heaterFaultCode
    );
    heaterOff();
    return;
  }

  heatLevel = level;

  Serial.println();
  Serial.println("==============================");
  Serial.print("Heat Level: ");
  Serial.print(heatLevel);
  Serial.println("%");

  if (heatLevel == 0) {
    Serial.println("Heating: OFF");
    heaterOff();
  } else {
    Serial.print("Target Temperature: ");
    Serial.print(getTargetTemperature(heatLevel));
    Serial.println(" C");
  }
  Serial.println("==============================");
}

void sendTemperatureBLE(float temperature) {
  if (!deviceConnected || txCharacteristic == nullptr) {
    return;
  }

  String payload = "TEMP:" + String(temperature, 2);
  txCharacteristic->setValue(payload.c_str());
  txCharacteristic->notify();
}

void sendHeaterSafetyFaultBLE(const char *fault) {
  if (!deviceConnected || txCharacteristic == nullptr) {
    return;
  }

  String payload = "SAFETY:" + String(fault);
  txCharacteristic->setValue(payload.c_str());
  txCharacteristic->notify();
}

void controlHeating(float temperature) {
  if (heatLevel == 0 || heaterFaultActive) {
    heaterOff();
    return;
  }

  float target = getTargetTemperature(heatLevel);

  // Absolute safety limit
  if (temperature >= SAFETY_MAX_TEMP) {
    if (!heaterFaultActive) {
      heaterFaultActive = true;
      heaterFaultCode = "OVER_TEMPERATURE";
      consecutiveSafeReadings = 0;
      heatLevel = 0;
      sendHeaterSafetyFaultBLE("OVER_TEMPERATURE");
      Serial.println("!!! OVER-TEMPERATURE CUTOFF: WAITING FOR SAFE READINGS !!!");
    }
    heaterOff();
    return;
  }

  float error = target - temperature;

  if (error <= 0.0)       currentPWM = 0;
  else if (error < 0.5)   currentPWM = 180;
  else if (error < 1.0)   currentPWM = 200;
  else if (error < 2.0)   currentPWM = 225;
  else if (error < 3.0)   currentPWM = 250;
  else if (error < 5.0)   currentPWM = 255;
  else                    currentPWM = 220;

  currentPWM = constrain(currentPWM, 0, 255);
  ledcWrite(HEATER_CHANNEL, currentPWM);
}

// ======================================================
// BLE CALLBACKS
// ======================================================
class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) {
    deviceConnected = true;
  }

  void onDisconnect(BLEServer* pServer) {
    deviceConnected = false;
    motorEnabled = false;
    ledcWrite(MOTOR_CHANNEL_1, 0);
    ledcWrite(MOTOR_CHANNEL_2, 0);
    heaterOff();

    // Queue the state update for the main loop as well.
    pendingHeatLevel = 0;

    BLEDevice::startAdvertising();
  }
};

class RXCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *pChar) {

    String rxValue = pChar->getValue().c_str();
    rxValue.trim();
    if (rxValue.length() == 0) return;

    Serial.println("RX: " + rxValue);

    // ---------- MOTOR ----------
    if (rxValue == "ON") {
      motorEnabled = true;
    }

    else if (rxValue == "OFF") {
      motorEnabled = false;
      heaterOff();
      pendingHeatLevel = 0;

      ledcWrite(MOTOR_CHANNEL_1, 0);
      ledcWrite(MOTOR_CHANNEL_2, 0);
    }

    else if (rxValue.startsWith("VIB:")) {
      int level = rxValue.substring(4).toInt();
      level = constrain(level, 0, 100);
      motorLevel = map(level, 0, 100, 0, 255);
    }

    // ---------- HEATER ----------
    // Format: HEAT:0 | HEAT:25 | HEAT:50 | HEAT:75 | HEAT:100
    else if (rxValue.startsWith("HEAT:")) {
      pendingHeatLevel = rxValue.substring(5).toInt();
    }
  }
};

// ======================================================
// SERIAL COMMAND (optional, for testing without the phone)
// Type: HEAT:50   (or just the number, e.g. 50)
// ======================================================
void readSerialCommand() {
  if (Serial.available()) {
    String command = Serial.readStringUntil('\n');
    command.trim();
    if (command.length() == 0) return;

    if (command.startsWith("HEAT:")) command = command.substring(5);
    setHeatLevel(command.toInt());
  }
}

// ======================================================
// SETUP
// ======================================================
void setup() {
  Serial.begin(115200);
  delay(500);

  // ----- Motor PWM -----
  pinMode(MOTOR_PIN_1, OUTPUT);
  pinMode(MOTOR_PIN_2, OUTPUT);

  ledcSetup(MOTOR_CHANNEL_1, PWM_FREQ, PWM_RESOLUTION);
  ledcAttachPin(MOTOR_PIN_1, MOTOR_CHANNEL_1);

  ledcSetup(MOTOR_CHANNEL_2, PWM_FREQ, PWM_RESOLUTION);
  ledcAttachPin(MOTOR_PIN_2, MOTOR_CHANNEL_2);

  ledcWrite(MOTOR_CHANNEL_1, 0);
  ledcWrite(MOTOR_CHANNEL_2, 0);

  // ----- Heater PWM -----
  ledcSetup(HEATER_CHANNEL, PWM_FREQ, PWM_RESOLUTION);
  ledcAttachPin(RPWM_PIN, HEATER_CHANNEL);
  ledcWrite(HEATER_CHANNEL, 0);

  // ----- DS18B20 (non-blocking) -----
  sensors.begin();
  sensors.setWaitForConversion(false);

  Serial.print("DS18B20 devices: ");
  Serial.println(sensors.getDeviceCount());

  // ----- BLE -----
  BLEDevice::init("ESP32_BLE");

  BLEServer *server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());

  BLEService *service = server->createService(SERVICE_UUID);

  txCharacteristic = service->createCharacteristic(
    CHARACTERISTIC_TX,
    BLECharacteristic::PROPERTY_NOTIFY
  );
  txCharacteristic->addDescriptor(new BLE2902());

  rxCharacteristic = service->createCharacteristic(
    CHARACTERISTIC_RX,
    BLECharacteristic::PROPERTY_WRITE
  );
  rxCharacteristic->setCallbacks(new RXCallbacks());

  service->start();
  BLEDevice::startAdvertising();

  // Heater starts OFF (heatLevel = 0) until the phone sends HEAT:<level>
  setHeatLevel(0);

  Serial.println();
  Serial.println("BLE commands:");
  Serial.println("ON / OFF        = vibration motor");
  Serial.println("VIB:0-100       = vibration intensity");
  Serial.println("HEAT:0/25/50/75/100 = heater level");
  Serial.println("READY");
}

// ======================================================
// LOOP
// ======================================================
void loop() {

  // ---------- Apply heat level requested by phone ----------
  if (pendingHeatLevel != -1) {
    int level = pendingHeatLevel;
    pendingHeatLevel = -1;
    setHeatLevel(level);
  }

  readSerialCommand();

  // ---------- MOTOR CONTROL ----------
  if (motorEnabled) {
    ledcWrite(MOTOR_CHANNEL_1, motorLevel);
    ledcWrite(MOTOR_CHANNEL_2, motorLevel);
  } else {
    ledcWrite(MOTOR_CHANNEL_1, 0);
    ledcWrite(MOTOR_CHANNEL_2, 0);
  }

  // ---------- TEMPERATURE: request ----------
  if (!tempRequested && millis() - lastTempRequest >= TEMP_INTERVAL) {
    lastTempRequest = millis();
    sensors.requestTemperatures();
    tempRequested = true;
  }

  // ---------- TEMPERATURE: read result + control ----------
  if (tempRequested && millis() - lastTempRequest >= TEMP_CONVERSION_MS) {
    tempRequested = false;

    float temperature = sensors.getTempCByIndex(0);

    // Sensor error -> heater OFF
    if (temperature == DEVICE_DISCONNECTED_C ||
        temperature < -50.0 ||
        temperature > 100.0) {

      Serial.println();
      Serial.println("!!! DS18B20 ERROR !!!");
      if (!heaterFaultActive) {
        heaterFaultActive = true;
        heaterFaultCode = "SENSOR_ERROR";
        consecutiveSafeReadings = 0;
        heatLevel = 0;
        sendHeaterSafetyFaultBLE("SENSOR_ERROR");
        Serial.println("!!! SENSOR FAULT CUTOFF: WAITING FOR VALID READINGS !!!");
      }
      heaterOff();
      return;
    }

    if (heaterFaultActive) {
      if (temperature <= SAFETY_RECOVERY_TEMP) {
        consecutiveSafeReadings++;
      } else {
        consecutiveSafeReadings = 0;
      }

      if (consecutiveSafeReadings >= SAFE_READINGS_TO_RECOVER) {
        heaterFaultActive = false;
        heaterFaultCode = nullptr;
        consecutiveSafeReadings = 0;
        sendHeaterSafetyFaultBLE("CLEARED");
        Serial.println("Heater safety fault cleared; heater remains OFF.");
      }
    }

    sendTemperatureBLE(temperature);
    controlHeating(temperature);

    // Serial monitor status
    Serial.print("Level: ");
    Serial.print(heatLevel);
    Serial.print("%");

    Serial.print(" | Target: ");
    if (heatLevel == 0) {
      Serial.print("OFF");
    } else {
      Serial.print(getTargetTemperature(heatLevel), 1);
      Serial.print(" C");
    }

    Serial.print(" | Actual: ");
    Serial.print(temperature, 2);
    Serial.print(" C");

    Serial.print(" | PWM: ");
    Serial.print(currentPWM);
    Serial.print(" / 255");

    Serial.print(" | PWM %: ");
    Serial.print((currentPWM / 255.0) * 100.0, 1);
    Serial.println("%");
  }
}
