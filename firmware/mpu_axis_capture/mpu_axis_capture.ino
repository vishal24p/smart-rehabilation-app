#include <Arduino.h>
#include <Wire.h>
#include <ESP8266WiFi.h>
#include <ESP8266WebServer.h>
#include <math.h>

// ============================================================
// REHAB WEARABLE - ESP8266
// ============================================================
//
// HARDWARE
//
// THIGH MPU6050
// AD0 -> 3.3V -> address 0x69
//
// SHIN MPU6050
// AD0 -> GND -> address 0x68
//
// BOTH MPU6050
// SDA -> D2 / GPIO4
// SCL -> D1 / GPIO5
//
// FSR
// LEFT SELECT  -> D5 / GPIO14
// RIGHT SELECT -> D6 / GPIO12
// SIGNAL       -> A0
//
// WIFI
// SSID     : REHAB-WEARABLE
// PASSWORD : rehab1234
//
// PHONE
// http://192.168.4.1
//
// ============================================================


// ============================================================
// WIFI
// ============================================================

const char* WIFI_NAME = "REHAB-WEARABLE";
const char* WIFI_PASSWORD = "rehab1234";

ESP8266WebServer server(80);


// ============================================================
// I2C
// ============================================================

#define SDA_PIN 4
#define SCL_PIN 5

#define THIGH_ADDRESS 0x69
#define SHIN_ADDRESS  0x68


// ============================================================
// FSR
// ============================================================

#define LEFT_FSR_PIN  14
#define RIGHT_FSR_PIN 12
#define FSR_ANALOG    A0


// ============================================================
// TIMING
// ============================================================

#define SENSOR_PERIOD 50

#define COUNTDOWN_TIME 5000


// ============================================================
// MPU DATA
// ============================================================

struct IMUData
{
  int16_t ax;
  int16_t ay;
  int16_t az;

  int16_t gx;
  int16_t gy;
  int16_t gz;
};

IMUData thigh;
IMUData shin;

bool thighOK = false;
bool shinOK = false;


// ============================================================
// EXERCISE TYPES
// ============================================================

enum ExerciseType
{
  EX_NONE,
  EX_GAIT,
  EX_SQUAT,
  EX_SIT_STAND
};

ExerciseType selectedExercise = EX_NONE;


// ============================================================
// USER INFORMATION
// ============================================================

String injuredLeg = "None";


// ============================================================
// EXERCISE STATE
// ============================================================

bool exerciseRunning = false;
bool countdownRunning = false;

int countdownValue = 5;

unsigned long countdownStart = 0;
unsigned long exerciseStartTime = 0;
unsigned long exerciseEndTime = 0;

unsigned long lastSensorTime = 0;


// ============================================================
// COUNTERS
// ============================================================

int repetitionCount = 0;
int stepCount = 0;


// ============================================================
// FSR VALUES
// ============================================================

int leftFSR = 0;
int rightFSR = 0;

float leftPressureAverage = 0;
float rightPressureAverage = 0;

String heavyLeg = "NONE";


// ============================================================
// REPORT STATISTICS
// ============================================================

float maximumLeftPressure = 0;
float maximumRightPressure = 0;

float totalLeftPressure = 0;
float totalRightPressure = 0;

unsigned long pressureSamples = 0;


// ============================================================
// ANGLES
// ============================================================

float thighAngle = 0;
float shinAngle = 0;

float thighNeutral = 0;
float shinNeutral = 0;

float minimumThighAngle = 9999;
float maximumThighAngle = -9999;

float minimumShinAngle = 9999;
float maximumShinAngle = -9999;


// ============================================================
// MOVEMENT STATE
// ============================================================

bool movementDown = false;

bool leftFootOnGround = false;
bool rightFootOnGround = false;

bool previousLeftFoot = false;
bool previousRightFoot = false;


// ============================================================
// THRESHOLDS
// ============================================================

// These values are starting values.
// They can be tuned after testing.

float SQUAT_THRESHOLD = 25.0;

int FSR_ACTIVE_THRESHOLD = 100;


// ============================================================
// MPU READ
// ============================================================

bool readRegisters(
  uint8_t address,
  uint8_t reg,
  uint8_t* data,
  uint8_t count
)
{
  Wire.beginTransmission(address);

  Wire.write(reg);

  if (Wire.endTransmission(false) != 0)
  {
    return false;
  }

  uint8_t received =
    Wire.requestFrom(address, count);

  if (received != count)
  {
    return false;
  }

  for (uint8_t i = 0; i < count; i++)
  {
    data[i] = Wire.read();
  }

  return true;
}


// ============================================================
// MPU WRITE
// ============================================================

bool writeRegister(
  uint8_t address,
  uint8_t reg,
  uint8_t value
)
{
  Wire.beginTransmission(address);

  Wire.write(reg);
  Wire.write(value);

  return Wire.endTransmission() == 0;
}


// ============================================================
// MPU INITIALIZATION
// ============================================================

