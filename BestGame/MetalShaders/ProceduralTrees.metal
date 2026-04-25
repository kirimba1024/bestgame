#include <metal_stdlib>
using namespace metal;

struct Instance {
    float3 position;
    float  scale;
    float  yaw;
    float  seed;
};

struct Uniforms {
    float4x4 viewProj;
    float    time;
    float3   _pad0;
};

struct FragUniforms {
    float3 cameraPosWS;
    float  _pad0;
    float3 sunDirectionWS;
    float  sunIntensity;
};

struct LightVPUniforms {
    float4x4 lightViewProj;
};

struct Vertex {
    float3 position;
    float3 normal;
    uint   materialID;
    uint   _pad;
};

struct VSOut {
    float4 position [[position]];
    float3 worldPos;
    float3 normalWS;
    uint   materialID;
    float  seed;
};

static inline float hash11(float p) {
    return fract(sin(p) * 43758.5453123);
}

static inline float2 rot2(float2 v, float a) {
    float s = sin(a), c = cos(a);
    return float2(c * v.x - s * v.y, s * v.x + c * v.y);
}

static inline float sampleShadowPCF(depth2d<float> shadowTex,
                                    sampler shadowSamp,
                                    float4 shadowPos,
                                    float cmpBias)
{
    float3 ndc = shadowPos.xyz / max(shadowPos.w, 1e-6);
    float2 uv = float2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
    float depth = ndc.z;
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) return 1.0;
    if (depth < 0.0 || depth > 1.0) return 1.0;

    float cmpZ = depth - cmpBias;
    // Simple 3x3 PCF with hardware compare.
    float2 texel = 1.0 / float2(shadowTex.get_width(), shadowTex.get_height());
    float sum = 0.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            sum += shadowTex.sample_compare(shadowSamp, uv + float2(x, y) * texel, cmpZ);
        }
    }
    return sum / 9.0;
}

vertex VSOut proceduralTreeVS(const device Vertex* vtx [[buffer(0)]],
                              const device Instance* inst [[buffer(1)]],
                              constant Uniforms& u [[buffer(2)]],
                              uint vid [[vertex_id]],
                              uint iid [[instance_id]])
{
    Vertex vin = vtx[vid];
    Instance I = inst[iid];

    float3 lp = vin.position;

    // Wind: bend mostly on canopy (above trunk).
    float sway = (hash11(I.seed * 17.3) * 2.0 - 1.0) * 0.15;
    float t = u.time * (0.8 + hash11(I.seed * 2.1)) + I.seed * 10.0;
    float canopyMask = smoothstep(0.8, 1.4, lp.y);
    float bend = sin(t + lp.y * 1.7) * sway * canopyMask;

    float2 xz = rot2(float2(lp.x, lp.z), I.yaw);
    xz = rot2(xz, bend * lp.y);
    float3 wp = float3(xz.x, lp.y, xz.y) * I.scale + I.position;

    float2 nxz = rot2(float2(vin.normal.x, vin.normal.z), I.yaw);
    float3 n = normalize(float3(nxz.x, vin.normal.y, nxz.y));

    VSOut o;
    o.worldPos = wp;
    o.normalWS = n;
    o.position = u.viewProj * float4(wp, 1.0);
    o.materialID = vin.materialID;
    o.seed = I.seed;
    return o;
}

// Shadow pass: re-use same VS but output clip-space already computed by light VP in Swift.
vertex float4 proceduralTreeShadowVS(const device Vertex* vtx [[buffer(0)]],
                                     const device Instance* inst [[buffer(1)]],
                                     constant Uniforms& u [[buffer(2)]],
                                     uint vid [[vertex_id]],
                                     uint iid [[instance_id]])
{
    Vertex vin = vtx[vid];
    Instance I = inst[iid];
    float3 lp = vin.position;

    float2 xz = rot2(float2(lp.x, lp.z), I.yaw);
    float3 wp = float3(xz.x, lp.y, xz.y) * I.scale + I.position;
    return u.viewProj * float4(wp, 1.0);
}

fragment void proceduralTreeShadowFS() {
    // Depth-only.
}

fragment float4 proceduralTreeFS(VSOut in [[stage_in]],
                                 constant FragUniforms& fu [[buffer(0)]],
                                 constant LightVPUniforms& lvp [[buffer(1)]],
                                 depth2d<float> shadowTex [[texture(0)]],
                                 sampler shadowSamp [[sampler(0)]])
{
    float3 N = normalize(in.normalWS);
    float3 L = normalize(-fu.sunDirectionWS);
    float NdotL = clamp(dot(N, L), 0.0, 1.0);

    float3 trunkCol = float3(0.62, 0.58, 0.52);
    float3 leafCol  = float3(0.10, 0.34, 0.13);
    float3 baseCol = (in.materialID == 0) ? trunkCol : leafCol;

    // Shadowing (optional).
    float shadow = 1.0;
    if (shadowTex.get_width() > 0) {
        // NOTE: WorldScene already has a PCF sampler; we use a local PCF here.
        float4 sp = lvp.lightViewProj * float4(in.worldPos, 1.0);
        // More bias for leaves to reduce shimmering, especially at distance.
        float baseBias = max(0.0018, 0.0100 * (1.0 - NdotL));
        float matBias = (in.materialID == 0) ? 0.0 : 0.0015;
        shadow = sampleShadowPCF(shadowTex, shadowSamp, sp, baseBias + matBias);
    }

    float3 ambient = baseCol * 0.25;
    float3 diffuse = baseCol * (0.12 + fu.sunIntensity * NdotL * shadow);
    return float4(ambient + diffuse, 1.0);
}

