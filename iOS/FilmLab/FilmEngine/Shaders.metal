#include <metal_stdlib>
using namespace metal;

// Layouts must match FilmEngine/ShaderTypes.swift.
struct StageParams {
    float4 domainMin;      // xyz: LUT DOMAIN_MIN, w: linear exposure gain (2^EV)
    float4 domainMax;      // xyz: LUT DOMAIN_MAX, w: LUT size N
    float3x3 toFGamut;     // Rec.2020 -> F-Gamut (identity, kept explicit)
    uint clipNegatives;
};

struct DecodeParams {
    float4 yParams;        // x: code scale (normalized sample -> integer code), y: yOffset, z: yScale
    float4 cParams;        // x: cOffset, y: cScale
    float4 matrix;         // crR, cbG, crG, cbB
    float3x3 toRec2020;    // input primaries -> Rec.2020
    uint transfer;         // 0 = Apple Log, 1 = BT.709 inverse OETF (approximate)
};

struct PreviewParams {
    float4 uvTransform;    // xy: scale, zw: offset. srcUV = dstUV * scale + offset
};

// ---------------------------------------------------------------------------
// Curves (research/reference/bake_applelog_to_fuji.py)
// ---------------------------------------------------------------------------
constant float AL_R0 = -0.05641088;
constant float AL_C = 47.28711236;
constant float AL_BETA = 0.00964052;
constant float AL_GAMMA = 0.08550479;
constant float AL_DELTA = 0.69336945;
constant float AL_PT = AL_C * (0.01 - AL_R0) * (0.01 - AL_R0);

constant float FL2_A = 5.555556;
constant float FL2_B = 0.064829;
constant float FL2_C = 0.245281;
constant float FL2_D = 0.384316;
constant float FL2_E = 8.799461;
constant float FL2_F = 0.092864;
constant float FL2_CUT1 = 0.000889;

static inline float3 applelog_decode(float3 p) {
    float3 hi = exp2((p - AL_DELTA) / AL_GAMMA) - AL_BETA;
    float3 lo = sqrt(max(p, 0.0) / AL_C) + AL_R0;
    return select(lo, hi, p >= AL_PT);
}

static inline float3 flog2_encode(float3 x) {
    float3 lg = FL2_C * log10(max(FL2_A * x + FL2_B, 1e-10)) + FL2_D;
    float3 ln = FL2_E * x + FL2_F;
    return select(ln, lg, x >= FL2_CUT1);
}

static inline float3 bt709_inverse_oetf(float3 v) {
    v = max(v, 0.0);
    return select(pow((v + 0.099) / 1.099, 1.0 / 0.45), v / 4.5, v < 0.081);
}

// ---------------------------------------------------------------------------
// Shared film simulation stage
// ---------------------------------------------------------------------------
// Manual trilinear interpolation over texel reads (exact fp32, mirrors apply_cube in the Python
// reference). Hardware linear filtering was measured at up to 2.7e-3 error against Python (8-bit-ish
// filter weights + half-float storage), which fails the 1e-3 spec tolerance. See DEVELOPMENT_LOG.md.
static inline float3 sample_lut(float3 code, constant StageParams &p, texture3d<float> lut, sampler lutSampler) {
    int n = int(p.domainMax.w);
    float3 x = clamp((code - p.domainMin.xyz) / (p.domainMax.xyz - p.domainMin.xyz), 0.0, 1.0) * float(n - 1);
    int3 i0 = min(int3(floor(x)), int3(n - 2));
    float3 f = x - float3(i0);
    uint3 a = uint3(i0);
    float3 c000 = lut.read(a).rgb;
    float3 c100 = lut.read(a + uint3(1, 0, 0)).rgb;
    float3 c010 = lut.read(a + uint3(0, 1, 0)).rgb;
    float3 c110 = lut.read(a + uint3(1, 1, 0)).rgb;
    float3 c001 = lut.read(a + uint3(0, 0, 1)).rgb;
    float3 c101 = lut.read(a + uint3(1, 0, 1)).rgb;
    float3 c011 = lut.read(a + uint3(0, 1, 1)).rgb;
    float3 c111 = lut.read(a + uint3(1, 1, 1)).rgb;
    float3 c00 = mix(c000, c100, f.x);
    float3 c01 = mix(c010, c110, f.x);
    float3 c10 = mix(c001, c101, f.x);
    float3 c11 = mix(c011, c111, f.x);
    return mix(mix(c00, c01, f.y), mix(c10, c11, f.y), f.z);
}

