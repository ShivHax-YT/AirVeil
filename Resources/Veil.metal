#include <metal_stdlib>
using namespace metal;

struct RasterVertex { float4 position [[position]]; float2 uv; };
struct VeilUniforms { float4 effect; float4 options; };

vertex RasterVertex veilVertex(uint id [[vertex_id]]) {
    const float2 p[3] = {float2(-1, 1), float2(-1, -3), float2(3, 1)};
    const float2 uv[3] = {float2(0, 0), float2(0, 2), float2(2, 0)};
    return {float4(p[id], 0, 1), uv[id]};
}

fragment float4 veilFragment(RasterVertex v [[stage_in]],
                             texture2d<float> sharp [[texture(0)]],
                             texture2d<float> soft [[texture(1)]],
                             texture2d<float> medium [[texture(2)]],
                             texture2d<float> strong [[texture(3)]],
                             constant VeilUniforms& u [[buffer(0)]]) {
    constexpr sampler linearClamp(coord::normalized, address::clamp_to_edge, filter::linear);
    const float3 concealment = float3(0.075, 0.085, 0.105);
    if (u.options.y > 0.5) return float4(concealment, 1);
    float w = max(u.effect.z, 0.001);
    float rightMask = smoothstep(0.5-w*0.5, 0.5+w*0.5, v.uv.x);
    float coverage = clamp(mix(u.effect.x, u.effect.y, rightMask), 0.0, 1.0);
    bool base = u.options.z > 0.5;
    float3 original = sharp.sample(linearClamp, v.uv).rgb;
    if (coverage <= 0.000001) return base ? float4(original, 1) : float4(0);
    // Requested variance is maximum variance * coverage. Interpolating the
    // neighboring Gaussian levels gives a continuous approximation.
    const float a = (6.0/32.0)*(6.0/32.0);
    const float b = 0.25;
    float3 color;
    if (coverage < a) color = mix(original, soft.sample(linearClamp, v.uv).rgb, coverage/a);
    else if (coverage < b) color = mix(soft.sample(linearClamp, v.uv).rgb,
                                      medium.sample(linearClamp, v.uv).rgb, (coverage-a)/(b-a));
    else color = mix(medium.sample(linearClamp, v.uv).rgb,
                     strong.sample(linearClamp, v.uv).rgb, (coverage-b)/(1.0-b));
    if (u.options.x > 0.5) color = mix(color, concealment, smoothstep(0.65, 1.0, coverage));
    if (base) return float4(mix(original, color, coverage), 1);
    return float4(color * coverage, coverage);
}
