#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Glowing voice ribbon for the dictionary recording step.
// phase moves the strands; energy (0...1) is the smoothed microphone level.
[[ stitchable ]] half4 dictionaryVoiceWave(float2 position, half4 color, float2 size, float phase, float energy, float dark) {
    float x = position.x / size.x;
    float y = position.y - size.y * 0.5;

    // Strands fade in and out at both ends instead of stopping at a hard edge.
    float ends = smoothstep(0.0, 0.18, x) * smoothstep(1.0, 0.82, x);
    float envelope = sin(M_PI_F * x);

    float3 cyan = float3(0.25, 0.92, 1.0);
    float3 blue = float3(0.18, 0.48, 1.0);
    float3 violet = float3(0.58, 0.36, 1.0);
    float3 tint = x < 0.5 ? mix(cyan, blue, x * 2.0) : mix(blue, violet, (x - 0.5) * 2.0);

    float amplitude = size.y * (0.26 + 0.14 * energy);
    float glowWidth = 9.0 + 6.0 * energy;
    float3 light = float3(0.0);
    float hot = 0.0;

    for (int i = 0; i < 5; i++) {
        float f = float(i);
        float strandPhase = phase * (0.8 + 0.23 * f) + f * 1.9;
        float frequency = 0.85 + 0.3 * f;
        float wobble = 1.0 + 0.25 * sin(phase * 0.6 + f * 2.3);
        float strandY = amplitude * (1.0 - 0.17 * f) * wobble * envelope * sin(2.0 * M_PI_F * frequency * x + strandPhase);
        float d = abs(y - strandY);
        float weight = i == 0 ? 1.0 : 0.5 - 0.06 * f;
        float core = exp(-d * d / (2.0 * 1.1 * 1.1));
        float glow = exp(-d / glowWidth);
        light += tint * (core * 1.2 + glow * (0.5 + 0.15 * energy)) * weight;
        if (i == 0) { hot = core; }
    }

    // Soft bloom behind the middle of the ribbon, stronger while speaking.
    float2 centre = float2((x - 0.5) * 2.2, y / (size.y * 0.5));
    float bloom = exp(-dot(centre, centre) * 2.2) * (0.22 + 0.12 * energy);
    light += mix(blue, cyan, 0.4) * bloom;

    light += float3(1.0) * hot * (dark > 0.5 ? 0.75 : 0.25) ;
    light *= ends;

    float alpha = saturate(max(light.r, max(light.g, light.b)));
    float3 rgb = min(light, float3(alpha));
    return half4(half3(rgb), half(alpha));
}
