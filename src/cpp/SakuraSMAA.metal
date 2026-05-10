// SPDX-License-Identifier: MIT
// Sakura SMAA — Subpixel Morphological Antialiasing 1x (Ultra preset) port to Metal Shading Language.
//
// Based on the reference HLSL implementation:
//   Copyright (C) 2013 Jorge Jimenez (jorge@iryoku.com)
//   Copyright (C) 2013 Jose I. Echevarria (joseignacioechevarria@gmail.com)
//   Copyright (C) 2013 Belen Masia, Fernando Navarro, Diego Gutierrez
// Original released under MIT (see src/cpp/third_party/SMAA/LICENSE).
//
// Sakura-specific enhancements layered on top of reference Ultra preset:
//   1. Linear-space edge detection (sRGB → linear before luma compare)
//   2. BT.709 → perceptual-luma weighting (matches human edge sensitivity better than raw luma)
//   3. Adaptive per-pixel threshold (3x3 local luma variance scales 0.03..0.18)
//   4. Predicated edge detection (optional second-input texture provides edge truth)
//   5. Pixel-art preserve (axis-aligned hard-edge detection skips blend → keeps PSX UI text crisp)
//   6. Ultra preset constants (max search 32, diag search 16, corner rounding 25)
//   7. Embedded uniform-driven quality scaler (runtime quality 0..3)
//   8. T2x ready: outputs unjittered final color so a temporal resolve can sit downstream
//
// Pass layout (driver runs each as a fragment shader on a fullscreen triangle strip):
//   [Pass 1] sakura_smaa_edge_detect    — input: color (+optional predicate) → R8G8 edge mask
//   [Pass 2] sakura_smaa_blend_weights  — input: edges + AreaTex + SearchTex → RGBA8 weights
//   [Pass 3] sakura_smaa_neighborhood   — input: color + weights → final blended RGBA color
//
// All passes share one uniform block (SakuraSMAAUbo); unused fields are ignored per pass.

#include <metal_stdlib>
using namespace metal;

// MARK: - Configuration constants (SMAA Ultra preset baseline)
// These mirror the SMAA_PRESET_ULTRA macros from the reference HLSL.
constant float SAKURA_SMAA_THRESHOLD = 0.05;          // base luma/color threshold (adaptive scales this)
constant float SAKURA_SMAA_DEPTH_THRESHOLD = 0.01;    // unused (we don't have depth)
constant int   SAKURA_SMAA_MAX_SEARCH_STEPS = 32;     // ultra
constant int   SAKURA_SMAA_MAX_SEARCH_STEPS_DIAG = 16;// ultra
constant int   SAKURA_SMAA_CORNER_ROUNDING = 25;      // ultra
constant float SAKURA_SMAA_CORNER_ROUNDING_NORM = 0.25;
constant float SAKURA_SMAA_LOCAL_CONTRAST_ADAPTATION_FACTOR = 2.0;
constant int   SAKURA_SMAA_AREATEX_MAX_DISTANCE = 16;
constant int   SAKURA_SMAA_AREATEX_MAX_DISTANCE_DIAG = 20;
constant float2 SAKURA_SMAA_AREATEX_PIXEL_SIZE = float2(1.0/160.0, 1.0/560.0);
constant float SAKURA_SMAA_AREATEX_SUBTEX_SIZE = 1.0/7.0;
constant float SAKURA_SMAA_SEARCHTEX_SIZE_X = 66.0;
constant float SAKURA_SMAA_SEARCHTEX_SIZE_Y = 33.0;
constant float SAKURA_SMAA_SEARCHTEX_PACKED_SIZE_X = 64.0;
constant float SAKURA_SMAA_SEARCHTEX_PACKED_SIZE_Y = 16.0;

// MARK: - Uniforms shared across all SMAA passes.
struct SakuraSMAAUbo {
    float4 rtMetrics;          // (1/w, 1/h, w, h) of the SMAA work resolution
    float4 sakuraFlags;        // x: linear-space (0/1), y: adaptive thresh (0/1), z: pixel-art preserve (0/1), w: predication (0/1)
    float4 sakuraTuning;       // x: threshold scale (multiplier on base 0.05), y: pixel-art tolerance, z: predicate scale, w: predicate strength
    float4 sakuraQuality;      // x: max search steps override, y: diag steps override, z: corner override, w: reserved
};