static inline float3 film_stage(float3 linRec2020,
                                constant StageParams &p,
                                texture3d<float> lut,
                                sampler lutSampler) {
    float3 lin = p.toFGamut * (linRec2020 * p.domainMin.w);
    if (p.clipNegatives != 0) { lin = max(lin, 0.0); }
    float3 code = clamp(flog2_encode(lin), 0.0, 1.0);
    return clamp(sample_lut(code, p, lut, lutSampler), 0.0, 1.0);
}

static inline float3 decode_ycbcr(float ySample, float2 cSample, constant DecodeParams &d) {
    float y = (ySample * d.yParams.x - d.yParams.y) * d.yParams.z;
    float2 c = (cSample * d.yParams.x - d.cParams.x) * d.cParams.y;   // (Cb, Cr)
    float3 rgb = float3(y + d.matrix.x * c.y,
                        y + d.matrix.y * c.x + d.matrix.z * c.y,
                        y + d.matrix.w * c.x);
    float3 lin = d.transfer == 0 ? applelog_decode(rgb) : bt709_inverse_oetf(rgb);
    return d.toRec2020 * lin;
}

// Scene-linear Rec.2020 texture -> film simulation -> Rec.709 texture.
kernel void film_stage_kernel(texture2d<float, access::read> src [[texture(0)]],
                              texture2d<float, access::write> dst [[texture(1)]],
                              texture3d<float> lut [[texture(2)]],
                              sampler lutSampler [[sampler(0)]],
                              constant StageParams &p [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float3 rgb = film_stage(src.read(gid).rgb, p, lut, lutSampler);
    dst.write(float4(rgb, 1.0), gid);
}

// Live preview: Y'CbCr camera planes -> linear Rec.2020 -> film simulation -> drawable.
kernel void preview_kernel(texture2d<float, access::sample> lumaTex [[texture(0)]],
                           texture2d<float, access::sample> chromaTex [[texture(1)]],
                           texture2d<float, access::write> dst [[texture(2)]],
                           texture3d<float> lut [[texture(3)]],
                           sampler lutSampler [[sampler(0)]],
                           sampler planeSampler [[sampler(1)]],
                           constant StageParams &p [[buffer(0)]],
                           constant DecodeParams &d [[buffer(1)]],
                           constant PreviewParams &v [[buffer(2)]],
                           uint2 gid [[thread_position_in_grid]]) {
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) { return; }
    float2 uv = (float2(gid) + 0.5) / float2(w, h) * v.uvTransform.xy + v.uvTransform.zw;
    float3 lin = decode_ycbcr(lumaTex.sample(planeSampler, uv).r, chromaTex.sample(planeSampler, uv).rg, d);
    dst.write(float4(film_stage(lin, p, lut, lutSampler), 1.0), gid);
}

// Y'CbCr planes -> scene-linear Rec.2020, one output pixel per luma sample (no filtering).
// Used by tests and by the gray-card meter.
kernel void ycbcr_to_linear_kernel(texture2d<float, access::read> lumaTex [[texture(0)]],
                                   texture2d<float, access::read> chromaTex [[texture(1)]],
                                   texture2d<float, access::write> dst [[texture(2)]],
                                   constant DecodeParams &d [[buffer(1)]],
                                   constant uint2 &origin [[buffer(3)]],
                                   uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    uint2 pos = origin + gid;
    if (pos.x >= lumaTex.get_width() || pos.y >= lumaTex.get_height()) { return; }
    float3 lin = decode_ycbcr(lumaTex.read(pos).r, chromaTex.read(pos / 2).rg, d);
    dst.write(float4(lin, 1.0), gid);
}

// Curve evaluation for tests: out[2i] = applelog_decode(in[i]), out[2i+1] = flog2_encode(in[i]).
kernel void curve_eval_kernel(device const float *input [[buffer(0)]],
                              device float *output [[buffer(1)]],
                              uint gid [[thread_position_in_grid]]) {
    float x = input[gid];
    output[2 * gid] = applelog_decode(float3(x)).x;
    output[2 * gid + 1] = flog2_encode(float3(x)).x;
}

// LUT sampling only, for tests: output[i] = LUT(input[i]).
kernel void lut_sample_kernel(device const float4 *input [[buffer(1)]],
                              device float4 *output [[buffer(2)]],
                              texture3d<float> lut [[texture(0)]],
                              sampler lutSampler [[sampler(0)]],
                              constant StageParams &p [[buffer(0)]],
                              uint gid [[thread_position_in_grid]]) {
    output[gid] = float4(sample_lut(input[gid].xyz, p, lut, lutSampler), 1.0);
}
