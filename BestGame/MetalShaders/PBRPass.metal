#include "ShaderShared.h"

vertex PBRVertexOut vertex_skinned(SkinnedVertexIn in [[stage_in]],
                                   constant PBRUniforms& u [[buffer(1)]],
                                   const device float4x4* jointMats [[buffer(2)]]) {
    float4 p = float4(in.position, 1.0);
    float3 n = in.normal;

    float4 skinnedP = float4(0.0);
    float3 skinnedN = float3(0.0);

    ushort4 j = in.joints;
    float4 w = in.weights;

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

    float3x3 R0 = float3x3(m0[0].xyz, m0[1].xyz, m0[2].xyz);
    float3x3 R1 = float3x3(m1[0].xyz, m1[1].xyz, m1[2].xyz);
    float3x3 R2 = float3x3(m2[0].xyz, m2[1].xyz, m2[2].xyz);
    float3x3 R3 = float3x3(m3[0].xyz, m3[1].xyz, m3[2].xyz);
    skinnedN += (R0 * n) * w.x + (R1 * n) * w.y + (R2 * n) * w.z + (R3 * n) * w.w;

    float4 posWS4 = u.model * skinnedP;

    PBRVertexOut out;
    out.position = u.mvp * skinnedP;
    out.uv = in.uv;
    float3x3 nmat = float3x3(u.normalMatrix[0].xyz, u.normalMatrix[1].xyz, u.normalMatrix[2].xyz);
    out.normalWS = normalize(nmat * skinnedN);
    out.posWS = posWS4.xyz / max(1e-8, posWS4.w);
    return out;
}

vertex float4 vertex_shadow_static(StaticVertexIn in [[stage_in]],
                                   constant ShadowUniforms& u [[buffer(1)]]) {
    float4 posWS = u.model * float4(in.position, 1.0);
    return u.lightViewProj * posWS;
}

vertex float4 vertex_shadow_static_instanced(StaticVertexIn in [[stage_in]],
                                             constant ShadowInstancedUniforms& u [[buffer(1)]],
                                             const device float4x4* models [[buffer(2)]],
                                             uint iid [[instance_id]]) {
    float4 posWS = models[iid] * float4(in.position, 1.0);
    return u.lightViewProj * posWS;
}

vertex float4 vertex_shadow_skinned(SkinnedVertexIn in [[stage_in]],
                                    constant ShadowUniforms& u [[buffer(1)]],
                                    const device float4x4* jointMats [[buffer(2)]]) {
    float4 p = float4(in.position, 1.0);
    float4 skinnedP = float4(0.0);

    ushort4 j = in.joints;
    float4 w = in.weights;
    uint jc = max(u.jointCount, 1u);
    uint j0 = min(uint(j.x), jc - 1u);
    uint j1 = min(uint(j.y), jc - 1u);
    uint j2 = min(uint(j.z), jc - 1u);
    uint j3 = min(uint(j.w), jc - 1u);

    skinnedP += (jointMats[j0] * p) * w.x;
    skinnedP += (jointMats[j1] * p) * w.y;
    skinnedP += (jointMats[j2] * p) * w.z;
    skinnedP += (jointMats[j3] * p) * w.w;

    float4 posWS = u.model * skinnedP;
    return u.lightViewProj * posWS;
}

vertex PBRVertexOut vertex_static_pbr(StaticVertexIn in [[stage_in]],
                                      constant PBRUniforms& u [[buffer(1)]]) {
    float4 posOS = float4(in.position, 1.0);
    float4 posWS4 = u.model * posOS;

    PBRVertexOut out;
    out.position = u.mvp * posOS;
    out.uv = in.uv;
    float3x3 nmat = float3x3(u.normalMatrix[0].xyz, u.normalMatrix[1].xyz, u.normalMatrix[2].xyz);
    out.normalWS = normalize(nmat * in.normal);
    out.posWS = posWS4.xyz / max(1e-8, posWS4.w);
    return out;
}

vertex PBRVertexOut vertex_static_pbr_instanced(StaticVertexIn in [[stage_in]],
                                                constant PBRInstancedUniforms& u [[buffer(1)]],
                                                const device float4x4* models [[buffer(2)]],
                                                uint iid [[instance_id]]) {
    float4 posOS = float4(in.position, 1.0);
    float4x4 M = models[iid];
    float4 posWS4 = M * posOS;

    PBRVertexOut out;
    out.position = u.viewProj * posWS4;
    out.uv = in.uv;
    float3x3 R = float3x3(M[0].xyz, M[1].xyz, M[2].xyz);
    out.normalWS = normalize(R * in.normal);
    out.posWS = posWS4.xyz / max(1e-8, posWS4.w);
    return out;
}

