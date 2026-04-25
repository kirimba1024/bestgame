#include "ShaderShared.h"

struct TerrainVertexIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
};

struct TerrainUniforms {
    float4x4 viewProj;
    float4x4 lightViewProj;
    float3 cameraPosWS;
    float time;
};

struct TerrainOut {
    float4 position [[position]];
    float3 posWS;
    float3 normalWS;
};

vertex TerrainOut terrain_vs(TerrainVertexIn in [[stage_in]],
                             constant TerrainUniforms& u [[buffer(1)]]) {
    TerrainOut out;
    float4 posWS4 = float4(in.position, 1.0);
    out.position = u.viewProj * posWS4;
    out.posWS = in.position;
    out.normalWS = normalize(in.normal);
    return out;
}

inline float3 biomeColor(float h, float slope01) {
    // WoW-like readability: strong bands + soft blends.
    float grassLine = 6.0;
    float rockLine = 18.0;
    float snowLine = 32.0;

    float3 grass = float3(0.13, 0.28, 0.11);
    float3 dirt  = float3(0.20, 0.16, 0.10);
    float3 rock  = float3(0.28, 0.28, 0.30);
    float3 snow  = float3(0.86, 0.88, 0.92);

    float g = smoothstep(grassLine - 2.0, grassLine + 2.0, h);
    float r = smoothstep(rockLine - 3.0, rockLine + 3.0, h);
    float s = smoothstep(snowLine - 3.0, snowLine + 3.0, h);

    float3 low = mix(dirt, grass, 0.65);
    float3 mid = mix(grass, rock, r);
    float3 high = mix(rock, snow, s);

    float3 base = (h < rockLine) ? mix(low, mid, g) : high;
    // Increase rock on steep slopes.
    float rockBoost = smoothstep(0.35, 0.75, slope01);
    base = mix(base, rock, rockBoost * 0.85);
    return base;
}

fragment float4 terrain_fs(TerrainOut in [[stage_in]],
                           constant TerrainUniforms& u [[buffer(0)]],
                           constant KeyLightUniforms& keyL [[buffer(4)]],
                           depth2d<float> shadowTex [[texture(0)]],
                           sampler shadowS [[sampler(0)]]) {
    float3 N = normalize(in.normalWS);
    float3 Lsun = (length(keyL.dirWS) > 1e-5) ? normalize(keyL.dirWS) : kSunDirFallback;

    float slope01 = saturate(1.0 - N.y);
    float h = in.posWS.y;
    float3 albedo = biomeColor(h, slope01);

    // Cheap, stable lighting tuned for readability.
    float ndl = saturate(dot(N, Lsun));
    float3 sunRad = (length(keyL.radianceLinear) > 1e-8) ? keyL.radianceLinear : float3(1.12, 1.08, 1.02);
    float shadow = 1.0;
    if (shadowTex.get_width() > 0) {
        float4 sp = u.lightViewProj * float4(in.posWS, 1.0);
        sp.xyz /= max(1e-6, sp.w);
        float2 suv = float2(sp.x * 0.5 + 0.5, 0.5 - sp.y * 0.5);
        float sz = sp.z;
        if (all(suv >= float2(0.0)) && all(suv <= float2(1.0)) && sz >= 0.0 && sz <= 1.0) {
            // Slightly larger bias to avoid banding/acne on large smooth surfaces.
            float bias = max(0.0018, 0.0100 * (1.0 - ndl));
            float cmpZ = sz - bias;
            float2 texel = 1.0 / float2(shadowTex.get_width(), shadowTex.get_height());
            float sum = 0.0;
            // Wider PCF for less shimmering on large surfaces.
            for (int y = -2; y <= 2; ++y) {
                for (int x = -2; x <= 2; ++x) {
                    sum += shadowTex.sample_compare(shadowS, suv + float2(x, y) * texel, cmpZ);
                }
            }
            shadow = sum / 25.0;
        }
    }
    // Avoid overly dark banding on terrain; keep contact shadows but lift the floor.
    shadow = clamp(shadow, 0.55, 1.0);

    float3 direct = albedo * sunRad * (0.22 + 0.78 * ndl) * shadow;

    float hemi = saturate(N.y * 0.5 + 0.5);
    float3 amb = albedo * mix(float3(0.020, 0.022, 0.028), float3(0.070, 0.080, 0.095), hemi);

    // Subtle distance fog (matches PBR fog vibe).
    float dist = length(in.posWS - u.cameraPosWS);
    float fogStart = 85.0;
    float fogEnd = 520.0;
    float t = saturate((dist - fogStart) / max(1e-3, (fogEnd - fogStart)));
    float fogDensity = 0.018;
    float fog = (1.0 - exp(-fogDensity * max(0.0, dist - fogStart))) * t;
    float3 fogCol = skyColor(normalize(in.posWS - u.cameraPosWS), Lsun, keyL.skyDiskRadianceHDR);

    float3 color = direct + amb;
    color = mix(color, fogCol, saturate(fog) * 0.78);
    color = ACESFilm(color);
    return float4(color, 1.0);
}