bool initializeMPU(uint8_t address)
{
  uint8_t who = 0;

  if (!readRegisters(address, 0x75, &who, 1))
  {
    return false;
  }

  if (who != 0x68 && who != 0x70)
  {
    return false;
  }

  // Reset MPU
  if (!writeRegister(address, 0x6B, 0x80))
  {
    return false;
  }

  delay(100);

  // Wake MPU
  if (!writeRegister(address, 0x6B, 0x01))
  {
    return false;
  }

  // Enable sensors
  if (!writeRegister(address, 0x6C, 0x00)) return false;

  // Digital low pass filter
  if (!writeRegister(address, 0x1A, 0x03)) return false;

  // Gyroscope +/-250 deg/sec
  if (!writeRegister(address, 0x1B, 0x00)) return false;

  // Accelerometer +/-2g
  if (!writeRegister(address, 0x1C, 0x00)) return false;

  delay(50);

  return true;
}


// ============================================================
// READ MPU
// ============================================================

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

// ============================================================
// FSR LEFT
// ============================================================

int readLeftFSR()
{
  digitalWrite(
    LEFT_FSR_PIN,
    HIGH
  );

  digitalWrite(
    RIGHT_FSR_PIN,
    LOW
  );

  delayMicroseconds(100);

  return analogRead(
    FSR_ANALOG
  );
}


// ============================================================
// FSR RIGHT
// ============================================================

int readRightFSR()
{
  digitalWrite(
    LEFT_FSR_PIN,
    LOW
  );

  digitalWrite(
    RIGHT_FSR_PIN,
    HIGH
  );

  delayMicroseconds(100);

  return analogRead(
    FSR_ANALOG
  );
}


// ============================================================
// READ BOTH FSR
// ============================================================

void readFSRs()
{
  leftFSR = readLeftFSR();

  rightFSR = readRightFSR();

  digitalWrite(
    LEFT_FSR_PIN,
    LOW
  );

  digitalWrite(
    RIGHT_FSR_PIN,
    LOW
  );


  // Smooth pressure

  leftPressureAverage =
    (leftPressureAverage * 0.85) +
    (leftFSR * 0.15);

  rightPressureAverage =
    (rightPressureAverage * 0.85) +
    (rightFSR * 0.15);


  // Report statistics

  if (exerciseRunning)
  {
    totalLeftPressure += leftFSR;
    totalRightPressure += rightFSR;

    pressureSamples++;

    if (leftFSR > maximumLeftPressure)
    {
      maximumLeftPressure =
        leftFSR;
    }

    if (rightFSR > maximumRightPressure)
    {
      maximumRightPressure =
        rightFSR;
    }
  }


  // Determine heavy pressure

  if (leftPressureAverage >
      rightPressureAverage + 20)
  {
    heavyLeg = "LEFT";
  }

  else if (
      rightPressureAverage >
      leftPressureAverage + 20)
  {
    heavyLeg = "RIGHT";
  }

  else
  {
    heavyLeg = "BALANCED";
  }
}


// ============================================================
// CALCULATE ANGLE
// ============================================================

float calculateAngle(
  IMUData &imu
)
{
  float ax = imu.ax;
  float ay = imu.ay;
  float az = imu.az;

  float denominator =
    sqrt(
      (ay * ay) +
      (az * az)
    );

  if (denominator < 1)
  {
    return 0;
  }

  float angle =
    atan2(
      ax,
      denominator
    )
    * 180.0 / PI;

  return angle;
}


// ============================================================
// CALIBRATION
// ============================================================

void calibrateNeutral()
{
  Serial.println();
  Serial.println(
    "CALIBRATING NEUTRAL POSITION"
  );

  float thighTotal = 0;
  float shinTotal = 0;

  int thighSamples = 0;
  int shinSamples = 0;

  unsigned long start =
    millis();

  while (
    millis() - start < 1000
  )
  {
    if (
      readMPU(
        THIGH_ADDRESS,
        thigh
      )
    )
    {
      thighTotal +=
        calculateAngle(thigh);
      thighSamples++;
    }

    if (
      readMPU(
        SHIN_ADDRESS,
        shin
      )
    )
    {
      shinTotal +=
        calculateAngle(shin);
      shinSamples++;
    }

    delay(20);
  }

  thighNeutral = thighSamples > 0 ? thighTotal / thighSamples : NAN;
  shinNeutral = shinSamples > 0 ? shinTotal / shinSamples : NAN;

  Serial.print(
    "Thigh neutral: "
  );

  Serial.println(
    thighNeutral
  );

  Serial.print(
    "Shin neutral: "
  );

  Serial.println(
    shinNeutral
  );
}


// ============================================================
// RESET REPORT STATISTICS
// ============================================================

void resetReportData()
{
  maximumLeftPressure = 0;
  maximumRightPressure = 0;

  totalLeftPressure = 0;
  totalRightPressure = 0;

  pressureSamples = 0;

  minimumThighAngle = 9999;
  maximumThighAngle = -9999;

  minimumShinAngle = 9999;
  maximumShinAngle = -9999;
}


// ============================================================
// RESET EXERCISE
// ============================================================

void resetExercise()
{
  repetitionCount = 0;

  stepCount = 0;

  movementDown = false;

  previousLeftFoot = false;
  previousRightFoot = false;

  leftPressureAverage = 0;
  rightPressureAverage = 0;

  heavyLeg = "NONE";

  exerciseRunning = false;

  countdownRunning = false;

  countdownValue = 5;
}


// ============================================================
// START EXERCISE
// ============================================================

