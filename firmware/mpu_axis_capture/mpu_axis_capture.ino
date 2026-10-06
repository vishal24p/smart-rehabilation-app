#include <Arduino.h>
#include <Wire.h>
#include <WiFi.h>

// =====================================================
// WIFI
// =====================================================

const char* WIFI_NAME = "REHAB-WEARABLE";
const char* WIFI_PASSWORD = "rehab1234";

WiFiServer server(5000);

// =====================================================
// PINS
// =====================================================

#define SDA_PIN 21
#define SCL_PIN 22

#define FSR_LEFT_PIN 34
#define FSR_RIGHT_PIN 35

// =====================================================
// THIGH IMU
// =====================================================

// AD0 -> 3V3
#define THIGH_ADDRESS 0x69

// 50 Hz
#define SAMPLE_PERIOD_US 20000

unsigned long lastSampleUs = 0;

// =====================================================
// IMU DATA
// =====================================================

struct IMUData {
  int16_t ax;
  int16_t ay;
  int16_t az;

  int16_t gx;
  int16_t gy;
  int16_t gz;
};

// =====================================================
// WRITE REGISTER
// =====================================================

bool writeRegister(
  uint8_t address,
  uint8_t reg,
  uint8_t value
) {
  Wire.beginTransmission(address);

  Wire.write(reg);
  Wire.write(value);

  return Wire.endTransmission() == 0;
}

// =====================================================
// READ REGISTERS
// =====================================================

bool readRegisters(
  uint8_t address,
  uint8_t reg,
  uint8_t* data,
  uint8_t count
) {
  Wire.beginTransmission(address);

  Wire.write(reg);

  if (Wire.endTransmission(false) != 0) {
    return false;
  }

  int received = Wire.requestFrom(
    (int)address,
    (int)count,
    (int)true
  );

  if (received != count) {
    return false;
  }

  for (uint8_t i = 0; i < count; i++) {
    data[i] = Wire.read();
  }

  return true;
}

// =====================================================
// INITIALIZE THIGH IMU
// =====================================================

bool initializeThigh() {

  uint8_t who = 0;

  if (!readRegisters(
        THIGH_ADDRESS,
        0x75,
        &who,
        1
      )) {

    return false;
  }

  Serial.print("THIGH WHO_AM_I = 0x");
  Serial.println(who, HEX);

  if (who != 0x68 && who != 0x70) {
    return false;
  }

  // Reset
  if (!writeRegister(
        THIGH_ADDRESS,
        0x6B,
        0x80
      )) {

    return false;
  }

  delay(200);

  // Wake
  if (!writeRegister(
        THIGH_ADDRESS,
        0x6B,
        0x01
      )) {

    return false;
  }

  // Enable axes
  writeRegister(
    THIGH_ADDRESS,
    0x6C,
    0x00
  );

  // Low pass filter
  writeRegister(
    THIGH_ADDRESS,
    0x1A,
    0x03
  );

  // Gyro ±250 dps
  writeRegister(
    THIGH_ADDRESS,
    0x1B,
    0x00
  );

  // Accel ±2g
  writeRegister(
    THIGH_ADDRESS,
    0x1C,
    0x00
  );

  delay(100);

  return true;
}

// =====================================================
// READ THIGH
// =====================================================

bool readThigh(IMUData &imu) {

  uint8_t data[14];

  if (!readRegisters(
        THIGH_ADDRESS,
        0x3B,
        data,
        14
      )) {

    return false;
  }

  imu.ax =
    (int16_t)(
      (uint16_t(data[0]) << 8) |
      data[1]
    );

  imu.ay =
    (int16_t)(
      (uint16_t(data[2]) << 8) |
      data[3]
    );

  imu.az =
    (int16_t)(
      (uint16_t(data[4]) << 8) |
      data[5]
    );

  // Skip temperature data[6], data[7]

  imu.gx =
    (int16_t)(
      (uint16_t(data[8]) << 8) |
      data[9]
    );

  imu.gy =
    (int16_t)(
      (uint16_t(data[10]) << 8) |
      data[11]
    );

  imu.gz =
    (int16_t)(
      (uint16_t(data[12]) << 8) |
      data[13]
    );

  return true;
}

// =====================================================
// SETUP
// =====================================================

void setup() {

  Serial.begin(115200);

  delay(1500);

  // I2C
  Wire.begin(
    SDA_PIN,
    SCL_PIN
  );

  Wire.setClock(100000);
  Wire.setTimeOut(50);

  // Thigh sensor
  if (initializeThigh()) {

    Serial.println(
      "THIGH IMU READY"
    );

  } else {

    Serial.println(
      "ERROR: THIGH IMU NOT FOUND"
    );
  }

  // FSR
  analogReadResolution(12);

  pinMode(
    FSR_LEFT_PIN,
    INPUT
  );

  pinMode(
    FSR_RIGHT_PIN,
    INPUT
  );

  // WiFi
  WiFi.mode(WIFI_AP);

  WiFi.softAP(
    WIFI_NAME,
    WIFI_PASSWORD
  );

  delay(500);

  Serial.println();

  Serial.print("WiFi: ");
  Serial.println(WIFI_NAME);

  Serial.print("Password: ");
  Serial.println(WIFI_PASSWORD);

  Serial.print("IP: ");
  Serial.println(
    WiFi.softAPIP()
  );

  // TCP server
  server.begin();

  Serial.println(
    "TCP PORT: 5000"
  );

  Serial.println(
    "Waiting for Python..."
  );
}

// =====================================================
// LOOP
// =====================================================

void loop() {

  WiFiClient client =
    server.available();

  if (!client) {

    delay(20);

    return;
  }

  Serial.println(
    "PYTHON CONNECTED"
  );

  // CSV HEADER
  client.println(
    "time_us,"
    "thigh_ax,thigh_ay,thigh_az,"
    "thigh_gx,thigh_gy,thigh_gz,"
    "fsr_left,fsr_right"
  );

  lastSampleUs =
    micros();

  while (client.connected()) {

    unsigned long now =
      micros();

    if (
      now - lastSampleUs
      < SAMPLE_PERIOD_US
    ) {

      delay(1);

      continue;
    }

    lastSampleUs = now;

    IMUData thigh;

    bool thighOK =
      readThigh(thigh);

    int fsrLeft =
      analogRead(FSR_LEFT_PIN);

    int fsrRight =
      analogRead(FSR_RIGHT_PIN);

    // ===============================================
    // SEND DATA
    // ===============================================

    client.print(now);
    client.print(",");

    if (thighOK) {

      client.print(thigh.ax);
      client.print(",");

      client.print(thigh.ay);
      client.print(",");

      client.print(thigh.az);
      client.print(",");

      client.print(thigh.gx);
      client.print(",");

      client.print(thigh.gy);
      client.print(",");

      client.print(thigh.gz);

    } else {

      client.print(
        "0,0,0,0,0,0"
      );
    }

    client.print(",");

    client.print(
      fsrLeft
    );

    client.print(",");

    client.println(
      fsrRight
    );
  }

  client.stop();

  Serial.println(
    "PYTHON DISCONNECTED"
  );
}