fragment float4 fragment_pbr_mr(PBRVertexOut in [[stage_in]],
                              constant PBRUniforms& u [[buffer(0)]],
                              constant KeyLightUniforms& keyL [[buffer(4)]],
                              texture2d<float> baseColorTex [[texture(0)]],
                              texture2d<float> mrTex [[texture(1)]],
                              texture2d<float> envTex [[texture(2)]],
                              depth2d<float> shadowTex [[texture(3)]],
                              sampler s [[sampler(0)]],
                              sampler envS [[sampler(1)]],
                              sampler shadowS [[sampler(2)]]) {
    float4 base = u.baseColorFactor;
    if (baseColorTex.get_width() > 0) {
        base *= baseColorTex.sample(s, in.uv);
    }

    float metallic = u.metallicFactor;
    float roughness = u.roughnessFactor;
    if (mrTex.get_width() > 0) {
        float4 mr = mrTex.sample(s, in.uv);
        roughness *= mr.g;
        metallic *= mr.b;
    }
    roughness = clamp(roughness, 0.04, 1.0);
    metallic = clamp(metallic, 0.0, 1.0);
    float roughEff = max(roughness, (1.0 - metallic) * 0.42);

    float3 N = normalize(in.normalWS);
    float3 V = normalize(u.cameraPosWS - in.posWS);
    float3 albedo = base.rgb;

    float3 Lsun = (length(keyL.dirWS) > 1e-5) ? normalize(keyL.dirWS) : kSunDirFallback;
    float3 sunRad = (length(keyL.radianceLinear) > 1e-8) ? keyL.radianceLinear : float3(1.12, 1.08, 1.02);
    float3 sunDiskHDR = (length(keyL.skyDiskRadianceHDR) > 1e-5) ? keyL.skyDiskRadianceHDR : float3(6.0, 5.7, 5.1);

    float3 sunRadEff = sunRad * mix(1.0, 1.22, metallic);
    float3 directSun = pbr_mr_direct(N, V, Lsun, sunRadEff, albedo, metallic, roughEff);

    float shadow = 1.0;
    if (shadowTex.get_width() > 0) {
        float4 sp = u.lightViewProj * float4(in.posWS, 1.0);
        sp.xyz /= max(1e-6, sp.w);
        float2 suv = float2(sp.x * 0.5 + 0.5, 0.5 - sp.y * 0.5);
        float sz = sp.z;

        if (all(suv >= float2(0.0)) && all(suv <= float2(1.0)) && sz >= 0.0 && sz <= 1.0) {
            float NdotL = saturate(dot(N, Lsun));
            float bias = max(0.0008, 0.0035 * (1.0 - NdotL));
            float cmpZ = sz - bias;

            float2 texel = 1.0 / float2(shadowTex.get_width(), shadowTex.get_height());
            float sum = 0.0;
            for (int y = -1; y <= 1; ++y) {
                for (int x = -1; x <= 1; ++x) {
                    float2 o = float2(x, y) * texel;
                    sum += shadowTex.sample_compare(shadowS, suv + o, cmpZ);
                }
            }
            shadow = sum / 9.0;
        }
    }

    float3 color = directSun * shadow;

    if (u.debugMode == 1u) {
        return float4(shadow, shadow, shadow, 1.0);
    }

    if (envTex.get_width() > 0) {
        float NdotV = saturate(dot(N, V));

        float2 uvN = equirectUVFromDir(N);
        float3 irradiance = envTex.sample(envS, uvN).rgb;

        float3 R = reflect(-V, N);
        float3 Rn = normalize(R);
        float2 uvR = equirectUVFromDir(R);
        float mip = roughEff * float(envTex.get_num_mip_levels() - 1);
        float3 prefiltered = envTex.sample(envS, uvR, level(mip)).rgb;

        float3 F0 = mix(float3(0.04), albedo, metallic);
        float2 brdf = envBRDFApprox(roughEff, NdotV);
        float3 FrSpec = F0 * brdf.x + brdf.y;
        float3 specIBL = prefiltered * FrSpec;
        specIBL *= mix(0.10, 0.14, metallic);

        float sunAlignR = saturate(dot(Rn, Lsun));
        float r2 = max(0.03, roughEff * roughEff);
        float reflSunExp = min(220.0, 1.0 / r2);
        float sunBlob = pow(sunAlignR, reflSunExp);
        float3 reflSunKey = sunDiskHDR * sunBlob * FrSpec * metallic;
        float reflSunGain = mix(0.020, 0.032, roughEff);

        float3 kd = (1.0 - metallic);
        float3 diffIBL = irradiance * albedo / M_PI_F;
        float sunFacing = saturate(dot(N, Lsun));
        float diffIBLWrap = 0.58 + 0.42 * sunFacing;

        color += diffIBL * kd * 0.40 * diffIBLWrap;
        color += specIBL * 0.48 * mix(1.0, 0.48, metallic);
        color += reflSunKey * reflSunGain * shadow;
    }

    float hemiUp = saturate(N.y * 0.5 + 0.5);
    float wrapSun = saturate(dot(N, Lsun) * 0.45 + 0.55);
    float ambMix = mix(hemiUp, wrapSun, 0.72);
    float3 ambLow = float3(0.020, 0.020, 0.024);
    float3 ambHigh = float3(0.052, 0.056, 0.066);
    float3 amb = albedo * mix(ambLow, ambHigh, ambMix);
    color += amb * (0.12 + 0.38 * (1.0 - metallic) + 0.22 * metallic);

    {
        float dist = length(in.posWS - u.cameraPosWS);
        float fogStart = 55.0;
        float fogEnd = 280.0;
        float t = saturate((dist - fogStart) / max(1e-3, (fogEnd - fogStart)));
        float fogDensity = 0.032;
        float fog = (1.0 - exp(-fogDensity * max(0.0, dist - fogStart))) * t;
        float3 viewDir = normalize(in.posWS - u.cameraPosWS);
        float3 fogCol = skyColor(viewDir, Lsun, sunDiskHDR);
        color = mix(color, fogCol, saturate(fog) * 0.72);
    }

    color = ACESFilm(color * max(0.0, u.exposure));
    return float4(color, 1.0);
}
