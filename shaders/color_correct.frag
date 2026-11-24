#version 460 core

// The colour correction of the live previews (spec §6): what
// ColorEngine.correct does to a pixel, on the graphics card. The analysis
// (the eleven numbers of the filter) stays in Dart; this only applies it.
// Kept in step with lib/core/color/color_engine.dart by
// test/color/color_shader_test.dart.

#include <flutter/runtime_effect.glsl>

precision highp float;

uniform vec2 uSize;
// Red and blue restored from green.
uniform vec2 uColorFactor;
uniform vec3 uBlackPoint;
uniform vec3 uGreyWorld;
uniform float uDehaze;
// The filter's exposure times (1 - the profile's darkness).
uniform float uExposure;
// The profile's reference hue less the frame's blue hue.
uniform float uHueShift;
// How much of the correction is mixed in.
uniform float uCif;
// The profile's vibrance, contrast and reference water hue (the look,
// spec §10.101).
uniform float uVibrance;
uniform float uContrast;
uniform float uWaterHue;
uniform sampler2D uImage;

out vec4 fragColor;

const float TWO_PI = 6.283185307179586;

vec3 toLinear(vec3 v) {
  vec3 low = v / 12.92;
  vec3 high = pow((v + 0.055) / 1.055, vec3(2.4));
  return mix(high, low, vec3(lessThanEqual(v, vec3(0.04045))));
}

// Linear light to sRGB in the engine's 4096 steps, cut to a byte.
vec3 toSrgbByte(vec3 v) {
  vec3 q = clamp(floor(v * 4095.0 + 0.5), 0.0, 4095.0) / 4095.0;
  vec3 low = q * 12.92;
  vec3 high = pow(q, vec3(0.41666666667)) * 1.055 - 0.055;
  vec3 s = clamp(mix(high, low, vec3(lessThanEqual(q, vec3(0.0031308)))), 0.0, 1.0);
  // A hair up before the cut, so that a value a rounding error under a
  // whole byte is not a byte less.
  return floor(s * 255.0 + 0.0001) / 255.0;
}

vec3 cbrt3(vec3 v) {
  return sign(v) * pow(abs(v), vec3(1.0 / 3.0));
}

// Lightness, chroma and hue (0 to 1) of a linear colour.
vec3 toOklch(vec3 v) {
  vec3 lms = cbrt3(vec3(
    0.4122214708 * v.r + 0.5363325363 * v.g + 0.0514459929 * v.b,
    0.2119034982 * v.r + 0.6806995451 * v.g + 0.1073969566 * v.b,
    0.0883024619 * v.r + 0.2817188376 * v.g + 0.6299787005 * v.b));
  float lightness = dot(vec3(0.2104542553, 0.7936177850, -0.0040720468), lms);
  float a = dot(vec3(1.9779984951, -2.4285922050, 0.4505937099), lms);
  float b = dot(vec3(0.0259040371, 0.7827717662, -0.8086757660), lms);
  float hue = 0.0;
  if (abs(a) + abs(b) > 1e-12) {
    hue = atan(b, a) / TWO_PI;
  }
  if (hue < 0.0) {
    hue += 1.0;
  }
  return vec3(lightness, sqrt(a * a + b * b), hue);
}

vec3 toRgb(vec3 lch) {
  float angle = TWO_PI * lch.z;
  float a = lch.y * cos(angle);
  float b = lch.y * sin(angle);
  vec3 lms = vec3(
    lch.x + 0.3963377774 * a + 0.2158037573 * b,
    lch.x - 0.1055613458 * a - 0.0638541728 * b,
    lch.x - 0.0894841775 * a - 1.2914855480 * b);
  lms = lms * lms * lms;
  return vec3(
    dot(vec3(4.0767416621, -3.3077115913, 0.2309699292), lms),
    dot(vec3(-1.2684380046, 2.6097574011, -0.3413193965), lms),
    dot(vec3(-0.0041960863, -0.7034186147, 1.7076147010), lms));
}