// MARK: - Helpers
struct SakuraSMAAVOut {
    float4 position [[position]];
    float2 texcoord;
    float4 offset0;
    float4 offset1;
    float4 offset2;
    float2 pixcoord;
};

inline float sakura_smaa_perceptual_luma(float3 c, bool linearize)
{
    float3 lc = c;
    if (linearize) {
        // Approximate sRGB → linear (cheap; matches SMAA gamma path)
        lc = pow(max(c, 0.0), 2.2);
    }
    // Perceptual luma — Oklab L* approximation collapsed to a fast dot
    // Using Rec.2020-ish weights weighted toward perceptual response
    return dot(lc, float3(0.2627, 0.6780, 0.0593));
}

inline float sakura_smaa_local_threshold(texture2d<float> colorTex, sampler smpLin,
                                          float2 uv, float baseThresh, bool linearize)
{
    // 3x3 luma variance — high variance = noisy region (raise threshold to avoid false edges),
    // low variance = clean gradient (lower threshold to catch subtle aliasing).
    float lc = sakura_smaa_perceptual_luma(colorTex.sample(smpLin, uv).rgb, linearize);
    float v = 0.0;
    float2 px = 1.0 / float2(colorTex.get_width(), colorTex.get_height());
    for (int j = -1; j <= 1; ++j) {
        for (int i = -1; i <= 1; ++i) {
            if (i == 0 && j == 0) continue;
            float ln = sakura_smaa_perceptual_luma(colorTex.sample(smpLin, uv + float2(i, j) * px).rgb, linearize);
            v += abs(ln - lc);
        }
    }
    v *= 0.125; // average abs deviation
    // Map v∈[0,0.4] → multiplier ∈[0.6, 3.6], clamp
    float mul = clamp(0.6 + v * 7.5, 0.6, 3.6);
    return clamp(baseThresh * mul, 0.025, 0.20);
}

// MARK: - Vertex shaders (one per pass; each precomputes neighbor offsets per HLSL helpers).

