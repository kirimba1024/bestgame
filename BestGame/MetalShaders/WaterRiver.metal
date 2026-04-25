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
    float4x4 invViewProj;
    float4x4 model;
    float4x4 normalMatrix;
    float4 camAndTime;
    float4 sunAndFlow;
    float foamStrength;
    float3 _pad0;
    float4 nearFarInvWInvH;
};

struct WaterVertexOut {
    float4 position [[position]];
    float3 worldPos;
    float3 normalWS;
    float4 clipPos;
};

// Depth buffer is not a color signal; nearest can cause visible macro-blocks when used for thickness/foam.
// We use linear + small gather to reduce “squares” on close-up water.
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
    // Use clip-space UV, not `in.position`, to avoid blocky artifacts when drawable/depth resolutions differ.
    float3 ndc = in.clipPos.xyz / max(1e-6, in.clipPos.w);
    float2 uv = float2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
    float2 depthSize = float2(sceneDepth.get_width(), sceneDepth.get_height());
    float2 texel = 1.0 / depthSize;

    // Temporal stability: snap depth sampling to pixel centers.
    float2 px = uv * depthSize;
    uv = (floor(px) + 0.5) * texel;
    // Small 2x2 gather to suppress block artifacts near the camera.
    float sceneD =
        0.25 * (
            sceneDepth.sample(kDepthSampler, uv + texel * float2(-0.25, -0.25)) +
            sceneDepth.sample(kDepthSampler, uv + texel * float2( 0.25, -0.25)) +
            sceneDepth.sample(kDepthSampler, uv + texel * float2(-0.25,  0.25)) +
            sceneDepth.sample(kDepthSampler, uv + texel * float2( 0.25,  0.25))
        );

    // Reconstruct scene world position from depth (more stable than clip-depth heuristics).
    float2 ndcXY = float2(uv.x * 2.0 - 1.0, (1.0 - uv.y) * 2.0 - 1.0);
    float4 clip = float4(ndcXY, sceneD, 1.0);
    float4 ws4 = u.invViewProj * clip;
    float3 scenePosWS = ws4.xyz / max(1e-6, ws4.w);

    float3 Vdir = normalize(in.worldPos - u.camAndTime.xyz);
    float thicknessM = max(0.0, dot(scenePosWS - in.worldPos, Vdir));
    // Clamp to a sane range for stability.
    thicknessM = clamp(thicknessM, 0.0, 25.0);
    float thickness01 = saturate(thicknessM / 6.0);

    // Foam: strongest at intersections (thin water). Use derivatives for stability.
    float fw = max(0.001, fwidth(thicknessM));
    float foam = 1.0 - smoothstep(0.08 - fw, 0.08 + fw, thicknessM);
    foam *= foam;
    foam *= saturate(u.foamStrength);

    float3 N = normalize(in.normalWS);
    float3 V = normalize(u.camAndTime.xyz - in.worldPos);
    float3 Lsun = (length(keyL.dirWS) > 1e-5) ? normalize(keyL.dirWS) : kSunDirFallback;
    float3 sunDiskHDR = (length(keyL.skyDiskRadianceHDR) > 1e-5) ? keyL.skyDiskRadianceHDR : float3(6.0, 5.7, 5.1);

    // Specular AA: high-frequency normals + high exponent cause shimmering close to the water.
    // Use normal derivatives to widen the lobe in screen-space.
    float nVar = length(fwidth(N));
    float aa = saturate(nVar * 6.0); // tuned: 0..1
    float3 Nf = normalize(mix(N, float3(0.0, 1.0, 0.0), aa * 0.55));

    float NdotV = saturate(dot(Nf, V));
    float3 F0 = float3(0.02);
    float3 F = fresnelSchlick(NdotV, F0);

    float3 R = reflect(-V, Nf);
    float2 uvR = equirectUVFromDir(normalize(R));
    int envMip = max(0, int(envTex.get_num_mip_levels()) - 4);
    float3 refl = envTex.sample(kEnvSampler, uvR, level(envMip)).rgb;

    float3 deep = float3(0.02, 0.08, 0.12);
    float3 shallow = float3(0.07, 0.25, 0.30);
    float facing = pow(saturate(N.y * 0.5 + 0.5), 1.4);
    float3 baseFacing = mix(deep, shallow, facing);
    // More shallow tint when thickness is small (i.e. bottom is close).
    float3 base = mix(shallow, baseFacing, thickness01);

    float shininess = mix(64.0, 18.0, aa);
    float sunGlint = pow(saturate(dot(R, Lsun)), shininess);
    float3 specSun = sunDiskHDR * sunGlint * 0.018;

    float wrap = saturate(dot(N, Lsun) * 0.5 + 0.5);
    float3 diffSun = base * wrap * float3(0.35, 0.42, 0.38);

    // Beer-Lambert style absorption: thickness in meters.
    float3 absorb = float3(0.22, 0.10, 0.06);
    float3 transmitCol = exp(-absorb * thicknessM);
    float3 transmit = (base * 0.55 + diffSun) * transmitCol;

    float3 col = transmit;
    col = mix(col, refl, F * 0.85);
    col += specSun * F;

    float3 foamCol = float3(0.92, 0.95, 1.0);
    col = mix(col, foamCol, foam * 0.55);

    // Alpha: shallow => more transparent, deep => less.
    float alphaDepth = mix(0.22, 0.80, thickness01);
    float alpha = mix(alphaDepth, 0.94, foam * 0.45) * (0.78 + 0.22 * NdotV);
    alpha = saturate(alpha);

    return float4(col, alpha);
}
