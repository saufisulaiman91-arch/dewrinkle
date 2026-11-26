#include <CoreImage/CoreImage.h>

using namespace coreimage;
using namespace metal;

// Keep these in sync with KernelSources.swift. The high-frequency layer
// (image - detail) is added back unchanged.

[[ stitchable ]] float4 dewrinkleRecombine(
    sample_t image,
    sample_t detail,
    sample_t fine,
    sample_t deep,
    sample_t base,
    sample_t ridge,
    sample_t mask,
    float fineAmt,
    float deepAmt,
    float structureSoften
) {
    float3 weights = float3(0.299f, 0.587f, 0.114f);
    float y = dot(image.rgb, weights);
    float grain = y - detail.r;
    float lines = detail.r - fine.r;
    float folds = fine.r - deep.r;
    float drape = deep.r - base.r;
    float lineGate = smoothstep(0.004f, 0.02f, ridge.r);
    float contrast = smoothstep(abs(grain) * 1.4f + 0.008f, abs(grain) * 2.6f + 0.028f, abs(lines));
    float fineGate = lineGate * contrast;
    float delta = (-(lines * fineGate + grain * fineGate * 0.35f) * fineAmt - (folds * 0.9f + drape * structureSoften) * deepAmt) * mask.r;
    float3 shaded = clamp(image.rgb + float3(delta), float3(0.0f), float3(1.0f));
    return float4(shaded, image.a);
}

[[ stitchable ]] float4 subtractLuma(sample_t a, sample_t b) {
    float d = a.r - b.r + 0.5f;
    return float4(d, d, d, 1.0f);
}

[[ stitchable ]] float4 ridgeGate(sampler src) {
    float2 p = src.coord();
    float c = src.sample(src.transform(p)).r;
    float l = src.sample(src.transform(p + float2(-1.0f, 0.0f))).r;
    float r = src.sample(src.transform(p + float2(1.0f, 0.0f))).r;
    float u = src.sample(src.transform(p + float2(0.0f, 1.0f))).r;
    float dn = src.sample(src.transform(p + float2(0.0f, -1.0f))).r;
    float tl = src.sample(src.transform(p + float2(-1.0f, 1.0f))).r;
    float tr = src.sample(src.transform(p + float2(1.0f, 1.0f))).r;
    float bl = src.sample(src.transform(p + float2(-1.0f, -1.0f))).r;
    float br = src.sample(src.transform(p + float2(1.0f, -1.0f))).r;
    float ixx = l - 2.0f * c + r;
    float iyy = u - 2.0f * c + dn;
    float ixy = (br - bl - tr + tl) * 0.25f;
    float half = (ixx + iyy) * 0.5f;
    float root = sqrt(max(half * half - (ixx * iyy - ixy * ixy), 0.0f));
    float major = max(abs(half + root), abs(half - root));
    float minor = min(abs(half + root), abs(half - root));
    float score = major * major / (major + minor + 0.0001f);
    return float4(score, score, score, 1.0f);
}

[[ stitchable ]] float4 effectMask(sample_t garment, sample_t protect, float strength) {
    float amount = clamp(garment.r * (1.0f - protect.r) * strength, 0.0f, 1.0f);
    return float4(amount, amount, amount, 1.0f);
}

[[ stitchable ]] float4 denoiseAssemble(
    sample_t original,
    sample_t lumaImage,
    sample_t chromaSoft,
    float lumaMix,
    float chromaMix
) {
    float3 weights = float3(0.299f, 0.587f, 0.114f);
    float y0 = dot(original.rgb, weights);
    float yDenoised = dot(lumaImage.rgb, weights);
    float y = mix(y0, yDenoised, lumaMix);
    float3 soft = mix(original.rgb, chromaSoft.rgb, chromaMix);
    float ySoft = dot(soft, weights);
    float3 rgb = clamp(soft + float3(y - ySoft), float3(0.0f), float3(1.0f));
    return float4(rgb, original.a);
}

[[ stitchable ]] float4 blendMask(sample_t original, sample_t processed, sample_t mask) {
    return mix(original, processed, clamp(mask.r, 0.0f, 1.0f));
}

static float structureLuma(float4 color) {
    return dot(color.rgb, float3(0.2126f, 0.7152f, 0.0722f));
}

[[ stitchable ]] float4 structureSobel(sampler src, float lowT, float highT) {
    float2 p = src.coord();
    float tl = structureLuma(src.sample(src.transform(p + float2(-1.0f, 1.0f))));
    float tc = structureLuma(src.sample(src.transform(p + float2(0.0f, 1.0f))));
    float tr = structureLuma(src.sample(src.transform(p + float2(1.0f, 1.0f))));
    float ml = structureLuma(src.sample(src.transform(p + float2(-1.0f, 0.0f))));
    float mr = structureLuma(src.sample(src.transform(p + float2(1.0f, 0.0f))));
    float bl = structureLuma(src.sample(src.transform(p + float2(-1.0f, -1.0f))));
    float bc = structureLuma(src.sample(src.transform(p + float2(0.0f, -1.0f))));
    float br = structureLuma(src.sample(src.transform(p + float2(1.0f, -1.0f))));
    float gx = ((tr + 2.0f * mr + br) - (tl + 2.0f * ml + bl)) / 4.0f;
    float gy = ((bl + 2.0f * bc + br) - (tl + 2.0f * tc + tr)) / 4.0f;
    float magnitude = sqrt(gx * gx + gy * gy);
    float t = clamp((magnitude - lowT) / max(highT - lowT, 0.0001f), 0.0f, 1.0f);
    return float4(t, t, t, 1.0f);
}
