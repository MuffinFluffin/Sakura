#include <metal_stdlib>
using namespace metal;

#define A_GPU 1
#define A_HLSL 1
#define FSR_EASU_F 1

inline uint sakura_f32tof16_bits(float x) { return uint(as_type<uint16_t>(half(x))); }
inline float sakura_f16tof32_bits(uint h) {
    return float(half(as_type<uint16_t>((ushort)(h & 0xffffu))));
}
#define f32tof16(x) sakura_f32tof16_bits(float(x))
#define f16tof32(x) sakura_f16tof32_bits(uint(x))

#ifndef D3DCOLORtoUBYTE4
#define D3DCOLORtoUBYTE4(x) uint4(0u)
#endif

#include "third_party/FidelityFX-FSR/ffx-fsr/ffx_a_sakura_metal.h"
#include "third_party/FidelityFX-FSR/ffx-fsr/ffx_fsr1_sakura.h"

struct VSOut { float4 position [[position]]; float2 uv; };

vertex VSOut vertex_main(uint vid [[vertex_id]])
{
    float2 pos[4] = { float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0), float2(1.0, 1.0) };
    float2 uvs[4] = { float2(0.0, 1.0), float2(1.0, 1.0), float2(0.0, 0.0), float2(1.0, 0.0) };
    VSOut o;
    o.position = float4(pos[vid], 0.0, 1.0);
    o.uv = uvs[vid];
    return o;
}

struct PresUbo {
    int4 packed;
    float4 ts;
    uint4 easuCon0;
    uint4 easuCon1;
    uint4 easuCon2;
    uint4 easuCon3;
    float4 dims;
    float4 uvRect;
    float4 color0;
    float4 color1;
    float4 color2;
    float4 hdr0;
    float4 hdr1;
};

static float lum(float3 c) { return dot(c, float3(0.299, 0.587, 0.114)); }

