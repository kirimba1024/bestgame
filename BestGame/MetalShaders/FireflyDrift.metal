#include <metal_stdlib>
using namespace metal;

// -----------------------------------------------------------------------------
// Медленные «светлячки» — второй декоративный слой (additive, мягче burst).
// -----------------------------------------------------------------------------

struct FireflyParticle {
    float3 position;
    float life;
    float3 velocity;
    float size;
    float4 color;
    uint seed;
    uint3 _pad;
};

struct FireflySimUniforms {
    float time;
    float dt;
    uint particleCount;
    uint _pad0;
    float3 anchor;
    float driftRadius;
    float3 gravity;
    float drag;
    float wander;
    float lifeDecay;
    float minSize;
    float maxSize;
};

struct FireflyDrawUniforms {
    float4x4 viewProj;
    float3 cameraRight;
    float _padR;
    float3 cameraUp;
    float _padU;
};

struct FireflyVertexOut {
    float4 position [[position]];
    float4 color;
    float2 uv;
};

inline float ff_hash11(float n) { return fract(sin(n) * 43758.5453); }
inline float3 ff_hash31(float n) {
    return float3(ff_hash11(n), ff_hash11(n + 41.2), ff_hash11(n + 93.7));
}

inline void ff_respawn(thread FireflyParticle& p, constant FireflySimUniforms& u, float t) {
    float3 rnd = ff_hash31(float(p.seed) + t * 7.0);
    float3 orbit = float3(cos(t * 0.4 + rnd.x * 6.28), 0.12 * sin(t * 0.7 + rnd.y * 6.28), sin(t * 0.35 + rnd.z * 6.28));
    p.position = u.anchor + orbit * u.driftRadius + (rnd - 0.5) * (u.driftRadius * 0.35);
    float3 w = float3(sin(t * 0.55 + float(p.seed)), cos(t * 0.48), sin(t * 0.39 + float(p.seed) * 0.1));
    p.velocity = normalize(w) * u.wander * (0.4 + 0.6 * rnd.x);
    p.life = 1.0;
    float3 leaf = float3(0.35, 1.0, 0.45);
    float3 mint = float3(0.55, 0.95, 0.75);
    float3 rgb = mix(leaf, mint, rnd.y) * (0.55 + 0.45 * rnd.z);
    p.color = float4(rgb, 0.22 + 0.18 * rnd.x);
    p.size = mix(u.minSize, u.maxSize, rnd.y);
}

kernel void firefly_update_sim(
    device FireflyParticle* particles [[buffer(0)]],
    constant FireflySimUniforms& u [[buffer(1)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= u.particleCount) {
        return;
    }
    thread FireflyParticle p = particles[gid];
    float t = u.time + float(gid) * 0.013;
    float drag = clamp(u.drag, 0.0, 40.0);

    if (p.life <= 0.0) {
        ff_respawn(p, u, t);
    } else {
        p.velocity += u.gravity * u.dt;
        p.velocity *= exp(-drag * u.dt);
        p.position += p.velocity * u.dt;
        p.life -= u.lifeDecay * u.dt;
        float pulse = 0.82 + 0.18 * sin(t * 5.5 + float(gid));
        p.color.a = saturate(p.life) * 0.55 * pulse;
        if (p.life <= 0.0) {
            ff_respawn(p, u, t);
        }
    }
    particles[gid] = p;
}

vertex FireflyVertexOut firefly_billboard_vs(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    device const FireflyParticle* particles [[buffer(0)]],
    constant FireflyDrawUniforms& du [[buffer(1)]]
) {
    FireflyVertexOut out;
    FireflyParticle p = particles[iid];
    const float2 q[6] = {
        float2(-1.0, -1.0), float2(1.0, -1.0), float2(1.0, 1.0),
        float2(-1.0, -1.0), float2(1.0, 1.0), float2(-1.0, 1.0)
    };
    const float2 uv[6] = {
        float2(0.0, 1.0), float2(1.0, 1.0), float2(1.0, 0.0),
        float2(0.0, 1.0), float2(1.0, 0.0), float2(0.0, 0.0)
    };
    float2 corner = q[vid];
    float2 texUV = uv[vid];
    if (p.life <= 0.0) {
        out.position = float4(0.0, 0.0, 2.0, 1.0);
        out.color = float4(0.0);
        out.uv = texUV;
        return out;
    }
    float s = p.size * (0.7 + 0.3 * p.life);
    float3 world = p.position + du.cameraRight * (corner.x * s) + du.cameraUp * (corner.y * s);
    out.position = du.viewProj * float4(world, 1.0);
    out.color = float4(p.color.rgb, p.color.a);
    out.uv = texUV;
    return out;
}

fragment float4 firefly_soft_additive_fs(FireflyVertexOut in [[stage_in]]) {
    float2 c = in.uv * 2.0 - 1.0;
    float r2 = dot(c, c);
    float glow = exp(-r2 * 4.2);
    float3 rgb = in.color.rgb * glow * in.color.a * 0.85;
    return float4(rgb, 1.0);
}