void startExercise()
{
  resetExercise();

  resetReportData();
  exerciseStartTime = 0;
  exerciseEndTime = 0;

  countdownRunning = true;

  countdownValue = 5;

  countdownStart = millis();

  Serial.println();
  Serial.println(
    "=============================="
  );

  Serial.println(
    "EXERCISE STARTING"
  );

  Serial.print(
    "INJURED LEG: "
  );

  Serial.println(
    injuredLeg
  );

  Serial.print(
    "EXERCISE: "
  );


  if (
    selectedExercise ==
    EX_GAIT
  )
  {
    Serial.println(
      "GAIT"
    );
  }

  else if (
    selectedExercise ==
    EX_SQUAT
  )
  {
    Serial.println(
      "SQUAT"
    );
  }

  else if (
    selectedExercise ==
    EX_SIT_STAND
  )
  {
    Serial.println(
      "SIT TO STAND"
    );
  }

  Serial.println(
    "=============================="
  );
}


// ============================================================
// COUNTDOWN
// ============================================================

void updateCountdown()
{
  if (!countdownRunning)
  {
    return;
  }

  unsigned long elapsed =
    millis() -
    countdownStart;


  int newValue =
    5 -
    (elapsed / 1000);


  if (
    newValue != countdownValue &&
    newValue >= 1
  )
  {
    countdownValue =
      newValue;

    Serial.print(
      "COUNTDOWN: "
    );

    Serial.println(
      countdownValue
    );
  }


  if (
    elapsed >= COUNTDOWN_TIME
  )
  {
    countdownRunning = false;

    exerciseRunning = true;

    exerciseStartTime =
      millis();

    Serial.println(
      "EXERCISE STARTED"
    );

    calibrateNeutral();
  }
}


// ============================================================
// SQUAT DETECTION
// ============================================================

void processSquat()
{
  float relativeAngle =
    thighAngle -
    thighNeutral;


  if (
    fabs(relativeAngle) >
    SQUAT_THRESHOLD
  )
  {
    movementDown = true;
  }


  if (
    movementDown &&
    fabs(relativeAngle) < 10
  )
  {
    repetitionCount++;

    movementDown = false;

    Serial.print(
      "SQUAT COUNT = "
    );

    Serial.println(
      repetitionCount
    );
  }
}


// ============================================================
// SIT TO STAND
// ============================================================

void processSitStand()
{
  float relativeAngle =
    thighAngle -
    thighNeutral;


  if (
    fabs(relativeAngle) >
    SQUAT_THRESHOLD
  )
  {
    movementDown = true;
  }


  if (
    movementDown &&
    fabs(relativeAngle) < 10
  )
  {
    repetitionCount++;

    movementDown = false;

    Serial.print(
      "SIT-STAND COUNT = "
    );

    Serial.println(
      repetitionCount
    );
  }
}


// ============================================================
// GAIT DETECTION
// ============================================================

void processGait()
{
  leftFootOnGround =
    leftFSR >
    FSR_ACTIVE_THRESHOLD;

  rightFootOnGround =
    rightFSR >
    FSR_ACTIVE_THRESHOLD;


  bool leftNewContact =
    leftFootOnGround &&
    !previousLeftFoot;


  bool rightNewContact =
    rightFootOnGround &&
    !previousRightFoot;


  if (leftNewContact)
  {
    stepCount++;

    Serial.print(
      "LEFT STEP = "
    );

    Serial.println(
      stepCount
    );
  }


  if (rightNewContact)
  {
    stepCount++;

    Serial.print(
      "RIGHT STEP = "
    );

    Serial.println(
      stepCount
    );
  }


  previousLeftFoot =
    leftFootOnGround;

  previousRightFoot =
    rightFootOnGround;
}


// ============================================================
// SENSOR UPDATE
// ============================================================

void updateSensors()
{
  thighOK =
    readMPU(
      THIGH_ADDRESS,
      thigh
    );

  shinOK =
    readMPU(
      SHIN_ADDRESS,
      shin
    );


  if (thighOK)
  {
    thighAngle =
      calculateAngle(
        thigh
      );
  }


  if (shinOK)
  {
    shinAngle =
      calculateAngle(
        shin
      );
  }


  // Only fresh readings contribute to the report.
  if (exerciseRunning && thighOK)
  {
    minimumThighAngle = min(minimumThighAngle, thighAngle);
    maximumThighAngle = max(maximumThighAngle, thighAngle);
  }
  if (exerciseRunning && shinOK)
  {
    minimumShinAngle = min(minimumShinAngle, shinAngle);
    maximumShinAngle = max(maximumShinAngle, shinAngle);
  }
  if (!thighOK)
  {
    // A missing sample breaks a repetition; never bridge it using stale data.
    movementDown = false;
  }

  readFSRs();


  if (!exerciseRunning)
  {
    return;
  }


  switch (
    selectedExercise
  )
  {
    case EX_GAIT:

      processGait();

      break;


    case EX_SQUAT:

      if (thighOK && isfinite(thighNeutral)) processSquat();

      break;


    case EX_SIT_STAND:

      if (thighOK && isfinite(thighNeutral)) processSitStand();

      break;


    default:

      break;
  }
}


// ============================================================
// EXERCISE NAME
// ============================================================

String getExerciseName()
{
  if (
    selectedExercise ==
    EX_GAIT
  )
  {
    return "Gait Analysis";
  }

  if (
    selectedExercise ==
    EX_SQUAT
  )
  {
    return "Squat";
  }

  if (
    selectedExercise ==
    EX_SIT_STAND
  )
  {
    return "Sit to Stand";
  }

  return "None";
}


