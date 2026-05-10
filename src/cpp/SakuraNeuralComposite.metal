#include <metal_stdlib>
using namespace metal;

struct NeuralAccumParams {
    uint gx0;
    uint gy0;
    uint tout;
    uint tin;
    uint rl;
    uint outPadW;
    uint outPadH;
    uint useFlatWeights;
};
struct NeuralFinalParams {
    uint outW;
    uint outH;
    uint outPadW;
    uint outPadH;
    uint padInW;
    uint padInH;
    uint rl;
};

inline float hann_lane(uint j, uint n)
{
    if (n <= 1u)
        return 1.f;
    j = clamp(j, 0u, n - 1u);
    float u = float(j) / float(max(n - 1u, 1u));
    const float pi = 3.14159265358979323846f;
    return 0.5f * (1.f - cos(2.f * pi * u));
}

kernel void sakura_neural_accum_clear(texture2d<float, access::write> acc [[texture(0)]],
                                      uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= acc.get_width() || gid.y >= acc.get_height())
        return;
    acc.write(float4(0.f), gid);
}

kernel void sakura_neural_tile_accumulate(texture2d<half, access::read> tileBGRA [[texture(0)]],
                                          texture2d<float, access::read_write> acc [[texture(1)]],
                                          constant NeuralAccumParams &P [[buffer(0)]],
                                          uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= P.tout || gid.y >= P.tout)
        return;
    float wtile = (P.useFlatWeights != 0u)
        ? 1.f
        : hann_lane(gid.y / P.rl, P.tin) * hann_lane(gid.x / P.rl, P.tin);
    if (wtile <= 1e-7f)
        return;
    uint gx = P.gx0 + gid.x;
    uint gy = P.gy0 + gid.y;
    if (gx >= P.outPadW || gy >= P.outPadH)
        return;
    half4 bgra = tileBGRA.read(gid);
    float bf = float(bgra.r) * (1.f / 255.f);
    float gf = float(bgra.g) * (1.f / 255.f);
    float rf = float(bgra.b) * (1.f / 255.f);
    float4 cur = acc.read(uint2(gx, gy));
    cur.x += rf * wtile;
    cur.y += gf * wtile;
    cur.z += bf * wtile;
    cur.w += wtile;
    acc.write(cur, uint2(gx, gy));
}

kernel void sakura_neural_finalize(texture2d<float, access::read> acc [[texture(0)]],
                                   texture2d<half, access::read> padInBGRA [[texture(1)]],
                                   texture2d<half, access::write> outBGRA [[texture(2)]],
                                   constant NeuralFinalParams &F [[buffer(0)]],
                                   uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= F.outW || gid.y >= F.outH)
        return;
    float4 a = acc.read(gid);
    half4 o;
    if (a.w > 1e-5f) {
        float inv = 1.f / a.w;
        float rf = clamp(a.x * inv, 0.f, 1.f);
        float gf = clamp(a.y * inv, 0.f, 1.f);
        float bf = clamp(a.z * inv, 0.f, 1.f);
        o = half4(half(bf), half(gf), half(rf), half(1.f));
    } else {
        uint lx = gid.x / max(F.rl, 1u);
        uint ly = gid.y / max(F.rl, 1u);
        lx = min(lx, max(F.padInW, 1u) - 1u);
        ly = min(ly, max(F.padInH, 1u) - 1u);
        o = padInBGRA.read(uint2(lx, ly));
        o.a = half(1.f);
    }
    outBGRA.write(o, gid);
}
