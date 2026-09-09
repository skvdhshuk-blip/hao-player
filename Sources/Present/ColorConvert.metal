#include <metal_stdlib>
using namespace metal;

constexpr sampler convert_samp(coord::normalized, address::clamp_to_edge, filter::linear);

inline float4 ycbcr_rgb(float y, float2 cbcr, float full_range) {
    if (full_range < 0.5) {
        y = (y - 0.062745098) * 1.16438356;
    }
    float cb = cbcr.x - 0.5;
    float cr = cbcr.y - 0.5;
    float r = y + 1.5748 * cr;
    float g = y - 0.1873 * cb - 0.4681 * cr;
    float b = y + 1.8556 * cb;
    return float4(r, g, b, 1.0);
}

kernel void ycbcr_to_rgba16(
    texture2d<float> yTex [[texture(0)]],
    texture2d<float> cbcrTex [[texture(1)]],
    texture2d<float, access::write> dst [[texture(2)]],
    constant float &fullRange [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) {
        return;
    }
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
    float y = yTex.sample(convert_samp, uv).r;
    float2 cbcr = cbcrTex.sample(convert_samp, uv).rg;
    dst.write(ycbcr_rgb(y, cbcr, fullRange), gid);
}

kernel void bgra_to_rgba16(
    texture2d<float> src [[texture(0)]],
    texture2d<float, access::write> dst [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) {
        return;
    }
    dst.write(src.read(gid), gid);
}

kernel void rgba16_to_bgra8(
    texture2d<float> src [[texture(0)]],
    texture2d<float, access::write> dst [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) {
        return;
    }
    dst.write(src.read(gid), gid);
}