// ============================================================
// COUNT VALUE
// ============================================================

int getCountValue()
{
  if (
    selectedExercise ==
    EX_GAIT
  )
  {
    return stepCount;
  }

  return repetitionCount;
}


// ============================================================
// SESSION DURATION
// ============================================================

unsigned long getSessionDuration()
{
  if (exerciseStartTime == 0)
  {
    return 0;
  }

  if (exerciseRunning)
  {
    return millis() -
           exerciseStartTime;
  }

  if (exerciseEndTime >=
      exerciseStartTime)
  {
    return exerciseEndTime -
           exerciseStartTime;
  }

  return 0;
}


// ============================================================
// AVERAGE LEFT PRESSURE
// ============================================================

float getAverageLeftPressure()
{
  if (pressureSamples == 0)
  {
    return 0;
  }

  return totalLeftPressure /
         pressureSamples;
}


// ============================================================
// AVERAGE RIGHT PRESSURE
// ============================================================

float getAverageRightPressure()
{
  if (pressureSamples == 0)
  {
    return 0;
  }

  return totalRightPressure /
         pressureSamples;
}


// ============================================================
// LEFT PRESSURE PERCENTAGE
// ============================================================

float getLeftPressurePercent()
{
  float left =
    getAverageLeftPressure();

  float right =
    getAverageRightPressure();

  float total =
    left + right;

  if (total <= 0)
  {
    return 50;
  }

  return
    (left / total) * 100.0;
}


// ============================================================
// RIGHT PRESSURE PERCENTAGE
// ============================================================

float getRightPressurePercent()
{
  float left =
    getAverageLeftPressure();

  float right =
    getAverageRightPressure();

  float total =
    left + right;

  if (total <= 0)
  {
    return 50;
  }

  return
    (right / total) * 100.0;
}


// ============================================================
// GAIT SYMMETRY
// ============================================================

float getGaitSymmetry()
{
  float left =
    getAverageLeftPressure();

  float right =
    getAverageRightPressure();


  float total =
    left + right;


  if (total <= 0)
  {
    return 0;
  }


  float difference =
    fabs(left - right);


  float symmetry =
    100.0 -
    ((difference / total) *
     100.0);


  if (symmetry < 0)
  {
    symmetry = 0;
  }

  if (symmetry > 100)
  {
    symmetry = 100;
  }


  return symmetry;
}


// ============================================================
// LOAD ON INJURED LEG
// ============================================================

String getInjuredLegStatus()
{
  if (
    injuredLeg == "None"
  )
  {
    return "No injured leg selected";
  }


  float left =
    getLeftPressurePercent();

  float right =
    getRightPressurePercent();


  float injuredPressure = 0;


  if (
    injuredLeg == "LEFT"
  )
  {
    injuredPressure =
      left;
  }

  else if (
    injuredLeg == "RIGHT"
  )
  {
    injuredPressure =
      right;
  }


  if (
    injuredPressure < 40
  )
  {
    return "Reduced loading on injured leg";
  }


  if (
    injuredPressure > 60
  )
  {
    return "High loading on injured leg";
  }


  return "Approximately balanced loading";
}


// ============================================================
// WEB HOME PAGE
// ============================================================

const char MAIN_PAGE[] PROGMEM = R"rawliteral(

<!DOCTYPE html>

<html>

<head>

<meta name="viewport"
content="width=device-width,initial-scale=1">

<title>Rehab Wearable</title>

<style>

body
{
  font-family:Arial,sans-serif;
  margin:0;
  background:#eef3f7;
  color:#17212b;
}

.header
{
  background:#173b57;
  color:white;
  padding:20px;
  text-align:center;
}

.container
{
  max-width:700px;
  margin:auto;
  padding:15px;
}

.card
{
  background:white;
  border-radius:15px;
  padding:18px;
  margin-bottom:15px;
  box-shadow:0 3px 12px rgba(0,0,0,0.08);
}

label
{
  display:block;
  margin-top:12px;
  font-weight:bold;
}

select
{
  width:100%;
  padding:13px;
  margin-top:6px;
  border-radius:8px;
  border:1px solid #aaa;
  font-size:16px;
}

button
{
  width:100%;
  padding:15px;
  margin-top:15px;
  border:none;
  border-radius:10px;
  font-size:18px;
  font-weight:bold;
  background:#1f6f8b;
  color:white;
}

button.stop
{
  background:#a52a2a;
}

button.report
{
  background:#3d7c40;
}

.big
{
  text-align:center;
  font-size:55px;
  font-weight:bold;
}

.countdown
{
  text-align:center;
  font-size:80px;
  font-weight:bold;
  color:#c0392b;
}

.status
{
  text-align:center;
  font-size:20px;
  font-weight:bold;
}

.grid
{
  display:grid;
  grid-template-columns:1fr 1fr;
  gap:10px;
}

.value
{
  background:#f1f4f6;
  border-radius:10px;
  padding:14px;
  text-align:center;
}

.value span
{
  display:block;
  font-size:24px;
  font-weight:bold;
  margin-top:5px;
}

.heavy
{
  text-align:center;
  font-size:25px;
  font-weight:bold;
  padding:15px;
}

.warning
{
  padding:12px;
  background:#fff2cc;
  border-radius:10px;
  margin-top:10px;
}

.hidden
{
  display:none;
}

</style>

