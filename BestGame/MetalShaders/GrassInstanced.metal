#include <metal_stdlib>
using namespace metal;

// Инстансированная трава: один draw, ветер в VS (слои синусов по world XZ + время),
// градиент оснок/вершина, мягкий диффуз + «просвет» к солнцу (без текстур).

struct GrassVertexInstIn {
    float3 posOS [[attribute(0)]]; // x — ширина, y ∈ [0,1] высота, z=0
    float4 inst [[attribute(1)]]; // xyz основание, w hash
};

struct GrassUniforms {
    float4x4 viewProj;
    float4 cam_time;       // xyz камера, w — время
    float4 sun_wind;       // xyz направление к свету (уже нормализовано со Swift), w — сила ветра
    float4 blade;          // x ширина основания, y высота лезвия, z масштаб шума, w unused
};

struct GrassVertexOut {
    float4 position [[position]];
    float height01;
    float edge01;          // 0 центр лезвия, 1 край
    float3 posWS;
    float3 swayN;          // аппроксимация нормали после изгиба
};

inline float grass_hash11(float n) {
    return fract(sin(n) * 43758.5453123);
}

vertex GrassVertexOut grass_instanced_vs(
    GrassVertexInstIn vin [[stage_in]],
    constant GrassUniforms& u [[buffer(2)]]
) {
    GrassVertexOut out;
    float3 base = vin.inst.xyz;
    float h = vin.posOS.y;
    float lateral = vin.posOS.x;
    float seed = vin.inst.w;

    float t = u.cam_time.w;
    float nx = base.x * u.blade.z;
    float nz = base.z * u.blade.z;

    float w1 = sin(t * 1.15 + nx * 0.31 + nz * 0.17 + seed * 6.2831);
    float w2 = sin(t * 2.35 + nx * -0.22 + nz * 0.41 + seed * 4.1);
    float w3 = cos(t * 0.85 + nx * 0.11 + nz * 0.53);
    float gust = (w1 * 0.55 + w2 * 0.28 + w3 * 0.17) * u.sun_wind.w;

    float bend = h * h;
    float swayX = gust * bend * 0.95;
    float swayZ = (w2 * 0.6 + w3 * 0.25) * bend * u.sun_wind.w * 0.55;

    float yaw = seed * 6.2831853;
    float cy = cos(yaw);
    float sy = sin(yaw);
    float3 side = float3(cy, 0.0, sy);
    float3 up = float3(0.0, 1.0, 0.0);

    float height = u.blade.y;
    float halfW = u.blade.x;
    float3 local = side * (lateral * halfW * 2.0) + up * (h * height);
    local.x += swayX * h;
    local.z += swayZ * h;
    float lean = gust * bend * 0.12;
    local.y += lean * height * 0.08;

    float3 world = base + local;
    world.y += 0.035;

    out.position = u.viewProj * float4(world, 1.0);
    out.height01 = h;
    out.edge01 = saturate(abs(lateral) * 1.15);
    out.posWS = world;
    float3 windDir = normalize(float3(swayX, 0.02, swayZ) + float3(0.001, 1.0, 0.001));
    out.swayN = normalize(mix(float3(0.0, 1.0, 0.0), windDir, 0.35 + 0.65 * h));
    return out;
}

fragment float4 grass_instanced_fs(
    GrassVertexOut in [[stage_in]],
    constant GrassUniforms& u [[buffer(2)]]
) {
    float3 V = normalize(u.cam_time.xyz - in.posWS);
    float3 L = u.sun_wind.xyz;
    float3 N = normalize(in.swayN);

    float edgeA = 1.0 - smoothstep(0.55, 1.0, in.edge01);
    float tipA = smoothstep(0.0, 0.22, in.height01) * (1.0 - smoothstep(0.78, 1.0, in.height01)) * 0.25 + 0.92;
    float alpha = saturate(edgeA * tipA);
    if (alpha < 0.04) {
        discard_fragment();
    }

    float3 baseCol = float3(0.05, 0.16, 0.045);
    float3 tipCol = float3(0.38, 0.72, 0.14);
    float3 albedo = mix(baseCol, tipCol, pow(in.height01, 1.35));

    float wrap = saturate(dot(N, L) * 0.55 + 0.42);
    float3 diffuse = albedo * wrap;

    float back = saturate(dot(-L, V));
    float transl = pow(back, 2.2) * (0.22 + 0.55 * in.height01);
    float3 sunTint = float3(0.55, 0.85, 0.35);
    float3 sss = transl * sunTint * 0.55;

    float3 H = normalize(L + V);
    float spec = pow(saturate(dot(N, H)), 48.0) * 0.12 * in.height01;

    float3 amb = albedo * 0.07;
    float3 color = amb + diffuse * 0.95 + sss + float3(spec);

    color = color / (color + float3(0.28));
    return float4(color, alpha * 0.94);
}
