#include <metal_stdlib>
#include "ShaderShared.h"
using namespace metal;

// Река: сетка + процедурные волны (VS), Френель + IBL-отражение, пена по сравнению с depth буфера.
// Один проход, без захвата цвета сцены — «рефракция» имитацией затемнения дна.

struct WaterVertexIn {
    float3 position [[attribute(0)]];
    float2 uv [[attribute(1)]];
};

struct WaterUniforms {
    float4x4 viewProj;
    float4x4 model;
    float4x4 normalMatrix;
    float4 camAndTime;
    float4 sunAndFlow;
    float4 nearFarInvWInvH;
};

struct WaterVertexOut {
    float4 position [[position]];
    float3 worldPos;
    float3 normalWS;
    float4 clipPos;
};

constexpr sampler kDepthSampler(coord::normalized, filter::linear, address::clamp_to_edge);
constexpr sampler kEnvSampler(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear);

inline float3 waterWaveNormal(float2 xz, float t, float flow) {
    float2 w = xz * 42.0;
    float e = 0.04;
    float hx = sin((w.x + e * 42.0) * 1.05 + t * 1.85 + flow * 2.2) - sin((w.x - e * 42.0) * 1.05 + t * 1.85 + flow * 2.2);
    float hz = sin((w.y + e * 42.0) * 0.92 - t * 1.35 + flow) - sin((w.y - e * 42.0) * 0.92 - t * 1.35 + flow);
    float amp = 0.055;
    float3 n = float3(-hx * amp * 0.5, 1.0, -hz * amp * 0.5);
    return normalize(n);
}

vertex WaterVertexOut water_river_vs(
    WaterVertexIn in [[stage_in]],
    constant WaterUniforms& u [[buffer(1)]]
) {
    WaterVertexOut out;
    float t = u.camAndTime.w;
    float flow = u.sunAndFlow.w;
    float2 xz = in.position.xz;
    float h =
        sin(xz.x * 38.0 + t * 1.9 + flow) * 0.45
        + sin(xz.y * 31.0 - t * 1.55 + flow * 0.7) * 0.35
        + sin((xz.x + xz.y) * 22.0 + t * 2.2) * 0.2;
    h *= 0.052;
    float3 posOS = float3(in.position.x, in.position.y + h, in.position.z);
    float4 world4 = u.model * float4(posOS, 1.0);
    out.worldPos = world4.xyz / max(1e-6, world4.w);
    float3x3 nmat = float3x3(
        u.normalMatrix[0].xyz,
        u.normalMatrix[1].xyz,
        u.normalMatrix[2].xyz
    );
    float3 nOS = waterWaveNormal(xz, t, flow);
    out.normalWS = normalize(nmat * nOS);
    float4 clip = u.viewProj * world4;
    out.clipPos = clip;
    out.position = clip;
    return out;
}

fragment float4 water_river_fs(
    WaterVertexOut in [[stage_in]],
    constant WaterUniforms& u [[buffer(0)]],
    constant KeyLightUniforms& keyL [[buffer(1)]],
    depth2d<float> sceneDepth [[texture(0)]],
    texture2d<float> envTex [[texture(1)]]
) {
    float invW = u.nearFarInvWInvH.z;
    float invH = u.nearFarInvWInvH.w;

    float2 uv = float2(in.position.x * invW, in.position.y * invH);
    float sceneD = sceneDepth.sample(kDepthSampler, uv);

    float waterD = in.clipPos.z / max(1e-6, in.clipPos.w);
    float foamEdge = saturate(abs(sceneD - waterD) * 95.0);
    float foam = (1.0 - foamEdge) * (1.0 - foamEdge);

    float3 N = normalize(in.normalWS);
    float3 V = normalize(u.camAndTime.xyz - in.worldPos);
    float3 Lsun = (length(keyL.dirWS) > 1e-5) ? normalize(keyL.dirWS) : kSunDirFallback;
    float3 sunDiskHDR = (length(keyL.skyDiskRadianceHDR) > 1e-5) ? keyL.skyDiskRadianceHDR : float3(6.0, 5.7, 5.1);

    float NdotV = saturate(dot(N, V));
    float3 F0 = float3(0.02);
    float3 F = fresnelSchlick(NdotV, F0);

    float3 R = reflect(-V, N);
    float2 uvR = equirectUVFromDir(normalize(R));
    int envMip = max(0, int(envTex.get_num_mip_levels()) - 4);
    float3 refl = envTex.sample(kEnvSampler, uvR, level(envMip)).rgb;

    float3 deep = float3(0.02, 0.08, 0.12);
    float3 shallow = float3(0.06, 0.22, 0.28);
    float3 base = mix(deep, shallow, pow(saturate(N.y * 0.5 + 0.5), 1.4));

    float sunGlint = pow(saturate(dot(R, Lsun)), 64.0);
    float3 specSun = sunDiskHDR * sunGlint * 0.018;

    float wrap = saturate(dot(N, Lsun) * 0.5 + 0.5);
    float3 diffSun = base * wrap * float3(0.35, 0.42, 0.38);

    float3 col = base * 0.35 + diffSun;
    col = mix(col, refl, F * 0.85);
    col += specSun * F;

    float3 foamCol = float3(0.92, 0.95, 1.0);
    col = mix(col, foamCol, foam * 0.55);

    float alpha = mix(0.72, 0.94, foam * 0.35 + NdotV * 0.15);
    alpha = saturate(alpha);

    return float4(col, alpha);
}