</head>


<body>


<div class="header">

<h1>REHAB WEARABLE</h1>

<p>Gait & Exercise Monitoring</p>

</div>


<div class="container">


<div class="card">

<h2>Patient Setup</h2>


<label>Injured Leg</label>

<select id="injured">

<option value="None">
No injured leg
</option>

<option value="LEFT">
Left Leg
</option>

<option value="RIGHT">
Right Leg
</option>

</select>


<label>Exercise</label>

<select id="exercise">

<option value="GAIT">
Gait Analysis
</option>

<option value="SQUAT">
Squat
</option>

<option value="SIT_STAND">
Sit to Stand
</option>

</select>


<button onclick="startExercise()">
START EXERCISE
</button>


<button class="stop"
onclick="stopExercise()">
STOP
</button>


<button class="report"
onclick="openReport()">
GENERATE REPORT
</button>

</div>


<div class="card">

<div id="status"
class="status">
Ready
</div>


<div id="countdown"
class="countdown hidden">
5
</div>


<div class="big"
id="count">
0
</div>


<div style="text-align:center"
id="countLabel">

Repetitions / Steps

</div>

</div>


<div class="card">

<h2>Pressure</h2>


<div class="grid">

<div class="value">

Left FSR

<span id="leftPressure">
0
</span>

</div>


<div class="value">

Right FSR

<span id="rightPressure">
0
</span>

</div>

</div>


<div class="heavy"
id="heavy">

Pressure: --

</div>


<div class="warning"
id="injuredWarning">

Injured leg: None

</div>

</div>


<div class="card">

<h2>Pressure Distribution</h2>


<div class="grid">

<div class="value">

Left %

<span id="leftPercent">
50
</span>

</div>


<div class="value">

Right %

<span id="rightPercent">
50
</span>

</div>

</div>


<div class="warning"
id="injuredStatus">

No injured leg selected

</div>

</div>


<div class="card">

<h2>Movement</h2>


<div class="grid">

<div class="value">

Thigh Angle

<span id="thighAngle">
0
</span>

</div>


<div class="value">

Shin Angle

<span id="shinAngle">
0
</span>

</div>

</div>

</div>


<div class="card">

<h2>Gait Symmetry</h2>

<div class="big"
id="symmetry">

0%

</div>

</div>


<div class="card">

<h2>Raw Sensors</h2>


<div class="grid">

<div class="value">

Thigh AX

<span id="tax">
0
</span>

</div>


<div class="value">

Thigh AY

<span id="tay">
0
</span>

</div>


<div class="value">

Thigh AZ

<span id="taz">
0
</span>

</div>


<div class="value">

Shin AX

<span id="sax">
0
</span>

</div>


<div class="value">

Shin AY

<span id="say">
0
</span>

</div>


<div class="value">

Shin AZ

<span id="saz">
0
</span>

</div>

</div>

</div>


</div>


<script>


function startExercise()
{
  const injured =
    document.getElementById(
      "injured"
    ).value;


  const exercise =
    document.getElementById(
      "exercise"
    ).value;


  fetch(
    "/start?injured=" +
    encodeURIComponent(injured) +
    "&exercise=" +
    encodeURIComponent(exercise)
  );


  document.getElementById(
    "status"
  ).innerText =
    "Starting...";


  document.getElementById(
    "injuredWarning"
  ).innerText =
    "Injured leg: " +
    injured;
}


function stopExercise()
{
  fetch("/stop");

  document.getElementById(
    "status"
  ).innerText =
    "Stopped";
}


function openReport()
{
  window.open(
    "/report",
    "_blank"
  );
}


function updateData()
{
  fetch("/data")
  .then(
    response => response.json()
  )
  .then(
    data =>
    {

      document.getElementById(
        "leftPressure"
      ).innerText =
        data.leftFSR;


      document.getElementById(
        "rightPressure"
      ).innerText =
        data.rightFSR;


      document.getElementById(
        "heavy"
      ).innerText =
        "Pressure: " +
        data.heavyLeg;


      document.getElementById(
        "leftPercent"
      ).innerText =
        data.leftPercent.toFixed(1) +
        "%";


      document.getElementById(
        "rightPercent"
      ).innerText =
        data.rightPercent.toFixed(1) +
        "%";


      document.getElementById(
        "injuredStatus"
      ).innerText =
        data.injuredStatus;


      document.getElementById(
        "thighAngle"
      ).innerText =
        data.thighAngle.toFixed(1) +
        "°";


      document.getElementById(
        "shinAngle"
      ).innerText =
        data.shinAngle.toFixed(1) +
        "°";


      document.getElementById(
        "symmetry"
      ).innerText =
        data.symmetry.toFixed(1) +
        "%";


      document.getElementById(
        "tax"
      ).innerText =
        data.tax;


      document.getElementById(
        "tay"
      ).innerText =
        data.tay;


      document.getElementById(
        "taz"
      ).innerText =
        data.taz;


      document.getElementById(
        "sax"
      ).innerText =
        data.sax;


      document.getElementById(
        "say"
      ).innerText =
        data.say;


      document.getElementById(
        "saz"
      ).innerText =
        data.saz;


      document.getElementById(
        "count"
      ).innerText =
        data.count;


      document.getElementById(
        "injuredWarning"
      ).innerText =
        "Injured leg: " +
        data.injured;


      if(data.exercise == "GAIT")
      {
        document.getElementById(
          "countLabel"
        ).innerText =
          "Steps";
      }

      else
      {
        document.getElementById(
          "countLabel"
        ).innerText =
          "Repetitions";
      }


      if(data.countdownRunning)
      {
        document.getElementById(
          "countdown"
        ).classList.remove(
          "hidden"
        );


        document.getElementById(
          "countdown"
        ).innerText =
          data.countdown;


        document.getElementById(
          "status"
        ).innerText =
          "GET READY";
      }

      else
      {
        document.getElementById(
          "countdown"
        ).classList.add(
          "hidden"
        );
      }


      if(data.running)
      {
        document.getElementById(
          "status"
        ).innerText =
          "EXERCISE RUNNING";
      }

    }
  )
  .catch(
    error =>
    {
      document.getElementById(
        "status"
      ).innerText =
        "Wi-Fi connection lost";
    }
  );
}


