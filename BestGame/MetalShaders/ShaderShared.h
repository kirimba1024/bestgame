#ifndef BESTGAME_SHADER_SHARED_H
#define BESTGAME_SHADER_SHARED_H

#include <metal_stdlib>
using namespace metal;

// -----------------------------------------------------------------------------
// Общие константы и типы для всех .metal-юнитов (синхрон с CPU: SceneLighting).
// -----------------------------------------------------------------------------
constant float3 kSunDirFallback = float3(0.3675, 0.8898, 0.2707);

struct KeyLightUniforms {
    float3 dirWS;
    float _p0;
    float3 radianceLinear;
    float _p1;
    float3 skyDiskRadianceHDR;
    float _p2;
};

struct VertexIn {
    float3 position [[attribute(0)]];
    float3 color    [[attribute(1)]];
};

struct Uniforms {
    float4x4 mvp;
};

struct VertexOut {
    float4 position [[position]];
    float3 color;
};

struct SkinnedVertexIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
    float2 uv       [[attribute(2)]];
    ushort4 joints  [[attribute(3)]];
    float4 weights  [[attribute(4)]];
};

struct PBRUniforms {
    float4x4 mvp;
    float4x4 model;
    float4x4 normalMatrix;
    float4x4 lightViewProj;
    float3 cameraPosWS;
    uint jointCount;
    float4 baseColorFactor;
    float metallicFactor;
    float roughnessFactor;
    float exposure;
    uint debugMode;
    float3 _pad;
};

// Instanced variant for static foliage/props.
// Assumes uniform scale (normals use model's upper-left 3x3).
struct PBRInstancedUniforms {
    float4x4 viewProj;
    float4x4 lightViewProj;
    float3 cameraPosWS;
    uint _p0;
    float4 baseColorFactor;
    float metallicFactor;
    float roughnessFactor;
    float exposure;
    uint debugMode;
    float3 _pad;
};

struct PBRVertexOut {
    float4 position [[position]];
    float2 uv;
    float3 normalWS;
    float3 posWS;
};

struct FSOut {
    float4 position [[position]];
    float2 uv;
};

struct SkyUniforms {
    float4x4 invViewProj;
    float3 cameraPosWS;
    float _pad0;
    float3 sunDirWS;
    float _pad1;
    float3 sunDiskRadianceHDR;
    float _pad2;
};

struct StaticVertexIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
    float2 uv       [[attribute(2)]];
};

struct ShadowUniforms {
    float4x4 lightViewProj;
    float4x4 model;
    uint jointCount;
    float3 _pad0;
};

struct ShadowInstancedUniforms {
    float4x4 lightViewProj;
};

inline float3 skyColor(float3 dir, float3 sunDirWS, float3 sunDiskRadianceHDR) {
    dir = normalize(dir);
    float3 sunD = normalize(sunDirWS);
    float3 sunDisk = sunDiskRadianceHDR;
    float sky = saturate(dir.y * 0.5 + 0.5);
    float3 zenith = float3(0.08, 0.12, 0.22);
    float3 horizon = float3(0.20, 0.26, 0.34);
    float3 ground = float3(0.02, 0.02, 0.025);
    float3 base = (dir.y >= 0.0) ? mix(horizon, zenith, sky) : mix(horizon * 0.25, ground, saturate(-dir.y));

    float sunDot = saturate(dot(dir, sunD));
    float disk = smoothstep(0.9994, 0.9999, sunDot);
    float halo = smoothstep(0.97, 0.9994, sunDot) * 0.08;
    return base + sunDisk * (disk + halo);
}

inline float pow5(float x) { float x2 = x*x; return x2*x2*x; }

inline float3 fresnelSchlick(float cosTheta, float3 F0) {
    return F0 + (1.0 - F0) * pow5(1.0 - cosTheta);
}

inline float D_GGX(float NdotH, float alpha) {
    float a2 = alpha * alpha;
    float d = (NdotH * NdotH) * (a2 - 1.0) + 1.0;
    return a2 / max(1e-6, (M_PI_F * d * d));
}

inline float G_SchlickGGX(float NdotV, float k) {
    return NdotV / max(1e-6, (NdotV * (1.0 - k) + k));
}

inline float G_Smith(float NdotV, float NdotL, float k) {
    return G_SchlickGGX(NdotV, k) * G_SchlickGGX(NdotL, k);
}

inline float2 envBRDFApprox(float roughness, float NdotV) {
    const float4 c0 = float4(-1.0, -0.0275, -0.572, 0.022);
    const float4 c1 = float4( 1.0,  0.0425,  1.04, -0.04);
    float4 r = roughness * c0 + c1;
    float a004 = min(r.x * r.x, exp2(-9.28 * NdotV)) * r.x + r.y;
    return float2(-1.04, 1.04) * a004 + r.zw;
}

inline float3 ACESFilm(float3 x) {
    x *= 0.6;
    float a = 2.51;
    float b = 0.03;
    float c = 2.43;
    float d = 0.59;
    float e = 0.14;
    return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
}

inline float3 pbr_mr_direct(float3 N, float3 V, float3 L, float3 radiance,
                            float3 albedo, float metallic, float roughness) {
    float NdotL = saturate(dot(N, L));
    if (NdotL <= 1e-6) {
        return float3(0.0);
    }

    float3 H = normalize(V + L);
    float NdotV = saturate(dot(N, V));
    float NdotH = saturate(dot(N, H));
    float VdotH = saturate(dot(V, H));

    float3 F0 = mix(float3(0.04), albedo, metallic);
    float alpha = roughness * roughness;
    float D = D_GGX(NdotH, alpha);
    float k = (roughness + 1.0);
    k = (k * k) / 8.0;
    float G = G_Smith(NdotV, NdotL, k);
    float3 F = fresnelSchlick(VdotH, F0);

    float3 numerator = D * G * F;
    float denom = max(1e-6, (4.0 * NdotV * NdotL));
    float3 spec = numerator / denom;

    float3 kd = (1.0 - F) * (1.0 - metallic);
    float3 diff = kd * albedo / M_PI_F;

    float specScale = mix(0.06, 1.0, metallic);
    return (diff + spec * specScale) * radiance * NdotL;
}

inline float2 equirectUVFromDir(float3 d) {
    d = normalize(d);
    float phi = atan2(d.x, d.z);
    float theta = acos(clamp(d.y, -1.0, 1.0));
    float u = (phi + M_PI_F) / (2.0 * M_PI_F);
    float v = theta / M_PI_F;
    return float2(u, v);
}

#endif /* BESTGAME_SHADER_SHARED_H */
