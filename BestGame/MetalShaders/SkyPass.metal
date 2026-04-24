#include "ShaderShared.h"

vertex FSOut vertex_fullscreen(uint vid [[vertex_id]]) {
    float2 p;
    if (vid == 0) p = float2(-1.0, -1.0);
    else if (vid == 1) p = float2( 3.0, -1.0);
    else p = float2(-1.0,  3.0);

    FSOut o;
    o.position = float4(p, 0.0, 1.0);
    o.uv = p * 0.5 + 0.5;
    return o;
}

fragment float4 fragment_sky(FSOut in [[stage_in]], constant SkyUniforms& u [[buffer(0)]]) {
    float2 ndc = in.uv * 2.0 - 1.0;
    float4 pClip = float4(ndc, 1.0, 1.0);
    float4 pWS = u.invViewProj * pClip;
    pWS.xyz /= max(1e-6, pWS.w);
    float3 dir = normalize(pWS.xyz - u.cameraPosWS);
    float3 sunD = (length(u.sunDirWS) > 1e-5) ? normalize(u.sunDirWS) : kSunDirFallback;
    float3 disk = (length(u.sunDiskRadianceHDR) > 1e-5) ? u.sunDiskRadianceHDR : float3(6.0, 5.7, 5.1);
    float3 col = skyColor(dir, sunD, disk);
    return float4(col, 1.0);
}