setInterval(
  updateData,
  200
);


updateData();

</script>


</body>

</html>

)rawliteral";


// ============================================================
// HOME
// ============================================================

void handleRoot()
{
  server.send_P(
    200,
    "text/html",
    MAIN_PAGE
  );
}


// ============================================================
// START
// ============================================================

void handleStart()
{
  String injured = server.arg("injured");
  String ex = server.arg("exercise");
  if ((injured != "None" && injured != "LEFT" && injured != "RIGHT") ||
      (ex != "GAIT" && ex != "SQUAT" && ex != "SIT_STAND"))
  {
    server.send(400, "text/plain", "Choose a valid injured leg and exercise.");
    return;
  }

  injuredLeg = injured;
  selectedExercise = ex == "GAIT" ? EX_GAIT :
                     ex == "SQUAT" ? EX_SQUAT : EX_SIT_STAND;
  startExercise();
  server.send(200, "text/plain", "STARTED");
}


// ============================================================
// STOP
// ============================================================

void handleStop()
{
  if (exerciseRunning)
  {
    exerciseEndTime =
      millis();
  }

  exerciseRunning = false;
  countdownRunning = false;
  movementDown = false;


  server.send(
    200,
    "text/plain",
    "STOPPED"
  );
}


// ============================================================
// DATA JSON
// ============================================================

void handleData()
{
  String exerciseName =
    getExerciseName();


  int countValue =
    getCountValue();


  String json = "{";


  json +=
    "\"running\":";

  json +=
    exerciseRunning
      ? "true"
      : "false";


  json +=
    ",";


  json +=
    "\"countdownRunning\":";

  json +=
    countdownRunning
      ? "true"
      : "false";


  json +=
    ",";


  json +=
    "\"countdown\":";

  json +=
    String(
      countdownValue
    );


  json +=
    ",";


  json +=
    "\"count\":";

  json +=
    String(
      countValue
    );


  json +=
    ",";


  json +=
    "\"exercise\":\"";

  json +=
    exerciseName;

  json +=
    "\"";


  json +=
    ",";


  json +=
    "\"injured\":\"";

  json +=
    injuredLeg;

  json +=
    "\"";


  json +=
    ",";


  json +=
    "\"leftFSR\":";

  json +=
    String(
      leftFSR
    );


  json +=
    ",";


  json +=
    "\"rightFSR\":";

  json +=
    String(
      rightFSR
    );


  json +=
    ",";


  json +=
    "\"heavyLeg\":\"";

  json +=
    heavyLeg;

  json +=
    "\"";


  json +=
    ",";


  json +=
    "\"leftPercent\":";

  json +=
    String(
      getLeftPressurePercent(),
      2
    );


  json +=
    ",";


  json +=
    "\"rightPercent\":";

  json +=
    String(
      getRightPressurePercent(),
      2
    );


  json +=
    ",";


  json +=
    "\"symmetry\":";

  json +=
    String(
      getGaitSymmetry(),
      2
    );


  json +=
    ",";


  json +=
    "\"injuredStatus\":\"";

  json +=
    getInjuredLegStatus();

  json +=
    "\"";


  json +=
    ",";


  json +=
    "\"thighAngle\":";

  json +=
    String(
      thighAngle,
      2
    );


  json +=
    ",";


  json +=
    "\"shinAngle\":";

  json +=
    String(
      shinAngle,
      2
    );


  json +=
    ",";


  json +=
    "\"tax\":";

  json +=
    String(
      thigh.ax
    );


  json +=
    ",";


  json +=
    "\"tay\":";

  json +=
    String(
      thigh.ay
    );


  json +=
    ",";


  json +=
    "\"taz\":";

  json +=
    String(
      thigh.az
    );


  json +=
    ",";


  json +=
    "\"sax\":";

  json +=
    String(
      shin.ax
    );


  json +=
    ",";


  json +=
    "\"say\":";

  json +=
    String(
      shin.ay
    );


  json +=
    ",";


  json +=
    "\"saz\":";

  json +=
    String(
      shin.az
    );


  json +=
    "}";


  server.send(
    200,
    "application/json",
    json
  );
}


// ============================================================
// REPORT PAGE
// ============================================================

