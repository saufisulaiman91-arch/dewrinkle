#include <CoreImage/CoreImage.h>

using namespace coreimage;
using namespace metal;

// Keep these in sync with KernelSources.swift. The high-frequency layer
// (image - detail) is added back unchanged.

[[ stitchable ]] float4 dewrinkleRecombine(
    sample_t image,
    sample_t detail,
    sample_t fine,
    sample_t coarse,
    sample_t mask,
    float fineKeep,
    float foldKeep,
    float strength
) {
    float3 weights = float3(0.299f, 0.587f, 0.114f);
    float y = dot(image.rgb, weights);
    float high = y - detail.r;
    float mid = detail.r - fine.r;
    float broad = fine.r - coarse.r;
    float corrected = coarse.r + broad * foldKeep + mid * fineKeep + high;
    float delta = (corrected - y) * strength;
    float3 shaded = clamp(image.rgb + float3(delta), float3(0.0f), float3(1.0f));
    float amount = clamp(mask.r, 0.0f, 1.0f);
    return float4(mix(image.rgb, shaded, amount), image.a);
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