bool inGamut(vec3 lch) {
  vec3 c = toRgb(lch);
  return all(greaterThanEqual(c, vec3(-0.0005))) && all(lessThanEqual(c, vec3(1.0005)));
}

// The profile's contrast and vibrance on an OKLCH colour, as
// ColorEngine._look: an S-curve on the lightness; the chroma scaled, most
// for weak colours and least in the water's hues, and brought back along
// the chroma when the colour leaves sRGB.
vec3 look(vec3 lch) {
  if (uContrast != 0.0) {
    float l = clamp(lch.x, 0.0, 1.0);
    lch.x = l + uContrast * (l * l * (3.0 - 2.0 * l) - l);
  }
  if (uVibrance == 0.0) {
    return lch;
  }
  float before = lch.y;
  float room = 1.0 - clamp(before / 0.3, 0.0, 1.0);
  float away = clamp((abs(lch.z - uWaterHue) - 0.07) / 0.10, 0.0, 1.0);
  float weight = 0.35 + 0.65 * away * away * (3.0 - 2.0 * away);
  float wanted = before * (1.0 + uVibrance * weight * room);
  if (inGamut(vec3(lch.x, wanted, lch.z))) {
    return vec3(lch.x, wanted, lch.z);
  }
  float low = before;
  float high = wanted;
  for (int i = 0; i < 6; i++) {
    float mid = (low + high) / 2.0;
    if (inGamut(vec3(lch.x, mid, lch.z))) {
      low = mid;
    } else {
      high = mid;
    }
  }
  return vec3(lch.x, low, lch.z);
}

void main() {
  // No flip on OpenGL ES: a picture given by setImageSampler comes the
  // right way up there too (tried on Windows, 2026-11-20; flipped, the
  // Color page's preview was upside down).
  vec2 uv = FlutterFragCoord().xy / uSize;
  // A picture with see-through parts is worked on as the engine reads it:
  // its colours as they are, without their alpha.
  vec4 source = texture(uImage, uv);
  vec3 original = toLinear(source.a > 0.0 ? clamp(source.rgb / source.a, 0.0, 1.0) : source.rgb);

  // Red and blue restored from green.
  vec3 v = original;
  v.r += uColorFactor.x * (1.0 - original.r) * original.g;
  v.b += uColorFactor.y * (1.0 - original.b) * original.g;
  // The black point off, then the balance.
  v = clamp((v - uBlackPoint) * uGreyWorld, 0.0, 1.0);
  // The dehaze curve, the exposure and the darkness.
  float high = max(v.r, max(v.g, v.b));
  float curve = high / uDehaze + 1.0 - high;
  v = clamp(uExposure * (curve * (v - 1.0) + 1.0), 0.0, 1.0);
  // The hue moved towards the reference water colour, less so for hues
  // away from blue.
  vec3 lch = toOklch(v);
  float damping = 1.0;
  if (lch.z > 0.81) {
    damping = 1.0 + (lch.z - 0.81) / 0.07;
  }
  if (lch.z < 0.65) {
    damping = 1.0 + (0.65 - lch.z) / 0.07;
  }
  damping = min(damping, 1.5);
  float hue = lch.z + uHueShift / damping;
  if (hue > 1.0) {
    hue -= 1.0;
  }
  if (hue < 0.0) {
    hue += 1.0;
  }
  lch.z = hue;
  if (uVibrance != 0.0 || uContrast != 0.0) {
    lch = look(lch);
  }
  v = clamp(toRgb(lch), 0.0, 1.0);
  if (uCif != 1.0) {
    // Mixed with the uncorrected pixel.
    v = v * uCif + original * (1.0 - uCif);
    v = clamp(toRgb(toOklch(v)), 0.0, 1.0);
  }
  fragColor = vec4(toSrgbByte(v), 1.0);
}
