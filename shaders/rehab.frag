#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;

out vec4 fragColor;

float hash21(vec2 point) {
  point = fract(point * vec2(123.34, 345.45));
  point += dot(point, point + 34.345);
  return fract(point.x * point.y);
}

float noise(vec2 point) {
  vec2 cell = floor(point);
  vec2 local = fract(point);
  local = local * local * (3.0 - 2.0 * local);
  return mix(
    mix(hash21(cell), hash21(cell + vec2(1.0, 0.0)), local.x),
    mix(hash21(cell + vec2(0.0, 1.0)), hash21(cell + vec2(1.0, 1.0)), local.x),
    local.y
  );
}

float fbm(vec2 point) {
  float value = 0.0;
  float amplitude = 0.5;
  for (int octave = 0; octave < 4; octave++) {
    value += amplitude * noise(point);
    point *= 2.03;
    amplitude *= 0.5;
  }
  return value;
}

void main() {
  vec2 pixel = FlutterFragCoord().xy;
  vec2 uv = pixel / uSize;
  float warp = fbm(uv * 2.4 + vec2(4.0, 7.0));
  vec2 field = uv * 3.1 + vec2(warp * 0.7, warp * -0.5);
  float sageField = smoothstep(0.36, 0.64, fbm(field + vec2(3.0, 1.0)));
  float lilacField = smoothstep(0.40, 0.68, fbm(field * 0.85 + vec2(8.0, 4.0)));
  float peachField = smoothstep(0.45, 0.73, fbm(field * 1.15 + vec2(1.0, 9.0)));
  float grain = hash21(floor(pixel)) - 0.5;

  vec3 color = vec3(0.91, 0.89, 0.87);
  color = mix(color, vec3(0.62, 0.74, 0.64), sageField * 0.62);
  color = mix(color, vec3(0.72, 0.63, 0.84), lilacField * 0.58);
  color = mix(color, vec3(0.96, 0.70, 0.58), peachField * 0.50);
  color += grain * 0.055;

  fragColor = vec4(color, 1.0);
}
