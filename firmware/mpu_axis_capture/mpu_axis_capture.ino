#include <Arduino.h>
#include <Wire.h>
#include <ESP8266WiFi.h>

// Wi-Fi
const char* WIFI_NAME = "REHAB-WEARABLE";
const char* WIFI_PASSWORD = "rehab1234";

WiFiServer server(5000);

// I2C
#define SDA_PIN 4  // D2
#define SCL_PIN 5  // D1

#define THIGH_ADDRESS 0x69
#define SHIN_ADDRESS  0x68

// FSR
#define LEFT_FSR_PIN  14  // D5
#define RIGHT_FSR_PIN 12  // D6
#define FSR_ANALOG A0

// 50 Hz
#define SAMPLE_PERIOD_MS 20

struct IMUData {
  int16_t ax;
  int16_t ay;
  int16_t az;
  int16_t gx;
  int16_t gy;
  int16_t gz;
};

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

  uint8_t received = Wire.requestFrom(address, count);

  if (received != count) {
    return false;
  }

  for (uint8_t i = 0; i < count; i++) {
    data[i] = Wire.read();
  }

  return true;
}

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

bool initializeMPU(uint8_t address) {
  uint8_t who = 0;

  if (!readRegisters(address, 0x75, &who, 1)) {
    return false;
  }

  if (who != 0x68 && who != 0x70) {
    return false;
  }

  // Reset MPU
  if (!writeRegister(address, 0x6B, 0x80)) {
    return false;
  }

  delay(100);

  // Wake MPU
  if (!writeRegister(address, 0x6B, 0x01)) {
    return false;
  }

  // Enable axes
  writeRegister(address, 0x6C, 0x00);

  // Low-pass filter
  writeRegister(address, 0x1A, 0x03);

  // Gyroscope: +/-250 degrees per second
  writeRegister(address, 0x1B, 0x00);

  // Accelerometer: +/-2g
  writeRegister(address, 0x1C, 0x00);

  delay(50);

  return true;
}

bool readMPU(uint8_t address, IMUData &imu) {
  uint8_t data[14];

  if (!readRegisters(address, 0x3B, data, 14)) {
    return false;
  }

  imu.ax = (int16_t)(((uint16_t)data[0] << 8) | data[1]);
  imu.ay = (int16_t)(((uint16_t)data[2] << 8) | data[3]);
  imu.az = (int16_t)(((uint16_t)data[4] << 8) | data[5]);

  // Skip temperature bytes 6 and 7.
  imu.gx = (int16_t)(((uint16_t)data[8] << 8) | data[9]);
  imu.gy = (int16_t)(((uint16_t)data[10] << 8) | data[11]);
  imu.gz = (int16_t)(((uint16_t)data[12] << 8) | data[13]);

  return true;
}

int readLeftFSR() {
  digitalWrite(LEFT_FSR_PIN, HIGH);
  digitalWrite(RIGHT_FSR_PIN, LOW);

  delayMicroseconds(100);

  return analogRead(FSR_ANALOG);
}

int readRightFSR() {
  digitalWrite(LEFT_FSR_PIN, LOW);
  digitalWrite(RIGHT_FSR_PIN, HIGH);

  delayMicroseconds(100);

  return analogRead(FSR_ANALOG);
}

void setup() {
  Serial.begin(115200);
  delay(1500);

  Wire.begin(SDA_PIN, SCL_PIN);
  Wire.setClock(100000);

  Serial.println();
  Serial.println("==============================");
  Serial.println("REHAB WEARABLE");
  Serial.println("ESP-12E SENSOR SYSTEM");
  Serial.println("==============================");

  if (initializeMPU(THIGH_ADDRESS)) {
    Serial.println("THIGH MPU 0x69 : READY");
  } else {
    Serial.println("THIGH MPU 0x69 : ERROR");
  }

  if (initializeMPU(SHIN_ADDRESS)) {
    Serial.println("SHIN MPU 0x68 : READY");
  } else {
    Serial.println("SHIN MPU 0x68 : ERROR");
  }

  pinMode(LEFT_FSR_PIN, OUTPUT);
  pinMode(RIGHT_FSR_PIN, OUTPUT);

  digitalWrite(LEFT_FSR_PIN, LOW);
  digitalWrite(RIGHT_FSR_PIN, LOW);

  WiFi.mode(WIFI_AP);
  WiFi.softAP(WIFI_NAME, WIFI_PASSWORD);

  delay(500);

  Serial.println();
  Serial.println("==============================");
  Serial.println("WIFI READY");
  Serial.println("==============================");

  Serial.print("NETWORK: ");
  Serial.println(WIFI_NAME);

  Serial.print("PASSWORD: ");
  Serial.println(WIFI_PASSWORD);

  Serial.print("DEVICE IP: ");
  Serial.println(WiFi.softAPIP());

  server.begin();

  Serial.println("DATA SERVER READY");
  Serial.println("WAITING FOR MOBILE APP...");
  Serial.println("==============================");
}

void loop() {
  WiFiClient client = server.available();

  if (!client) {
    delay(10);
    return;
  }

  Serial.println();
  Serial.println("MOBILE APP CONNECTED");

  // Exact CSV header supported by your application.
  client.println(
    "time_us,"
    "thigh_ax,thigh_ay,thigh_az,"
    "thigh_gx,thigh_gy,thigh_gz,"
    "shin_ax,shin_ay,shin_az,"
    "shin_gx,shin_gy,shin_gz,"
    "fsr_left,fsr_right"
  );

  unsigned long lastTime = millis();

  while (client.connected()) {
    if (millis() - lastTime < SAMPLE_PERIOD_MS) {
      delay(1);
      continue;
    }

    lastTime = millis();

    IMUData thigh;
    bool thighOK = readMPU(THIGH_ADDRESS, thigh);

    IMUData shin;
    bool shinOK = readMPU(SHIN_ADDRESS, shin);

    int leftFSR = readLeftFSR();
    int rightFSR = readRightFSR();

    // Application expects microseconds, not milliseconds.
    client.print(micros());
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
      client.print("0,0,0,0,0,0");
    }

    client.print(",");

    if (shinOK) {
      client.print(shin.ax);
      client.print(",");
      client.print(shin.ay);
      client.print(",");
      client.print(shin.az);
      client.print(",");
      client.print(shin.gx);
      client.print(",");
      client.print(shin.gy);
      client.print(",");
      client.print(shin.gz);
    } else {
      client.print("0,0,0,0,0,0");
    }

    client.print(",");
    client.print(leftFSR);
    client.print(",");
    client.println(rightFSR);
  }

  client.stop();
  Serial.println("MOBILE APP DISCONNECTED");
}