void handleReport()
{
  unsigned long duration =
    getSessionDuration();


  unsigned long seconds =
    duration / 1000;


  unsigned long minutes =
    seconds / 60;


  seconds =
    seconds % 60;


  float leftAverage =
    getAverageLeftPressure();


  float rightAverage =
    getAverageRightPressure();


  float leftPercent =
    getLeftPressurePercent();


  float rightPercent =
    getRightPressurePercent();


  float symmetry =
    getGaitSymmetry();


  String performance;


  if (
    selectedExercise ==
    EX_GAIT
  )
  {
    if (symmetry >= 90)
    {
      performance =
        "Excellent pressure symmetry";
    }

    else if (symmetry >= 75)
    {
      performance =
        "Good pressure symmetry";
    }

    else if (symmetry >= 60)
    {
      performance =
        "Moderate pressure asymmetry";
    }

    else
    {
      performance =
        "Significant pressure asymmetry";
    }
  }

  else
  {
    if (repetitionCount >= 15)
    {
      performance =
        "Good exercise volume";
    }

    else if (repetitionCount >= 8)
    {
      performance =
        "Moderate exercise volume";
    }

    else
    {
      performance =
        "Low exercise volume";
    }
  }


  String report = R"rawliteral(

<!DOCTYPE html>

<html>

<head>

<meta name="viewport"
content="width=device-width,initial-scale=1">

<title>Rehabilitation Report</title>

<style>

body
{
  font-family:Arial,sans-serif;
  background:#eeeeee;
  margin:0;
  color:#222;
}

.report
{
  max-width:750px;
  margin:auto;
  background:white;
  padding:25px;
}

.header
{
  text-align:center;
  border-bottom:2px solid #333;
  padding-bottom:15px;
}

h1
{
  margin-bottom:5px;
}

h2
{
  margin-top:25px;
  border-bottom:1px solid #aaa;
  padding-bottom:7px;
}

table
{
  width:100%;
  border-collapse:collapse;
}

td,th
{
  border:1px solid #aaa;
  padding:10px;
  text-align:left;
}

th
{
  background:#eeeeee;
}

.summary
{
  font-size:22px;
  text-align:center;
  padding:20px;
  background:#eef3f7;
  border-radius:10px;
}

button
{
  width:100%;
  padding:14px;
  margin-top:20px;
  border:none;
  border-radius:8px;
  background:#286c8c;
  color:white;
  font-size:18px;
}

@media print
{
  button
  {
    display:none;
  }

  body
  {
    background:white;
  }

  .report
  {
    max-width:none;
  }
}

</style>

</head>


<body>


<div class="report">


<div class="header">

<h1>REHABILITATION EXERCISE REPORT</h1>

<p>ESP8266 Rehab Wearable System</p>

</div>


<h2>Patient / Session</h2>


<table>

<tr>
<th>Injured Leg</th>
<td>)rawliteral";


  report +=
    injuredLeg;


  report += R"rawliteral(</td>
</tr>

<tr>
<th>Exercise</th>
<td>)rawliteral";


  report +=
    getExerciseName();


  report += R"rawliteral(</td>
</tr>

<tr>
<th>Duration</th>
<td>)rawliteral";


  report +=
    String(minutes);


  report +=
    " min ";


  report +=
    String(seconds);


  report +=
    " sec";


  report += R"rawliteral(</td>
</tr>

</table>


<h2>Exercise Result</h2>


<div class="summary">

)rawliteral";


  if (
    selectedExercise ==
    EX_GAIT
  )
  {
    report +=
      "Total Steps: ";


    report +=
      String(stepCount);
  }

  else
  {
    report +=
      "Total Repetitions: ";


    report +=
      String(repetitionCount);
  }


  report += R"rawliteral(

</div>


<h2>Pressure Analysis</h2>


<table>

<tr>

<th>Parameter</th>
<th>Result</th>

</tr>


<tr>

<td>Average Left Pressure</td>

<td>)rawliteral";


  report +=
    String(
      leftAverage,
      1
    );


  report += R"rawliteral(</td>

</tr>


<tr>

<td>Average Right Pressure</td>

<td>)rawliteral";


  report +=
    String(
      rightAverage,
      1
    );


  report += R"rawliteral(</td>

</tr>


<tr>

<td>Left Pressure Distribution</td>

<td>)rawliteral";


  report +=
    String(
      leftPercent,
      1
    );


  report += "%";


  report += R"rawliteral(</td>

</tr>


<tr>

<td>Right Pressure Distribution</td>

<td>)rawliteral";


  report +=
    String(
      rightPercent,
      1
    );


  report += "%";


  report += R"rawliteral(</td>

</tr>


<tr>

<td>Heavier Loading Leg</td>

<td>)rawliteral";


  report +=
    heavyLeg;


  report += R"rawliteral(</td>

</tr>


<tr>

<td>Maximum Left FSR</td>

<td>)rawliteral";


  report +=
    String(
      maximumLeftPressure,
      0
    );


  report += R"rawliteral(</td>

</tr>


<tr>

<td>Maximum Right FSR</td>

<td>)rawliteral";


  report +=
    String(
      maximumRightPressure,
      0
    );


  report += R"rawliteral(</td>

</tr>

</table>


<h2>Gait Symmetry</h2>


<div class="summary">

)rawliteral";


  report +=
    String(
      symmetry,
      1
    );


  report +=
    "%";


  report += R"rawliteral(

</div>


<h2>Injured Leg Loading</h2>


<div class="summary">

)rawliteral";


  report +=
    getInjuredLegStatus();


  report += R"rawliteral(

</div>


<h2>Movement Analysis</h2>