static float luma_bt709(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

static float3 sampleN(texture2d<float> tex, sampler s, int2 p, int2 mx, uint w, uint h)
{
    p = clamp(p, int2(0), mx);
    float2 uv = (float2(p) + 0.5) / float2(float(w), float(h));
    return tex.sample(s, uv).rgb;
}

static float edge_amt(texture2d<float> tex, sampler sn, float2 uv, uint w, uint h)
{
    int2 mx = int2(int(w) - 1, int(h) - 1);
    float2 pd = uv * float2(float(w), float(h)) - 0.5;
    int2 c = clamp(int2(floor(pd + 0.5)), int2(0), mx);
    float lcc = lum(sampleN(tex, sn, c, mx, w, h));
    float g =
        fabs(lcc - lum(sampleN(tex, sn, c + int2(-1, 0), mx, w, h))) +
        fabs(lcc - lum(sampleN(tex, sn, c + int2(1, 0), mx, w, h))) +
        fabs(lcc - lum(sampleN(tex, sn, c + int2(0, -1), mx, w, h))) +
        fabs(lcc - lum(sampleN(tex, sn, c + int2(0, 1), mx, w, h)));
    return clamp(g * 1.8, 0.0, 1.0);
}

static float3 filter_three_point(texture2d<float> tex, sampler sn, float2 uv, uint w, uint h)
{
    float2 p = uv * float2(float(w), float(h)) - 0.5;
    int2 i = int2(floor(p));
    float2 f = p - float2(i);
    int2 mx = int2(int(w) - 1, int(h) - 1);
    float3 s00 = sampleN(tex, sn, i + int2(0, 0), mx, w, h);
    float3 s10 = sampleN(tex, sn, i + int2(1, 0), mx, w, h);
    float3 s01 = sampleN(tex, sn, i + int2(0, 1), mx, w, h);
    float3 s11 = sampleN(tex, sn, i + int2(1, 1), mx, w, h);
    if (f.x + f.y <= 1.0) {
        float w0 = 1.0 - f.x - f.y;
        return s00 * w0 + s10 * f.x + s01 * f.y;
    }
    float w11 = f.x + f.y - 1.0;
    float w10 = 1.0 - f.y;
    float w01 = 1.0 - f.x;
    return s11 * w11 + s10 * w10 + s01 * w01;
}

static float3 filter_sabr(texture2d<float> tex, sampler sn, float2 uv, uint w, uint h)
{
    float2 p = uv * float2(float(w), float(h)) - 0.5;
    int2 i = int2(floor(p));
    float2 f = p - float2(i);
    int2 mx = int2(int(w) - 1, int(h) - 1);
    float3 n00 = sampleN(tex, sn, i + int2(0, 0), mx, w, h);
    float3 n10 = sampleN(tex, sn, i + int2(1, 0), mx, w, h);
    float3 n01 = sampleN(tex, sn, i + int2(0, 1), mx, w, h);
    float3 n11 = sampleN(tex, sn, i + int2(1, 1), mx, w, h);
    float3 tlbr = mix(sampleN(tex, sn, i + int2(0, 0), mx, w, h),
                      sampleN(tex, sn, i + int2(1, 1), mx, w, h), clamp((f.x + f.y) * 0.5, 0.0, 1.0));
    float3 trbl = mix(sampleN(tex, sn, i + int2(1, 0), mx, w, h),
                      sampleN(tex, sn, i + int2(0, 1), mx, w, h), clamp((f.x + (1.0 - f.y)) * 0.5, 0.0, 1.0));
    float wl = 1.0 / (length(tlbr - trbl) + 0.06);
    float3 sab = mix(trbl, tlbr, wl / (wl + 1.0));
    float3 bil = mix(mix(n00, n10, f.x), mix(n01, n11, f.x), f.y);
    float e = edge_amt(tex, sn, uv, w, h);
    return mix(bil, sab, 0.28 + 0.62 * e);
}

static float3 filter_xbr(texture2d<float> tex, sampler sn, float2 uv, uint w, uint h)
{
    float2 p = uv * float2(float(w), float(h)) - 0.5;
    int2 i = int2(floor(p));
    float2 f = p - float2(i);
    int2 mx = int2(int(w) - 1, int(h) - 1);
    float3 B = sampleN(tex, sn, i + int2(0, -1), mx, w, h);
    float3 D = sampleN(tex, sn, i + int2(-1, 0), mx, w, h);
    float3 E = sampleN(tex, sn, i + int2(0, 0), mx, w, h);
    float3 F = sampleN(tex, sn, i + int2(1, 0), mx, w, h);
    float3 H = sampleN(tex, sn, i + int2(0, 1), mx, w, h);
    float el = lum(E);
    float wf = fabs(el - lum(F));
    float wd = fabs(el - lum(D));
    float wb = fabs(el - lum(B));
    float wh = fabs(el - lum(H));
    float sx = wd + wf + 1e-4;
    float sy = wb + wh + 1e-4;
    float3 xh = mix(D, F, f.x);
    float3 xv = mix(B, H, f.y);
    float k = smoothstep(0.32, 0.68, sx / (sx + sy));
    return mix(xv, xh, k);
}

static float3 filter_xbrz(texture2d<float> tex, sampler sn, float2 uv, uint w, uint h)
{
    float2 p = uv * float2(float(w), float(h)) - 0.5;
    int2 i = int2(floor(p));
    float2 f = p - float2(i);
    int2 mx = int2(int(w) - 1, int(h) - 1);
    float3 B = sampleN(tex, sn, i + int2(0, -1), mx, w, h);
    float3 D = sampleN(tex, sn, i + int2(-1, 0), mx, w, h);
    float3 E = sampleN(tex, sn, i + int2(0, 0), mx, w, h);
    float3 F = sampleN(tex, sn, i + int2(1, 0), mx, w, h);
    float3 H = sampleN(tex, sn, i + int2(0, 1), mx, w, h);
    float3 A = sampleN(tex, sn, i + int2(-1, -1), mx, w, h);
    float3 C = sampleN(tex, sn, i + int2(1, -1), mx, w, h);
    float3 G = sampleN(tex, sn, i + int2(-1, 1), mx, w, h);
    float3 Ip = sampleN(tex, sn, i + int2(1, 1), mx, w, h);
    float el = lum(E);
    float wf = fabs(el - lum(F));
    float wd = fabs(el - lum(D));
    float wb = fabs(el - lum(B));
    float wh = fabs(el - lum(H));
    float sx = wd + wf + 1e-4;
    float sy = wb + wh + 1e-4;
    float3 xh = mix(D, F, f.x);
    float3 xv = mix(B, H, f.y);
    float k = smoothstep(0.38, 0.62, sx / (sx + sy));
    float3 base = mix(xv, xh, k);
    float3 xd1 = mix(A, Ip, clamp((f.x + f.y) * 0.5, 0.0, 1.0));
    float3 xd2 = mix(C, G, clamp((f.x + (1.0 - f.y)) * 0.5, 0.0, 1.0));
    float dh = fabs(lum(D) - lum(F));
    float dv = fabs(lum(B) - lum(H));
    float dd = fabs(lum(A) - lum(Ip)) + fabs(lum(C) - lum(G));
    float em = max(max(dh, dv), dd);
    float cornerBlend = clamp(1.0 - em * 6.5, 0.0, 1.0);
    float3 diag = mix(xd1, xd2, step(f.y, f.x));
    return mix(base, diag, cornerBlend * 0.42);
}

static float3 filter_anime4k(texture2d<float> tex, sampler sl, float2 uv, uint w, uint h)
{
    float2 rcp = float2(1.0 / float(w), 1.0 / float(h));
    float3 ce = tex.sample(sl, uv).rgb;
    float3 L = tex.sample(sl, uv + float2(-rcp.x, 0)).rgb;
    float3 R = tex.sample(sl, uv + float2(rcp.x, 0)).rgb;
    float3 U = tex.sample(sl, uv + float2(0, -rcp.y)).rgb;
    float3 D = tex.sample(sl, uv + float2(0, rcp.y)).rgb;
    float3 gx = R - L;
    float3 gy = D - U;
    float de = length(gx) + length(gy);
    float dl = fabs(lum(L) + lum(R) + lum(U) + lum(D) - 4.0 * lum(ce));
    float edge = smoothstep(0.015, 0.14, dl) * smoothstep(0.012, 0.22, de);
    float2 dir = float2(lum(R) - lum(L), lum(D) - lum(U));
    float dm = length(dir) + 1e-5;
    dir /= dm;
    float3 gradPush = (gx * dir.x + gy * dir.y) * (0.22 * edge);
    return clamp(ce + gradPush, 0.0, 1.0);
}

static float3 filter_base(int fk, texture2d<float> tex, sampler sn, sampler sl, float2 uv, uint w, uint h)
{
    if (fk <= 0)
        return tex.sample(sn, uv).rgb;
    if (fk == 1)
        return tex.sample(sl, uv).rgb;
    if (fk == 2)
        return filter_three_point(tex, sn, uv, w, h);
    if (fk == 3)
        return filter_sabr(tex, sn, uv, w, h);
    if (fk == 4)
        return filter_xbr(tex, sn, uv, w, h);
    if (fk == 5)
        return filter_xbrz(tex, sn, uv, w, h);
    if (fk == 6)
        return tex.sample(sl, uv).rgb;
    if (fk == 7)
        return filter_anime4k(tex, sl, uv, w, h);
    return tex.sample(sl, uv).rgb;
}

static float3 apply_fxaa(float3 rgbCenter, texture2d<float> tex, sampler sn, float2 uv, float2 rcp)
{
    float lC = lum(rgbCenter);
    float lN = lum(tex.sample(sn, uv + float2(0, -rcp.y)).rgb);
    float lS = lum(tex.sample(sn, uv + float2(0, rcp.y)).rgb);
    float lW = lum(tex.sample(sn, uv + float2(-rcp.x, 0)).rgb);
    float lE = lum(tex.sample(sn, uv + float2(rcp.x, 0)).rgb);
    float r = max(max(lN, lS), max(lE, max(lW, lC))) - min(min(lN, lS), min(min(lE, lW), lC));
    if (r < 1.0 / 24.0)
        return rgbCenter;
    float2 dir = float2((lN + lS) - (lW + lE), (lW + lE) - (lN + lS));
    float dr = max((lN + lS + lW + lE + lC) * 0.03125, 0.0078125);
    float dm = min(abs(dir.x), abs(dir.y)) + dr;
    dir = clamp(dir / dm, float2(-10), float2(10)) * rcp * 0.55;
    float3 A = tex.sample(sn, uv + dir * float2(-1.2, -1.2)).rgb;
    float3 B = tex.sample(sn, uv + dir * float2(1.0, 1.0)).rgb;
    float3 C = tex.sample(sn, uv + dir * float2(-1.0, 1.0)).rgb;
    float3 D = tex.sample(sn, uv + dir * float2(1.0, -1.0)).rgb;
    return clamp((A + B + C + D) * 0.25, 0.0, 1.0);
}

static float3 apply_cas(float3 c, texture2d<float> tex, sampler sn, float2 uv, float2 rcp, float sharp)
{
    float3 a = tex.sample(sn, uv + float2(0, -rcp.y)).rgb;
    float3 b = tex.sample(sn, uv + float2(-rcp.x, 0)).rgb;
    float3 d = tex.sample(sn, uv + float2(rcp.x, 0)).rgb;
    float3 e = tex.sample(sn, uv + float2(0, rcp.y)).rgb;
    float3 mn = min(min(a, b), min(min(c, d), e));
    float3 mx = max(max(a, b), max(max(c, d), e));
    float3 mid = (mn + mx) * 0.5;
    float k = clamp(sharp * 0.92 + 0.1, 0.06, 1.42);
    float contr = length(mx - mn);
    float adapt = smoothstep(0.015, 0.38, contr);
    return clamp(c + (c - mid) * k * (0.5 + 0.5 * adapt), mn, mx);
}

static float3 disc_bloom_acc(texture2d<float> tex, sampler smpL, float2 uv, uint w, uint h, float bloomRadius)
{
    float2 tsb = float2(1.0 / float(w), 1.0 / float(h)) * bloomRadius;
    float2 offs[8] = {
        float2(-0.942, -0.399), float2(0.946, -0.769), float2(-0.094, -0.929),
        float2(0.345, 0.294), float2(-0.916, 0.458), float2(0.975, 0.756),
        float2(-0.383, 0.277), float2(0.443, -0.975),
    };
    float3 bloomAcc = float3(0);
    float tw = 0;
    for (int i = 0; i < 8; i++) {
        float3 s = tex.sample(smpL, uv + offs[i] * tsb).rgb;
        float wl = smoothstep(0.5, 1.0, luma_bt709(s));
        bloomAcc += s * wl;
        tw += wl;
    }
    if (tw > 0.001)
        bloomAcc /= tw;
    return bloomAcc;
}

static float3 grade_display_color_sdr(float3 rgb, float2 uv, texture2d<float> tex,
                                      sampler smpN, sampler smpL, uint w, uint h,
                                      float sat, float brightness, float contrast, float vibrance,
                                      float exposure, float gamma, float colorTemp, float sharpness,
                                      float bloomIntensity, float bloomRadius,
                                      float vignetteIntensity, float vignetteRadius)
{
    if (sharpness > 0.001) {
        float2 ts = float2(1.0 / float(w), 1.0 / float(h));
        float cL = luma_bt709(rgb);
        float tL = luma_bt709(tex.sample(smpN, uv + float2(0, -ts.y)).rgb);
        float bL = luma_bt709(tex.sample(smpN, uv + float2(0, ts.y)).rgb);
        float lL = luma_bt709(tex.sample(smpN, uv + float2(-ts.x, 0)).rgb);
        float rL = luma_bt709(tex.sample(smpN, uv + float2(ts.x, 0)).rgb);
        float edge = 4.0 * cL - tL - bL - lL - rL;
        rgb += rgb * edge * sharpness;
    }

    if (bloomIntensity > 0.001) {
        float3 bloomAcc = disc_bloom_acc(tex, smpL, uv, w, h, bloomRadius);
        rgb = mix(rgb, rgb + bloomAcc, bloomIntensity);
    }

    if (abs(exposure) > 0.001)
        rgb *= pow(2.0, exposure);

    if (abs(brightness) > 0.001)
        rgb += brightness;

    if (abs(contrast - 1.0) > 0.001)
        rgb = (rgb - 0.5) * contrast + 0.5;

    if (abs(sat - 1.0) > 0.001) {
        float lm = luma_bt709(rgb);
        rgb = mix(float3(lm), rgb, sat);
    }

    if (abs(vibrance) > 0.001) {
        float maxC = max(rgb.r, max(rgb.g, rgb.b));
        float minC = min(rgb.r, min(rgb.g, rgb.b));
        float satm = (maxC - minC) / max(maxC, 0.001);
        float vf = vibrance * (1.0 - satm);
        float lm2 = luma_bt709(rgb);
        rgb = mix(float3(lm2), rgb, 1.0 + vf);
    }

    if (abs(gamma - 1.0) > 0.001)
        rgb = pow(max(rgb, float3(0)), float3(1.0 / gamma));

    if (abs(colorTemp) > 0.001) {
        float t = colorTemp;
        rgb.r *= 1.0 + t * 0.2;
        rgb.b *= 1.0 - t * 0.2;
        rgb.g *= 1.0 + t * 0.02;
    }

    if (vignetteIntensity > 0.001) {
        float2 center = uv - 0.5;
        float dist = length(center) * vignetteRadius;
        float vig = 1.0 - smoothstep(0.4, 1.0, dist);
        rgb *= mix(1.0, vig, vignetteIntensity);
    }

    return clamp(rgb, 0.0, 1.0);
}

static float3 grade_display_color_hdr(float3 rgb, float2 uv, texture2d<float> tex,
                                      sampler smpN, sampler smpL, uint w, uint h,
                                      float sat, float brightness, float contrast, float vibrance,
                                      float exposure, float gamma, float colorTemp, float sharpness,
                                      float bloomRadius,
                                      float vignetteIntensity, float vignetteRadius,
                                      float hdrExposure, float hdrSaturation, float hdrContrast, float hdrBloom,
                                      float shadowLift, float highlightCompress)
{
    if (sharpness > 0.001) {
        float2 ts = float2(1.0 / float(w), 1.0 / float(h));
        float cL = luma_bt709(rgb);
        float tL = luma_bt709(tex.sample(smpN, uv + float2(0, -ts.y)).rgb);
        float bL = luma_bt709(tex.sample(smpN, uv + float2(0, ts.y)).rgb);
        float lL = luma_bt709(tex.sample(smpN, uv + float2(-ts.x, 0)).rgb);
        float rL = luma_bt709(tex.sample(smpN, uv + float2(ts.x, 0)).rgb);
        float edge = 4.0 * cL - tL - bL - lL - rL;
        rgb += rgb * edge * sharpness;
    }

    if (abs(exposure) > 0.001)
        rgb *= pow(2.0, exposure);

    if (abs(brightness) > 0.001) {
        float lumv = max(luma_bt709(rgb), 0.001);
        rgb *= (lumv + brightness) / lumv;
    }

    if (abs(contrast - 1.0) > 0.001) {
        float lumv = luma_bt709(rgb);
        float midpoint = min(lumv, 1.0) * 0.5;
        rgb = (rgb - midpoint) * contrast + midpoint;
    }

    if (abs(sat - 1.0) > 0.001) {
        float lm = luma_bt709(rgb);
        rgb = mix(float3(lm), rgb, sat);
    }

    if (abs(vibrance) > 0.001) {
        float maxC = max(rgb.r, max(rgb.g, rgb.b));
        float minC = min(rgb.r, min(rgb.g, rgb.b));
        float satm = (maxC - minC) / max(maxC, 0.001);
        float vf = vibrance * (1.0 - satm);
        float lm = luma_bt709(rgb);
        rgb = mix(float3(lm), rgb, 1.0 + vf);
    }

    if (abs(gamma - 1.0) > 0.001) {
        float lum = luma_bt709(rgb);
        float sdrLum = min(lum, 1.0);
        float hdrExtra = max(lum - 1.0, 0.0);
        float corrected = pow(max(sdrLum, 0.0), 1.0 / gamma);
        float scale = (lum > 0.001) ? (corrected + hdrExtra) / lum : 1.0;
        rgb *= scale;
    }

    if (abs(colorTemp) > 0.001) {
        float t = colorTemp;
        rgb.r *= 1.0 + t * 0.2;
        rgb.b *= 1.0 - t * 0.2;
        rgb.g *= 1.0 + t * 0.02;
    }

    if (abs(hdrExposure) > 0.001)
        rgb *= pow(2.0, hdrExposure);

    if (abs(hdrSaturation - 1.0) > 0.001) {
        float lm = luma_bt709(rgb);
        rgb = mix(float3(lm), rgb, hdrSaturation);
    }

    if (abs(hdrContrast - 1.0) > 0.001) {
        float lm = luma_bt709(rgb);
        rgb = (rgb - lm) * hdrContrast + lm;
    }

    if (shadowLift > 0.001) {
        float lm = luma_bt709(rgb);
        float mask = 1.0 - smoothstep(0.0, 0.3, lm);
        rgb += shadowLift * mask;
    }

    if (highlightCompress > 0.001) {
        float lm = luma_bt709(rgb);
        if (lm > 1.0) {
            float compressed = 1.0 + (lm - 1.0) * (1.0 - highlightCompress);
            rgb *= compressed / lm;
        }
    }

    if (hdrBloom > 0.001) {
        float3 hb = disc_bloom_acc(tex, smpL, uv, w, h, bloomRadius);
        rgb += hb * hdrBloom * 2.0;
    }

    if (vignetteIntensity > 0.001) {
        float2 center = uv - 0.5;
        float dist = length(center) * vignetteRadius;
        float vig = 1.0 - smoothstep(0.4, 1.0, dist);
        rgb *= mix(1.0, vig, vignetteIntensity);
    }

    return max(rgb, float3(0));
}

fragment float4 fragment_pres(VSOut in [[stage_in]], texture2d<float> frame [[texture(0)]],
                              sampler smpN [[sampler(0)]], sampler smpL [[sampler(1)]],
                              constant PresUbo& u [[buffer(0)]])
{
    uint w = frame.get_width(), h = frame.get_height();
    if (w < 1u || h < 1u)
        return float4(0, 0, 0, 1);
    float2 tuv = mix(u.uvRect.xy, u.uvRect.zw, in.uv);
    int fkIn = u.packed.x;
    bool cropped = (u.uvRect.x > 0.001 || u.uvRect.y > 0.001 || u.uvRect.z < 0.999 || u.uvRect.w < 0.999);
    int fk = (cropped && fkIn == 6) ? 1 : fkIn;
    float outW = max(u.dims.x, 1.0);
    float outH = max(u.dims.y, 1.0);
    float3 rgb;
    if (fk == 6) {
        AF3 epix;
        uint2 ip = uint2(uint(in.uv.x * outW), uint(in.uv.y * outH));
        FsrEasuF(epix, AU2(ip.x, ip.y), u.easuCon0, u.easuCon1, u.easuCon2, u.easuCon3, frame, smpL);
        rgb = float3(epix);
    } else {
        rgb = filter_base(fk, frame, smpN, smpL, tuv, w, h);
    }
    if (u.packed.y != 0) {
        float2 rcp = float2(u.ts.x > 0 ? u.ts.x : 1.0 / float(w), u.ts.y > 0 ? u.ts.y : 1.0 / float(h));
        rgb = apply_fxaa(rgb, frame, smpN, tuv, rcp);
    }
    if (u.packed.z != 0) {
        float2 rcp = float2(1.0 / float(w), 1.0 / float(h));
        rgb = apply_cas(rgb, frame, smpN, tuv, rcp, u.ts.z);
    }
    if (u.packed.w != 0) {
        if (u.ts.w >= 0.5) {
            rgb = grade_display_color_hdr(
                rgb, tuv, frame, smpN, smpL, w, h,
                u.color0.x, u.color0.y, u.color0.z, u.color0.w,
                u.color1.x, u.color1.y, u.color1.z, u.color1.w,
                u.color2.y,
                u.color2.z, u.color2.w,
                u.hdr0.x, u.hdr0.y, u.hdr0.z, u.hdr0.w,
                u.hdr1.x, u.hdr1.y);
        } else {
            rgb = grade_display_color_sdr(
                rgb, tuv, frame, smpN, smpL, w, h,
                u.color0.x, u.color0.y, u.color0.z, u.color0.w,
                u.color1.x, u.color1.y, u.color1.z, u.color1.w,
                u.color2.x, u.color2.y, u.color2.z, u.color2.w);
        }
    }
    return float4(rgb, 1.0);
}

fragment float4 fragment_main(VSOut in [[stage_in]], texture2d<float> frame [[texture(0)]], sampler smp [[sampler(0)]],
                              constant float4& uvRect [[buffer(0)]])
{
    float2 uv = mix(uvRect.xy, uvRect.zw, in.uv);
    return frame.sample(smp, uv);
}

fragment float4 fragment_blend(VSOut in [[stage_in]], texture2d<float> prev [[texture(0)]],
                               texture2d<float> curr [[texture(1)]], sampler smp [[sampler(0)]],
                               constant float4& uvRect [[buffer(0)]])
{
    float2 uv = mix(uvRect.xy, uvRect.zw, in.uv);
    float4 a = prev.sample(smp, uv), b = curr.sample(smp, uv);
    return mix(a, b, 0.5);
}
