#version 460 core

// The unsharp mask of the live previews (spec §6): what
// lib/core/color/color_engine.dart's `unsharp` does to the corrected
// picture, on the graphics card: the picture plus uAmount times its
// difference from a Gaussian blur seven pixels wide, the edges mirrored.

#include <flutter/runtime_effect.glsl>

precision highp float;

uniform vec2 uSize;
// The blur's weights from the middle outwards (they add up to 1).
uniform vec4 uKernel;
uniform float uAmount;
uniform sampler2D uImage;

out vec4 fragColor;

float weight(float k) {
  float d = abs(k);
  return d < 0.5 ? uKernel.x : (d < 1.5 ? uKernel.y : (d < 2.5 ? uKernel.z : uKernel.w));
}

// A pixel's index mirrored back into 0 to size - 1 (the edge pixel itself
// not repeated, as OpenCV's default border).
float mirrored(float i, float size) {
  float j = abs(i);
  return j > size - 1.0 ? 2.0 * (size - 1.0) - j : j;
}

vec3 pixel(vec2 at) {
  // Not flipped on OpenGL ES either (color_correct.frag).
  vec2 uv = (vec2(mirrored(at.x, uSize.x), mirrored(at.y, uSize.y)) + 0.5) / uSize;
  return texture(uImage, uv).rgb;
}

void main() {
  vec2 at = floor(FlutterFragCoord().xy);
  vec3 blur = vec3(0.0);
  for (float y = -3.0; y <= 3.0; y += 1.0) {
    vec3 row = vec3(0.0);
    for (float x = -3.0; x <= 3.0; x += 1.0) {
      row += weight(x) * pixel(at + vec2(x, y));
    }
    blur += weight(y) * row;
  }
  // In bytes, as the engine: the blur rounded first, then the result.
  vec3 blurred = floor(blur * 255.0 + 0.5);
  vec3 own = floor(pixel(at) * 255.0 + 0.5);
  vec3 sharp = floor(own * (1.0 + uAmount) - blurred * uAmount + 0.5);
  fragColor = vec4(clamp(sharp, 0.0, 255.0) / 255.0, 1.0);
}