<table>

<tr>

<th>Parameter</th>
<th>Minimum</th>
<th>Maximum</th>

</tr>


<tr>

<td>Thigh Angle</td>

<td>)rawliteral";


  report +=
    String(
      minimumThighAngle,
      1
    );


  report +=
    "°";


  report += R"rawliteral(</td>

<td>)rawliteral";


  report +=
    String(
      maximumThighAngle,
      1
    );


  report +=
    "°";


  report += R"rawliteral(</td>

</tr>


<tr>

<td>Shin Angle</td>

<td>)rawliteral";


  report +=
    String(
      minimumShinAngle,
      1
    );


  report +=
    "°";


  report += R"rawliteral(</td>

<td>)rawliteral";


  report +=
    String(
      maximumShinAngle,
      1
    );


  report +=
    "°";


  report += R"rawliteral(</td>

</tr>

</table>


<h2>Overall Observation</h2>


<div class="summary">

)rawliteral";


  report +=
    performance;


  report += R"rawliteral(

</div>


<h2>Important Note</h2>

<p>

The FSR values in this prototype are
raw sensor readings. They are not calibrated
force values in kilograms or Newtons.

Pressure distribution is calculated from
the relative left/right FSR readings.

Exercise thresholds should be calibrated
for the patient's movement and sensor
placement before clinical use.

</p>


<button onclick="window.print()">

PRINT / SAVE REPORT AS PDF

</button>


</div>


</body>

</html>

)rawliteral";


  server.send(
    200,
    "text/html",
    report
  );
}


// ============================================================
// SETUP
// ============================================================

void setup()
{
  Serial.begin(
    115200
  );

  delay(1500);


  Serial.println();

  Serial.println(
    "================================"
  );

  Serial.println(
    "REHAB WEARABLE"
  );

  Serial.println(
    "ESP8266 GAIT + EXERCISE SYSTEM"
  );

  Serial.println(
    "================================"
  );


  // ----------------------------------------------------------
  // I2C
  // ----------------------------------------------------------

  Wire.begin(
    SDA_PIN,
    SCL_PIN
  );

  Wire.setClock(
    100000
  );
  // Bound clock stretching when a disconnected sensor holds SCL low.
  Wire.setClockStretchLimit(1000);


  // ----------------------------------------------------------
  // THIGH MPU
  // ----------------------------------------------------------

  thighOK =
    initializeMPU(
      THIGH_ADDRESS
    );


  if (thighOK)
  {
    Serial.println(
      "THIGH MPU 0x69 : READY"
    );
  }

  else
  {
    Serial.println(
      "THIGH MPU 0x69 : ERROR"
    );
  }


  // ----------------------------------------------------------
  // SHIN MPU
  // ----------------------------------------------------------

  shinOK =
    initializeMPU(
      SHIN_ADDRESS
    );


  if (shinOK)
  {
    Serial.println(
      "SHIN MPU 0x68 : READY"
    );
  }

  else
  {
    Serial.println(
      "SHIN MPU 0x68 : ERROR"
    );
  }


  // ----------------------------------------------------------
  // FSR
  // ----------------------------------------------------------

  pinMode(
    LEFT_FSR_PIN,
    OUTPUT
  );

  pinMode(
    RIGHT_FSR_PIN,
    OUTPUT
  );


  digitalWrite(
    LEFT_FSR_PIN,
    LOW
  );

  digitalWrite(
    RIGHT_FSR_PIN,
    LOW
  );


  // ----------------------------------------------------------
  // WIFI ACCESS POINT
  // ----------------------------------------------------------

  WiFi.mode(
    WIFI_AP
  );


  WiFi.softAP(
    WIFI_NAME,
    WIFI_PASSWORD
  );


  delay(500);


  Serial.println();

  Serial.println(
    "================================"
  );

  Serial.println(
    "WIFI READY"
  );

  Serial.println(
    "================================"
  );


  Serial.print(
    "NETWORK: "
  );

  Serial.println(
    WIFI_NAME
  );


  Serial.print(
    "PASSWORD: "
  );

  Serial.println(
    WIFI_PASSWORD
  );


  Serial.print(
    "PHONE ADDRESS: http://"
  );

  Serial.println(
    WiFi.softAPIP()
  );


  // ----------------------------------------------------------
  // WEB SERVER
  // ----------------------------------------------------------

  server.on(
    "/",
    handleRoot
  );


  server.on(
    "/start",
    handleStart
  );


  server.on(
    "/stop",
    handleStop
  );


  server.on(
    "/data",
    handleData
  );


  server.on(
    "/report",
    handleReport
  );


  server.begin();


  Serial.println();

  Serial.println(
    "WEB SERVER READY"
  );

  Serial.println(
    "CONNECT PHONE TO:"
  );

  Serial.println(
    "REHAB-WEARABLE"
  );

  Serial.println();

  Serial.println(
    "OPEN:"
  );

  Serial.println(
    "http://192.168.4.1"
  );

  Serial.println();

  Serial.println(
    "================================"
  );
}


// ============================================================
// LOOP
// ============================================================

void loop()
{
  // Handle phone requests
  server.handleClient();


  // Handle countdown
  updateCountdown();


  // Update sensors
  if (
    millis() -
    lastSensorTime >=
    SENSOR_PERIOD
  )
  {
    lastSensorTime =
      millis();

    updateSensors();
  }
}