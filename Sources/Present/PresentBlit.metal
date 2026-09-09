#include <metal_stdlib>
using namespace metal;

struct PresentUniforms {
    float4 drawable;
    float4 dest;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut present_vertex(uint vid [[vertex_id]], constant PresentUniforms &u [[buffer(0)]]) {
    float2 corners[4] = {
        float2(u.dest.x, u.dest.y),
        float2(u.dest.x + u.dest.z, u.dest.y),
        float2(u.dest.x, u.dest.y + u.dest.w),
        float2(u.dest.x + u.dest.z, u.dest.y + u.dest.w)
    };
    float2 uvs[4] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(0.0, 1.0),
        float2(1.0, 1.0)
    };
    float2 px = corners[vid];
    float2 ndc = float2(
        (px.x / u.drawable.x) * 2.0 - 1.0,
        1.0 - (px.y / u.drawable.y) * 2.0
    );
    VertexOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.uv = uvs[vid];
    return out;
}

fragment float4 present_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]]
) {
    constexpr sampler samp(coord::normalized, address::clamp_to_edge, filter::linear);
    return tex.sample(samp, in.uv);
}

fragment float4 present_ycbcr_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> yTex [[texture(0)]],
    texture2d<float> cbcrTex [[texture(1)]],
    constant float &fullRange [[buffer(1)]]
) {
    constexpr sampler samp(coord::normalized, address::clamp_to_edge, filter::linear);
    float y = yTex.sample(samp, in.uv).r;
    float2 cbcr = cbcrTex.sample(samp, in.uv).rg;
    if (fullRange < 0.5) {
        y = (y - 0.062745098) * 1.16438356;
    }
    float cb = cbcr.x - 0.5;
    float cr = cbcr.y - 0.5;
    float r = y + 1.5748 * cr;
    float g = y - 0.1873 * cb - 0.4681 * cr;
    float b = y + 1.8556 * cb;
    return float4(r, g, b, 1.0);
}
