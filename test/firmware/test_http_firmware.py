"""Run actual HTTP firmware reader/start/stop functions on a host C++ compiler."""
from pathlib import Path
import glob
import shutil
import subprocess
import tempfile
import unittest


class HttpFirmwareTest(unittest.TestCase):
    def test_reader_validation_and_retained_report(self):
        sketch = (Path(__file__).resolve().parents[2] /
                  'firmware/mpu_axis_capture/mpu_axis_capture.ino').read_text()

        def function(name):
            start = sketch.index(name + '(')
            start = sketch.rfind('\n', 0, start) + 1
            body = sketch.index('{', start)
            depth = 1
            end = body + 1
            while depth:
                depth += (sketch[end] == '{') - (sketch[end] == '}')
                end += 1
            return sketch[start:end]

        source = r'''
#include <cassert>
#include <cstdint>
#include <string>
using String = std::string;
enum ExerciseType { EX_NONE, EX_GAIT, EX_SQUAT, EX_SIT_STAND };
struct IMUData { int16_t ax, ay, az, gx, gy, gz; };
bool readable = true;
bool readRegisters(uint8_t, uint8_t reg, uint8_t* data, uint8_t count) {
  assert(reg == 0x3B && count == 14);
  if (!readable) return false;
  uint8_t sample[] = {0x80,0,0x7f,0xff,0,1,0xff,0xff,0xff,0xfe,0,3,0,4};
  for (int i = 0; i < 14; i++) data[i] = sample[i];
  return true;
}
struct Server {
  String injured = "LEFT", exercise = "GAIT";
  int status = 0;
  String arg(const char* name) { return String(name) == "injured" ? injured : exercise; }
  void send(int value, const char*, const char*) { status = value; }
} server;
String injuredLeg = "None";
ExerciseType selectedExercise = EX_NONE;
bool exerciseRunning = true, countdownRunning = true, movementDown = true;
unsigned long exerciseStartTime = 100, exerciseEndTime = 0;
int repetitionCount = 7, stepCount = 12, starts = 0;
unsigned long millis() { return 1000; }
void startExercise() { starts++; }
'''
        source += '\n'.join(function(name) for name in
                            ('readMPU', 'handleStart', 'handleStop'))
        source += r'''
int main() {
  IMUData imu = {};
  assert(readMPU(0x69, imu));
  assert(imu.ax == -32768 && imu.ay == 32767 && imu.az == 1);
  assert(imu.gx == -2 && imu.gy == 3 && imu.gz == 4);
  readable = false;
  assert(!readMPU(0x69, imu) && imu.ax == -32768);
  server.injured = "<script>";
  handleStart();
  assert(server.status == 400 && starts == 0 && injuredLeg == "None");
  server.injured = "LEFT";
  server.exercise = "UNKNOWN";
  handleStart();
  assert(server.status == 400 && starts == 0 && selectedExercise == EX_NONE);
  server.exercise = "GAIT";
  handleStart();
  assert(server.status == 200 && starts == 1 && injuredLeg == "LEFT" && selectedExercise == EX_GAIT);
  handleStop();
  assert(!exerciseRunning && !countdownRunning && !movementDown);
  assert(repetitionCount == 7 && stepCount == 12 && exerciseEndTime == 1000);
  handleStop();
  assert(repetitionCount == 7 && stepCount == 12 && exerciseEndTime == 1000);
}
'''
        with tempfile.TemporaryDirectory() as directory:
            cpp = Path(directory) / 'regression.cpp'
            exe = Path(directory) / 'regression.exe'
            cpp.write_text(source)
            compiler = shutil.which('g++') or shutil.which('clang++')
            if compiler:
                subprocess.run([compiler, '-std=c++17', str(cpp), '-o', str(exe)], check=True)
            else:
                setups = glob.glob('C:/Program Files*/Microsoft Visual Studio/*/*/VC/Auxiliary/Build/vcvars64.bat')
                if not setups:
                    self.fail('Host C++ compiler required for firmware regression check.')
                command = (f'call "{setups[0]}" >nul && cl /nologo /EHsc /std:c++17 '
                           f'"{cpp}" /Fe:"{exe}" /Fo:"{Path(directory) / "regression.obj"}"')
                subprocess.run(command, shell=True, check=True)
            subprocess.run([str(exe)], check=True)


if __name__ == '__main__':
    unittest.main()
