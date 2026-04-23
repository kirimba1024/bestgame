#include <metal_stdlib>
using namespace metal;

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

vertex VertexOut vertex_main(VertexIn in [[stage_in]],
                             constant Uniforms& u [[buffer(1)]]) {
    VertexOut out;
    out.position = u.mvp * float4(in.position, 1.0);
    out.color = in.color;
    return out;
}

fragment float4 fragment_main(VertexOut in [[stage_in]]) {
    return float4(in.color, 1.0);
}

// --- glTF pipeline (skinned + PBR MR, plus static PBR MR) ---

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
    float3 cameraPosWS;
    uint jointCount;
    float4 baseColorFactor;
    float metallicFactor;
    float roughnessFactor;
    float2 _pad;
};

struct PBRVertexOut {
    float4 position [[position]];
    float2 uv;
    float3 normalWS;
    float3 posWS;
};

vertex PBRVertexOut vertex_skinned(SkinnedVertexIn in [[stage_in]],
                                       constant PBRUniforms& u [[buffer(1)]],
                                       const device float4x4* jointMats [[buffer(2)]]) {
    // Linear blend skinning in object space.
    float4 p = float4(in.position, 1.0);
    float3 n = in.normal;

    float4 skinnedP = float4(0.0);
    float3 skinnedN = float3(0.0);

    ushort4 j = in.joints;
    float4 w = in.weights;

    // Clamp joint indices to range (defensive).
    uint jc = max(u.jointCount, 1u);
    uint j0 = min(uint(j.x), jc - 1u);
    uint j1 = min(uint(j.y), jc - 1u);
    uint j2 = min(uint(j.z), jc - 1u);
    uint j3 = min(uint(j.w), jc - 1u);

    float4x4 m0 = jointMats[j0];
    float4x4 m1 = jointMats[j1];
    float4x4 m2 = jointMats[j2];
    float4x4 m3 = jointMats[j3];

    skinnedP += (m0 * p) * w.x;
    skinnedP += (m1 * p) * w.y;
    skinnedP += (m2 * p) * w.z;
    skinnedP += (m3 * p) * w.w;

    float3x3 n0 = float3x3(m0[0].xyz, m0[1].xyz, m0[2].xyz);
    float3x3 n1 = float3x3(m1[0].xyz, m1[1].xyz, m1[2].xyz);
    float3x3 n2 = float3x3(m2[0].xyz, m2[1].xyz, m2[2].xyz);
    float3x3 n3 = float3x3(m3[0].xyz, m3[1].xyz, m3[2].xyz);
    skinnedN += (n0 * n) * w.x;
    skinnedN += (n1 * n) * w.y;
    skinnedN += (n2 * n) * w.z;
    skinnedN += (n3 * n) * w.w;

    float4 posWS4 = u.model * skinnedP;

    PBRVertexOut out;
    out.position = u.mvp * skinnedP;
    out.uv = in.uv;
    out.normalWS = normalize((float3x3(u.model[0].xyz, u.model[1].xyz, u.model[2].xyz) * skinnedN));
    out.posWS = posWS4.xyz / max(1e-8, posWS4.w);
    return out;
}

struct StaticVertexIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
    float2 uv       [[attribute(2)]];
};

vertex PBRVertexOut vertex_static_pbr(StaticVertexIn in [[stage_in]],
                                      constant PBRUniforms& u [[buffer(1)]]) {
    float4 posOS = float4(in.position, 1.0);
    float4 posWS4 = u.model * posOS;

    PBRVertexOut out;
    out.position = u.mvp * posOS;
    out.uv = in.uv;
    out.normalWS = normalize((float3x3(u.model[0].xyz, u.model[1].xyz, u.model[2].xyz) * in.normal));
    out.posWS = posWS4.xyz / max(1e-8, posWS4.w);
    return out;
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

/// Один направленный источник (Cook-Torrance / glTF-style MR).
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

    return (diff + spec) * radiance * NdotL;
}

fragment float4 fragment_pbr_mr(PBRVertexOut in [[stage_in]],
                                constant PBRUniforms& u [[buffer(0)]],
                                texture2d<float> baseColorTex [[texture(0)]],
                                texture2d<float> mrTex [[texture(1)]],
                                sampler s [[sampler(0)]]) {
    float4 base = u.baseColorFactor;
    if (baseColorTex.get_width() > 0) {
        base *= baseColorTex.sample(s, in.uv);
    }

    float metallic = u.metallicFactor;
    float roughness = u.roughnessFactor;
    if (mrTex.get_width() > 0) {
        float4 mr = mrTex.sample(s, in.uv);
        // glTF: roughness in G, metallic in B
        roughness *= mr.g;
        metallic *= mr.b;
    }
    roughness = clamp(roughness, 0.04, 1.0);
    metallic = clamp(metallic, 0.0, 1.0);

    float3 N = normalize(in.normalWS);
    float3 V = normalize(u.cameraPosWS - in.posWS);
    float3 albedo = base.rgb;

    // Ключ + заполняющий свет (без IBL металлика сильно «проваливается» в тень).
    float3 L0 = normalize(float3(0.38, 0.92, 0.28));
    float3 L1 = normalize(float3(-0.72, 0.35, -0.55));
    float3 rad0 = float3(1.28, 1.24, 1.18);
    float3 rad1 = float3(0.24, 0.26, 0.32);

    float3 color = pbr_mr_direct(N, V, L0, rad0, albedo, metallic, roughness)
                 + pbr_mr_direct(N, V, L1, rad1, albedo, metallic, roughness);

    // Диффузное «небо» (диэлектрики и краска на металле).
    float sky = saturate(N.y * 0.5 + 0.5);
    float3 ambLow = float3(0.035, 0.037, 0.042);
    float3 ambHigh = float3(0.10, 0.105, 0.115);
    float3 ambDiff = albedo * mix(ambLow, ambHigh, sky);
    color += ambDiff * (0.55 + 0.45 * (1.0 - metallic));

    // Без IBL чистый металлик почти не даёт диффуза — добавляем грубую «заливку»
    // от воображаемого окружения по Fresnel(N·V), иначе остаются только узкие блики.
    float nv = saturate(dot(N, V));
    float3 F0 = mix(float3(0.04), albedo, metallic);
    float3 Fnv = fresnelSchlick(nv, F0);
    float3 envCol = mix(float3(0.20, 0.21, 0.24), float3(0.58, 0.60, 0.64), sky);
    float envAmt = (0.12 + 0.88 * metallic)
        * (0.22 + 0.78 * saturate(1.0 - roughness));
    color += envCol * Fnv * envAmt;

    // Мягкий омни-свет (не физичен, но убирает «космическую» тень с тыльных граней).
    float wrap = saturate((dot(N, L0) + 0.35) / 1.35);
    color += albedo * float3(0.045, 0.046, 0.048) * wrap * (0.35 + 0.65 * (1.0 - metallic));

    return float4(color, base.a);
}

