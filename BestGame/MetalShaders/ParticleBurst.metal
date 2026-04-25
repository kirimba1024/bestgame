#include <metal_stdlib>
using namespace metal;

// -----------------------------------------------------------------------------
// Additive burst particles (витрина). Имена с префиксом burst_* — без коллизий с Firefly.
// -----------------------------------------------------------------------------

struct BurstParticle {
    float3 position;
    float life;
    float3 velocity;
    float size;
    float4 color;
    uint seed;
    uint3 _pad;
};

struct BurstSimUniforms {
    float time;
    float dt;
    uint particleCount;
    uint _pad0;
    float3 emitterCenter;
    float emitterJitter;
    float3 gravity;
    float drag;
    float spawnSpeed;
    float lifeDecay;
    float minParticleSize;
    float maxParticleSize;
};

struct BurstDrawUniforms {
    float4x4 viewProj;
    float3 cameraRight;
    float _padR;
    float3 cameraUp;
    float _padU;
};

struct BurstVertexOut {
    float4 position [[position]];
    float4 color;
    float2 uv;
};

inline float burst_hash11(float n) {
    return fract(sin(n) * 43758.5453123);
}

inline float2 burst_hash21(float n) {
    return float2(burst_hash11(n), burst_hash11(n + 19.19));
}

inline float3 burst_hash31(float n) {
    return float3(burst_hash11(n), burst_hash11(n + 73.1), burst_hash11(n + 131.7));
}

inline float3 burst_randomUnit(float seed) {
    float2 u = burst_hash21(seed);
    float z = u.x * 2.0 - 1.0;
    float phi = u.y * (2.0 * M_PI_F);
    float r = sqrt(max(1e-6, 1.0 - z * z));
    return float3(r * cos(phi), r * sin(phi), z);
}

inline void burst_respawn(thread BurstParticle& p, constant BurstSimUniforms& u, float t) {
    float3 rnd = burst_hash31(float(p.seed) + t * 60.0);
    float3 dir = normalize(burst_randomUnit(float(p.seed) * 0.1 + t) + float3(0.15, 1.0, 0.08));
    float speed = u.spawnSpeed * (0.35 + 0.65 * rnd.x);
    p.position = u.emitterCenter + (rnd - 0.5) * 2.0 * u.emitterJitter;
    p.velocity = dir * speed;
    p.life = 1.0;
    float hue = fract(0.08 + rnd.y * 0.12);
    float warm = 0.55 + 0.45 * rnd.z;
    float3 c1 = float3(1.0, 0.35, 0.08);
    float3 c2 = float3(0.25, 0.85, 1.0);
    float3 rgb = mix(c1, c2, hue) * warm;
    p.color = float4(rgb, 0.55 + 0.35 * rnd.x);
    p.size = mix(u.minParticleSize, u.maxParticleSize, rnd.y);
}

kernel void burst_update_sim(
    device BurstParticle* particles [[buffer(0)]],
    constant BurstSimUniforms& u [[buffer(1)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= u.particleCount) {
        return;
    }

    thread BurstParticle p = particles[gid];
    float t = u.time + float(gid) * 0.017;
    float3 g = u.gravity;
    float drag = clamp(u.drag, 0.0, 50.0);

    if (p.life <= 0.0) {
        burst_respawn(p, u, t);
    } else {
        p.velocity += g * u.dt;
        p.velocity *= exp(-drag * u.dt);
        p.position += p.velocity * u.dt;
        p.life -= u.lifeDecay * u.dt;
        float flicker = 0.88 + 0.12 * sin(t * 14.0 + float(gid));
        p.color.a = saturate(p.life * 0.95) * 0.75 * flicker;
        if (p.life <= 0.0) {
            burst_respawn(p, u, t);
        }
    }

    particles[gid] = p;
}

vertex BurstVertexOut burst_billboard_vs(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    device const BurstParticle* particles [[buffer(0)]],
    constant BurstDrawUniforms& du [[buffer(1)]]
) {
    BurstVertexOut out;
    BurstParticle p = particles[iid];

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

    float s = p.size * (0.65 + 0.35 * p.life);
    float3 world = p.position + du.cameraRight * (corner.x * s) + du.cameraUp * (corner.y * s);
    out.position = du.viewProj * float4(world, 1.0);
    out.color = float4(p.color.rgb, p.color.a);
    out.uv = texUV;
    return out;
}

fragment float4 burst_soft_additive_fs(BurstVertexOut in [[stage_in]]) {
    float2 c = in.uv * 2.0 - 1.0;
    float r2 = dot(c, c);
    float mask = exp(-r2 * 2.8);
    float core = exp(-r2 * 10.0);
    float intensity = mask * 0.55 + core * 0.95;
    float3 rgb = in.color.rgb * intensity * in.color.a;
    return float4(rgb, 1.0);
}