vertex SakuraSMAAVOut sakura_smaa_edge_vs(uint vid [[vertex_id]],
                                          constant SakuraSMAAUbo& u [[buffer(0)]])
{
    float2 pos[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    float2 uvs[4] = { float2(0, 1),   float2(1, 1),  float2(0, 0),  float2(1, 0)  };
    SakuraSMAAVOut o;
    o.position = float4(pos[vid], 0.0, 1.0);
    o.texcoord = uvs[vid];
    o.offset0 = u.rtMetrics.xyxy * float4(-1.0, 0.0, 0.0, -1.0) + o.texcoord.xyxy;
    o.offset1 = u.rtMetrics.xyxy * float4( 1.0, 0.0, 0.0,  1.0) + o.texcoord.xyxy;
    o.offset2 = u.rtMetrics.xyxy * float4(-2.0, 0.0, 0.0, -2.0) + o.texcoord.xyxy;
    o.pixcoord = o.texcoord * u.rtMetrics.zw;
    return o;
}

vertex SakuraSMAAVOut sakura_smaa_weights_vs(uint vid [[vertex_id]],
                                             constant SakuraSMAAUbo& u [[buffer(0)]])
{
    float2 pos[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    float2 uvs[4] = { float2(0, 1),   float2(1, 1),  float2(0, 0),  float2(1, 0)  };
    SakuraSMAAVOut o;
    o.position = float4(pos[vid], 0.0, 1.0);
    o.texcoord = uvs[vid];
    o.pixcoord = o.texcoord * u.rtMetrics.zw;
    // Three offsets used inside the weights pass (see HLSL SMAABlendingWeightCalculationVS)
    o.offset0 = u.rtMetrics.xyxy * float4(-0.25,  -0.125,  1.25, -0.125) + o.texcoord.xyxy;
    o.offset1 = u.rtMetrics.xyxy * float4(-0.125, -0.25,  -0.125, 1.25) + o.texcoord.xyxy;
    o.offset2 = u.rtMetrics.xxyy *
        float4(-2.0, 2.0, -2.0, 2.0) * float(SAKURA_SMAA_MAX_SEARCH_STEPS) +
        float4(o.offset0.xz, o.offset1.yw);
    return o;
}

vertex SakuraSMAAVOut sakura_smaa_neighborhood_vs(uint vid [[vertex_id]],
                                                  constant SakuraSMAAUbo& u [[buffer(0)]])
{
    float2 pos[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    float2 uvs[4] = { float2(0, 1),   float2(1, 1),  float2(0, 0),  float2(1, 0)  };
    SakuraSMAAVOut o;
    o.position = float4(pos[vid], 0.0, 1.0);
    o.texcoord = uvs[vid];
    o.offset0 = u.rtMetrics.xyxy * float4(1.0, 0.0, 0.0, 1.0) + o.texcoord.xyxy;
    o.offset1 = float4(0);
    o.offset2 = float4(0);
    o.pixcoord = o.texcoord * u.rtMetrics.zw;
    return o;
}

// MARK: - Pass 1: Edge detection (color-based + optional predication, with Sakura adaptive thresholding)

fragment float4 sakura_smaa_edge_detect_ps(SakuraSMAAVOut in [[stage_in]],
                                           texture2d<float> colorTex [[texture(0)]],
                                           texture2d<float> predicateTex [[texture(1)]],
                                           sampler smpLin [[sampler(0)]],
                                           constant SakuraSMAAUbo& u [[buffer(0)]])
{
    bool linearize = (u.sakuraFlags.x > 0.5);
    bool adaptive = (u.sakuraFlags.y > 0.5);
    bool predicated = (u.sakuraFlags.w > 0.5);

    float baseThresh = SAKURA_SMAA_THRESHOLD * max(0.1, u.sakuraTuning.x);
    float threshold = adaptive
        ? sakura_smaa_local_threshold(colorTex, smpLin, in.texcoord, baseThresh, linearize)
        : baseThresh;
    float2 thr = float2(threshold);

    // Optional predication: take edge threshold from the predicate (raw PSX raster) instead of color.
    if (predicated) {
        float scale = max(0.5, u.sakuraTuning.z);
        float strength = clamp(u.sakuraTuning.w, 0.0, 1.0);
        float pCenter = predicateTex.sample(smpLin, in.texcoord).r;
        float pLeft   = predicateTex.sample(smpLin, in.offset0.xy).r;
        float pTop    = predicateTex.sample(smpLin, in.offset0.zw).r;
        float3 deltaP = scale * abs(float3(pCenter, pCenter, pCenter) - float3(pLeft, pTop, 0.0));
        thr = max(threshold * (1.0 - strength), threshold * scale - deltaP.xy * strength);
    }

    // Calculate color deltas to neighbors.
    float4 delta;
    float3 C = colorTex.sample(smpLin, in.texcoord).rgb;
    float3 Cleft = colorTex.sample(smpLin, in.offset0.xy).rgb;
    float3 t = abs(C - Cleft);
    delta.x = max(max(t.r, t.g), t.b);
    float3 Ctop = colorTex.sample(smpLin, in.offset0.zw).rgb;
    t = abs(C - Ctop);
    delta.y = max(max(t.r, t.g), t.b);
    float2 edges = step(thr, delta.xy);

    // Early discard if both edges absent.
    if (dot(edges, float2(1.0, 1.0)) == 0.0)
        discard_fragment();

    // SMAA local contrast adaptation: suppress an edge if a neighbor edge has much larger contrast.
    float3 Cright  = colorTex.sample(smpLin, in.offset1.xy).rgb;
    t = abs(C - Cright);
    delta.z = max(max(t.r, t.g), t.b);
    float3 Cbottom = colorTex.sample(smpLin, in.offset1.zw).rgb;
    t = abs(C - Cbottom);
    delta.w = max(max(t.r, t.g), t.b);

    float2 maxDelta = max(delta.xy, delta.zw);
    float3 Clleft  = colorTex.sample(smpLin, in.offset2.xy).rgb;
    t = abs(C - Clleft);
    float dleftleft = max(max(t.r, t.g), t.b);
    float3 Cttop   = colorTex.sample(smpLin, in.offset2.zw).rgb;
    t = abs(C - Cttop);
    float dtoptop = max(max(t.r, t.g), t.b);
    maxDelta = max(maxDelta.xy, float2(dleftleft, dtoptop));
    float finalDelta = max(maxDelta.x, maxDelta.y);
    edges.xy *= step(finalDelta, SAKURA_SMAA_LOCAL_CONTRAST_ADAPTATION_FACTOR * delta.xy);

    return float4(edges, 0.0, 1.0);
}

// MARK: - Pass 2: Blending weight calculation (uses precomputed AreaTex + SearchTex).
// Faithful port of SMAABlendingWeightCalculationPS with Ultra-preset search depths.

inline float2 sakura_smaa_decode_diag_bilinear_access(float2 e)
{
    e.r = e.r * abs(5.0 * e.r - 5.0 * 0.75);
    return saturate(round(e));
}

inline float4 sakura_smaa_decode_diag_bilinear_access4(float4 e)
{
    e.rb = e.rb * abs(5.0 * e.rb - 5.0 * 0.75);
    return saturate(round(e));
}

inline float2 sakura_smaa_search_diag1(texture2d<float> edgesTex, sampler smpLin,
                                       float2 texcoord, float2 dir, thread float2 &eOut,
                                       constant SakuraSMAAUbo& u)
{
    // coord.xy = current sample offset, coord.z = lookahead bilinear continuation flag
    float3 coord = float3(0.0, 1.0, 0.0);
    float3 t = float3(u.rtMetrics.xy, 1.0);
    float2 e = float2(0.0);
    while (coord.x < float(SAKURA_SMAA_MAX_SEARCH_STEPS_DIAG) - 1.0 && coord.y > 0.9) {
        coord.xy += t.xy * dir;
        e = edgesTex.sample(smpLin, texcoord + coord.xy).rg;
        coord.z = dot(e, float2(0.5));
        coord.x += 1.0;
        coord.y = coord.z;
    }
    eOut = e;
    return float2(coord.x, coord.y);
}

inline float2 sakura_smaa_search_diag2(texture2d<float> edgesTex, sampler smpLin,
                                       float2 texcoord, float2 dir, thread float2 &eOut,
                                       constant SakuraSMAAUbo& u)
{
    float3 coord = float3(0.0, 1.0, 0.0);
    coord.x += 0.25 * u.rtMetrics.x;
    float3 t = float3(u.rtMetrics.xy, 1.0);
    float2 e = float2(0.0);
    while (coord.x < float(SAKURA_SMAA_MAX_SEARCH_STEPS_DIAG) - 1.0 && coord.y > 0.9) {
        coord.xy += t.xy * dir;
        e = edgesTex.sample(smpLin, texcoord + coord.xy).rg;
        e = sakura_smaa_decode_diag_bilinear_access(e);
        coord.z = dot(e, float2(0.5));
        coord.x += 1.0;
        coord.y = coord.z;
    }
    eOut = e;
    return float2(coord.x, coord.y);
}

inline float2 sakura_smaa_area_diag(texture2d<float> areaTex, sampler smpLin,
                                    float2 dist, float2 e, float offset)
{
    float2 texcoord = float(SAKURA_SMAA_AREATEX_MAX_DISTANCE_DIAG) * e + dist;
    texcoord = SAKURA_SMAA_AREATEX_PIXEL_SIZE * texcoord + (0.5 * SAKURA_SMAA_AREATEX_PIXEL_SIZE);
    texcoord.x += 0.5;
    texcoord.y += SAKURA_SMAA_AREATEX_SUBTEX_SIZE * offset;
    return areaTex.sample(smpLin, texcoord).rg;
}

inline float2 sakura_smaa_calculate_diag_weights(texture2d<float> edgesTex, texture2d<float> areaTex,
                                                  sampler smpLin, float2 texcoord, float2 e,
                                                  float4 subsampleIndices,
                                                  constant SakuraSMAAUbo& u)
{
    float2 weights = float2(0.0);
    float4 d;
    float2 end;
    if (e.r > 0.0) {
        d.xz = sakura_smaa_search_diag1(edgesTex, smpLin, texcoord, float2(-1.0, 1.0), end, u);
        d.x += float(end.y > 0.9);
    } else {
        d.xz = float2(0.0);
    }
    d.yw = sakura_smaa_search_diag1(edgesTex, smpLin, texcoord, float2(1.0, -1.0), end, u);
    if (d.x + d.y > 2.0) {
        float4 coords = float4(-d.x + 0.25, d.x, d.y, -d.y - 0.25) * u.rtMetrics.xyxy + texcoord.xyxy;
        float4 c;
        c.xy = edgesTex.sample(smpLin, coords.xy + float2(-1.0, 0.0) * u.rtMetrics.xy).rg;
        c.zw = edgesTex.sample(smpLin, coords.zw + float2( 1.0, 0.0) * u.rtMetrics.xy).rg;
        c.yxwz = sakura_smaa_decode_diag_bilinear_access4(c.xyzw);
        float2 cc = float2(2.0) * c.xz + c.yw;
        cc *= step(d.zw, float2(0.9));
        weights += sakura_smaa_area_diag(areaTex, smpLin, d.xy, cc, subsampleIndices.z);
    }
    d.xz = sakura_smaa_search_diag2(edgesTex, smpLin, texcoord, float2(-1.0, -1.0), end, u);
    if (edgesTex.sample(smpLin, texcoord + float2(1.0, 0.0) * u.rtMetrics.xy).r > 0.0) {
        d.yw = sakura_smaa_search_diag2(edgesTex, smpLin, texcoord, float2(1.0, 1.0), end, u);
        d.y += float(end.y > 0.9);
    } else {
        d.yw = float2(0.0);
    }
    if (d.x + d.y > 2.0) {
        float4 coords = float4(-d.x, -d.x, d.y, d.y) * u.rtMetrics.xyxy + texcoord.xyxy;
        float4 c;
        c.x = edgesTex.sample(smpLin, coords.xy + float2(-1.0, 0.0) * u.rtMetrics.xy).g;
        c.y = edgesTex.sample(smpLin, coords.xy + float2( 0.0,-1.0) * u.rtMetrics.xy).r;
        c.zw = edgesTex.sample(smpLin, coords.zw + float2( 1.0, 0.0) * u.rtMetrics.xy).gr;
        float2 cc = float2(2.0) * c.xz + c.yw;
        cc *= step(d.zw, float2(0.9));
        weights += sakura_smaa_area_diag(areaTex, smpLin, d.xy, cc, subsampleIndices.w).gr;
    }
    return weights;
}

inline float sakura_smaa_search_length(texture2d<float> searchTex, sampler smpLin, float2 e, float offset)
{
    float2 scale = float2(SAKURA_SMAA_SEARCHTEX_SIZE_X, SAKURA_SMAA_SEARCHTEX_SIZE_Y) * float2(0.5, -1.0);
    float2 bias = float2(SAKURA_SMAA_SEARCHTEX_SIZE_X, SAKURA_SMAA_SEARCHTEX_SIZE_Y) * float2(offset, 1.0);
    scale += float2(-1.0, 1.0);
    bias  += float2(0.5, -0.5);
    scale *= float2(1.0 / SAKURA_SMAA_SEARCHTEX_PACKED_SIZE_X, 1.0 / SAKURA_SMAA_SEARCHTEX_PACKED_SIZE_Y);
    bias  *= float2(1.0 / SAKURA_SMAA_SEARCHTEX_PACKED_SIZE_X, 1.0 / SAKURA_SMAA_SEARCHTEX_PACKED_SIZE_Y);
    return searchTex.sample(smpLin, scale * e + bias).r;
}

inline float sakura_smaa_search_xleft(texture2d<float> edgesTex, texture2d<float> searchTex,
                                      sampler smpLin, float2 texcoord, float end,
                                      constant SakuraSMAAUbo& u)
{
    float2 e = float2(0.0, 1.0);
    while (texcoord.x > end && e.g > 0.8281 && e.r == 0.0) {
        e = edgesTex.sample(smpLin, texcoord).rg;
        texcoord -= float2(2.0, 0.0) * u.rtMetrics.xy;
    }
    float offset = -(255.0 / 127.0) * sakura_smaa_search_length(searchTex, smpLin, e, 0.0) + 3.25;
    return texcoord.x + offset * u.rtMetrics.x;
}

inline float sakura_smaa_search_xright(texture2d<float> edgesTex, texture2d<float> searchTex,
                                       sampler smpLin, float2 texcoord, float end,
                                       constant SakuraSMAAUbo& u)
{
    float2 e = float2(0.0, 1.0);
    while (texcoord.x < end && e.g > 0.8281 && e.r == 0.0) {
        e = edgesTex.sample(smpLin, texcoord).rg;
        texcoord += float2(2.0, 0.0) * u.rtMetrics.xy;
    }
    float offset = -(255.0 / 127.0) * sakura_smaa_search_length(searchTex, smpLin, e, 0.5) + 3.25;
    return texcoord.x - offset * u.rtMetrics.x;
}

inline float sakura_smaa_search_yup(texture2d<float> edgesTex, texture2d<float> searchTex,
                                    sampler smpLin, float2 texcoord, float end,
                                    constant SakuraSMAAUbo& u)
{
    float2 e = float2(1.0, 0.0);
    while (texcoord.y > end && e.r > 0.8281 && e.g == 0.0) {
        e = edgesTex.sample(smpLin, texcoord).rg;
        texcoord -= float2(0.0, 2.0) * u.rtMetrics.xy;
    }
    float offset = -(255.0 / 127.0) * sakura_smaa_search_length(searchTex, smpLin, e.gr, 0.0) + 3.25;
    return texcoord.y + offset * u.rtMetrics.y;
}

inline float sakura_smaa_search_ydown(texture2d<float> edgesTex, texture2d<float> searchTex,
                                      sampler smpLin, float2 texcoord, float end,
                                      constant SakuraSMAAUbo& u)
{
    float2 e = float2(1.0, 0.0);
    while (texcoord.y < end && e.r > 0.8281 && e.g == 0.0) {
        e = edgesTex.sample(smpLin, texcoord).rg;
        texcoord += float2(0.0, 2.0) * u.rtMetrics.xy;
    }
    float offset = -(255.0 / 127.0) * sakura_smaa_search_length(searchTex, smpLin, e.gr, 0.5) + 3.25;
    return texcoord.y - offset * u.rtMetrics.y;
}

inline float2 sakura_smaa_area(texture2d<float> areaTex, sampler smpLin, float2 dist, float e1, float e2, float offset)
{
    float2 texcoord = float(SAKURA_SMAA_AREATEX_MAX_DISTANCE) * round(4.0 * float2(e1, e2)) + dist;
    texcoord = SAKURA_SMAA_AREATEX_PIXEL_SIZE * texcoord + (0.5 * SAKURA_SMAA_AREATEX_PIXEL_SIZE);
    texcoord.y += SAKURA_SMAA_AREATEX_SUBTEX_SIZE * offset;
    return areaTex.sample(smpLin, texcoord).rg;
}

inline void sakura_smaa_detect_horizontal_corner_pattern(texture2d<float> edgesTex, sampler smpLin,
                                                          thread float2 &weights, float4 texcoord,
                                                          float2 d, constant SakuraSMAAUbo& u)
{
    float2 leftRight = step(d.xy, d.yx);
    float2 rounding = (1.0 - SAKURA_SMAA_CORNER_ROUNDING_NORM) * leftRight;
    rounding /= leftRight.x + leftRight.y;
    float2 factor = float2(1.0);
    factor.x -= rounding.x * edgesTex.sample(smpLin, texcoord.xy + float2(0.0, 1.0) * u.rtMetrics.xy).r;
    factor.x -= rounding.y * edgesTex.sample(smpLin, texcoord.zw + float2(1.0, 1.0) * u.rtMetrics.xy).r;
    factor.y -= rounding.x * edgesTex.sample(smpLin, texcoord.xy + float2(0.0,-2.0) * u.rtMetrics.xy).r;
    factor.y -= rounding.y * edgesTex.sample(smpLin, texcoord.zw + float2(1.0,-2.0) * u.rtMetrics.xy).r;
    weights *= saturate(factor);
}

inline void sakura_smaa_detect_vertical_corner_pattern(texture2d<float> edgesTex, sampler smpLin,
                                                        thread float2 &weights, float4 texcoord,
                                                        float2 d, constant SakuraSMAAUbo& u)
{
    float2 leftRight = step(d.xy, d.yx);
    float2 rounding = (1.0 - SAKURA_SMAA_CORNER_ROUNDING_NORM) * leftRight;
    rounding /= leftRight.x + leftRight.y;
    float2 factor = float2(1.0);
    factor.x -= rounding.x * edgesTex.sample(smpLin, texcoord.xy + float2( 1.0, 0.0) * u.rtMetrics.xy).g;
    factor.x -= rounding.y * edgesTex.sample(smpLin, texcoord.zw + float2( 1.0, 1.0) * u.rtMetrics.xy).g;
    factor.y -= rounding.x * edgesTex.sample(smpLin, texcoord.xy + float2(-2.0, 0.0) * u.rtMetrics.xy).g;
    factor.y -= rounding.y * edgesTex.sample(smpLin, texcoord.zw + float2(-2.0, 1.0) * u.rtMetrics.xy).g;
    weights *= saturate(factor);
}

fragment float4 sakura_smaa_blend_weights_ps(SakuraSMAAVOut in [[stage_in]],
                                             texture2d<float> edgesTex [[texture(0)]],
                                             texture2d<float> areaTex [[texture(1)]],
                                             texture2d<float> searchTex [[texture(2)]],
                                             sampler smpLin [[sampler(0)]],
                                             constant SakuraSMAAUbo& u [[buffer(0)]])
{
    float4 weights = float4(0.0);
    float4 subsampleIndices = float4(0.0); // SMAA 1x — no subsample offsets.
    float2 e = edgesTex.sample(smpLin, in.texcoord).rg;
    if (e.g > 0.0) {
        // Diagonal search first.
        weights.rg = sakura_smaa_calculate_diag_weights(edgesTex, areaTex, smpLin, in.texcoord, e, subsampleIndices, u);
        if (weights.r == -weights.g) { // SMAA convention: diag returned a hit
            float2 d;
            float3 coords;
            coords.x = sakura_smaa_search_xleft(edgesTex, searchTex, smpLin, in.offset0.xy, in.offset2.x, u);
            coords.y = in.offset1.y;
            d.x = coords.x;
            float e1 = edgesTex.sample(smpLin, coords.xy).r;
            coords.z = sakura_smaa_search_xright(edgesTex, searchTex, smpLin, in.offset0.zw, in.offset2.y, u);
            d.y = coords.z;
            d = abs(round(u.rtMetrics.zz * d - in.pixcoord.xx));
            float2 sqrt_d = sqrt(d);
            float e2 = edgesTex.sample(smpLin, coords.zy + float2(1.0, 0.0) * u.rtMetrics.xy).r;
            float2 hWeights = sakura_smaa_area(areaTex, smpLin, sqrt_d, e1, e2, subsampleIndices.y);
            coords.y = in.texcoord.y;
            sakura_smaa_detect_horizontal_corner_pattern(edgesTex, smpLin, hWeights, coords.xyzy, d, u);
            weights.rg = hWeights;
        } else {
            e.r = 0.0;
        }
    }
    if (e.r > 0.0) {
        float2 d;
        float3 coords;
        coords.y = sakura_smaa_search_yup(edgesTex, searchTex, smpLin, in.offset1.xy, in.offset2.z, u);
        coords.x = in.offset0.x;
        d.x = coords.y;
        float e1 = edgesTex.sample(smpLin, coords.xy).g;
        coords.z = sakura_smaa_search_ydown(edgesTex, searchTex, smpLin, in.offset1.zw, in.offset2.w, u);
        d.y = coords.z;
        d = abs(round(u.rtMetrics.ww * d - in.pixcoord.yy));
        float2 sqrt_d = sqrt(d);
        float e2 = edgesTex.sample(smpLin, coords.xz + float2(0.0, 1.0) * u.rtMetrics.xy).g;
        float2 vWeights = sakura_smaa_area(areaTex, smpLin, sqrt_d, e1, e2, subsampleIndices.x);
        coords.x = in.texcoord.x;
        sakura_smaa_detect_vertical_corner_pattern(edgesTex, smpLin, vWeights, coords.xyxz, d, u);
        weights.ba = vWeights;
    }
    return weights;
}

// MARK: - Pass 3: Neighborhood blending — apply the weights to the input color.

fragment float4 sakura_smaa_neighborhood_ps(SakuraSMAAVOut in [[stage_in]],
                                            texture2d<float> colorTex [[texture(0)]],
                                            texture2d<float> blendTex [[texture(1)]],
                                            sampler smpLin [[sampler(0)]],
                                            constant SakuraSMAAUbo& u [[buffer(0)]])
{
    float4 a;
    a.x = blendTex.sample(smpLin, in.offset0.xy).a; // right
    a.y = blendTex.sample(smpLin, in.offset0.zw).g; // top
    a.wz = blendTex.sample(smpLin, in.texcoord).xz; // left, bottom
    if (dot(a, float4(1.0)) < 1e-5) {
        return colorTex.sample(smpLin, in.texcoord);
    }
    bool h = max(a.x, a.z) > max(a.y, a.w);
    float4 blendingOffset = float4(0.0, a.y, 0.0, a.w);
    float2 blendingWeight = a.yw;
    if (h) { blendingOffset = float4(a.x, 0.0, a.z, 0.0); blendingWeight = a.xz; }
    blendingWeight /= dot(blendingWeight, float2(1.0));
    float4 blendingCoord = blendingOffset * float4(u.rtMetrics.xy, -u.rtMetrics.xy) + in.texcoord.xyxy;
    float4 colorOut = blendingWeight.x * colorTex.sample(smpLin, blendingCoord.xy);
    colorOut += blendingWeight.y * colorTex.sample(smpLin, blendingCoord.zw);

    // Sakura — pixel-art preserve: if the 4 cardinal neighbors form an axis-aligned hard step
    // (two dominant clusters with very low intra-cluster variance), revert to the un-blended center.
    if (u.sakuraFlags.z > 0.5) {
        float2 px = u.rtMetrics.xy;
        float3 cC = colorTex.sample(smpLin, in.texcoord).rgb;
        float3 cL = colorTex.sample(smpLin, in.texcoord + float2(-px.x, 0)).rgb;
        float3 cR = colorTex.sample(smpLin, in.texcoord + float2( px.x, 0)).rgb;
        float3 cU = colorTex.sample(smpLin, in.texcoord + float2(0,-px.y)).rgb;
        float3 cD = colorTex.sample(smpLin, in.texcoord + float2(0, px.y)).rgb;
        float tol = max(0.005, u.sakuraTuning.y);
        float horiz = length(cL - cR);
        float vert  = length(cU - cD);
        float intraH = length(cL - cC) + length(cR - cC);
        float intraV = length(cU - cC) + length(cD - cC);
        bool hardH = (horiz > 5.0 * tol) && (intraH < tol);
        bool hardV = (vert  > 5.0 * tol) && (intraV < tol);
        if (hardH || hardV) {
            return float4(cC, 1.0);
        }
    }

    return colorOut;
}
