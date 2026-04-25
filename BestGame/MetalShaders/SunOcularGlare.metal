#include <metal_stdlib>
using namespace metal;

// -----------------------------------------------------------------------------
// Солнечный ореол + «ослепление»: процедурный blob в offscreen rgba16f → mips
// (hardware blur по пирамиде) → композит суммой LOD (как дешёвый bloom / CoD-стиль).
// -----------------------------------------------------------------------------

struct SunFSOut {
    float4 position [[position]];
    float2 uv;
};

vertex SunFSOut sun_glare_vertex(uint vid [[vertex_id]]) {
    float2 p;
    if (vid == 0) {
        p = float2(-1.0, -1.0);
    } else if (vid == 1) {
        p = float2(3.0, -1.0);
    } else {
        p = float2(-1.0, 3.0);
    }
    SunFSOut o;
    o.position = float4(p, 0.0, 1.0);
    o.uv = p * 0.5 + 0.5;
    return o;
}

struct SunBlobUniforms {
    float2 sunUV;
    /// h / w текстуры блума — круговой ореол в UV-текселях.
    float texInvAspect;
    float sunAlign;
};

/// Яркое HDR-пятно в экранных UV → мипы дают широкое размытие без отдельного Kawase.
fragment float4 sun_bloom_blob_fs(SunFSOut in [[stage_in]], constant SunBlobUniforms& u [[buffer(0)]]) {
    if (u.sunAlign < 0.02) {
        return float4(0.0);
    }
    float2 d = (in.uv - u.sunUV) * float2(1.0, u.texInvAspect);
    float r2 = dot(d, d);
    float core = exp(-r2 / 0.00055);
    float corona = exp(-r2 / 0.035);
    float halo = exp(-r2 / 0.22);
    float3 sunCol = float3(1.0, 0.96, 0.88);
    float3 hdr = sunCol * (core * 42.0 + corona * 9.0 + halo * 3.2);
    float gate = smoothstep(0.0, 0.06, u.sunAlign);
    return float4(hdr * gate, 1.0);
}

struct SunCompositeUniforms {
    float sunAlign;
    float mipGlowStrength;
    float veilStrength;
    float centerDazzle;
};

fragment float4 sun_glare_composite_fs(
    SunFSOut in [[stage_in]],
    constant SunCompositeUniforms& u [[buffer(0)]],
    texture2d<float> bloom [[texture(0)]],
    sampler smp [[sampler(0)]]
) {
    if (u.sunAlign < 0.015) {
        return float4(0.0);
    }

    constexpr int kMaxLod = 8;
    float3 acc = float3(0.0);
    float wsum = 0.0;
    float weights[kMaxLod] = {0.38, 0.48, 0.52, 0.45, 0.38, 0.30, 0.22, 0.14};

    for (int i = 0; i < kMaxLod; ++i) {
        float lod = float(i);
        float3 s = bloom.sample(smp, in.uv, level(lod)).rgb;
        float w = weights[i];
        acc += s * w;
        wsum += w;
    }
    acc /= max(1e-4, wsum);

    float3 glow = acc * u.mipGlowStrength * smoothstep(0.12, 1.0, u.sunAlign);

    float2 c = in.uv - float2(0.5);
    float distC = length(c);
    // Вуаль только при почти идеальном попадании в диск и в основном к центру кадра (не весь экран).
    float veilAmt = smoothstep(0.972, 0.9993, u.sunAlign) * u.veilStrength;
    float edgeFall = exp(-distC * distC * 3.8);
    float3 veiling = float3(1.0, 0.98, 0.94) * veilAmt * edgeFall;

    float dazzle = smoothstep(0.988, 0.9997, u.sunAlign) * u.centerDazzle;
    float3 dazz = float3(1.0, 0.98, 0.92) * dazzle * exp(-distC * distC * 28.0);

    return float4(glow + veiling + dazz, 1.0);
}
