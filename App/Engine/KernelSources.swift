import CoreImage
import Foundation

/// Runtime fallback for the Metal kernels in `Dewrinkle.metal`.
/// Core Image still compiles this language on macOS 14. Prefer the .ci.metallib
/// produced by the Xcode build script when it is in the app bundle.
enum KernelSources {
    static let recombine = """
    kernel vec4 dewrinkleRecombine(__sample image, __sample detail, __sample fine, __sample deep, __sample base, __sample ridge, __sample mask, float fineAmt, float deepAmt, float structureSoften) {
        vec3 weights = vec3(0.299, 0.587, 0.114);
        float y = dot(image.rgb, weights);
        float grain = y - detail.r;
        float lines = detail.r - fine.r;
        float folds = fine.r - deep.r;
        float drape = deep.r - base.r;
        float lineSpan = max(0.02 - 0.004, 0.0001);
        float lineT = clamp((ridge.r - 0.004) / lineSpan, 0.0, 1.0);
        float lineGate = lineT * lineT * (3.0 - 2.0 * lineT);
        float c0 = abs(grain) * 1.4 + 0.008;
        float c1 = abs(grain) * 2.6 + 0.028;
        float cT = clamp((abs(lines) - c0) / max(c1 - c0, 0.0001), 0.0, 1.0);
        float contrast = cT * cT * (3.0 - 2.0 * cT);
        float fineGate = lineGate * contrast;
        float delta = (-(lines * fineGate + grain * fineGate * 0.35) * fineAmt - (folds * 0.9 + drape * structureSoften) * deepAmt) * mask.r;
        vec3 shaded = clamp(image.rgb + vec3(delta), vec3(0.0), vec3(1.0));
        return vec4(shaded, image.a);
    }
    """

    static let ridge = """
    kernel vec4 ridgeGate(sampler src) {
        vec2 d = destCoord();
        float c = sample(src, samplerTransform(src, d)).r;
        float l = sample(src, samplerTransform(src, d + vec2(-1.0, 0.0))).r;
        float r = sample(src, samplerTransform(src, d + vec2(1.0, 0.0))).r;
        float u = sample(src, samplerTransform(src, d + vec2(0.0, 1.0))).r;
        float dn = sample(src, samplerTransform(src, d + vec2(0.0, -1.0))).r;
        float tl = sample(src, samplerTransform(src, d + vec2(-1.0, 1.0))).r;
        float tr = sample(src, samplerTransform(src, d + vec2(1.0, 1.0))).r;
        float bl = sample(src, samplerTransform(src, d + vec2(-1.0, -1.0))).r;
        float br = sample(src, samplerTransform(src, d + vec2(1.0, -1.0))).r;
        float ixx = l - 2.0 * c + r;
        float iyy = u - 2.0 * c + dn;
        float ixy = (br - bl - tr + tl) * 0.25;
        float half = (ixx + iyy) * 0.5;
        float root = sqrt(max(half * half - (ixx * iyy - ixy * ixy), 0.0));
        float major = max(abs(half + root), abs(half - root));
        float minor = min(abs(half + root), abs(half - root));
        float score = major * major / (major + minor + 0.0001);
        return vec4(score, score, score, 1.0);
    }
    """

    static let subtractLuma = """
    kernel vec4 subtractLuma(__sample a, __sample b) {
        float d = a.r - b.r + 0.5;
        return vec4(d, d, d, 1.0);
    }
    """

    static let effectMask = """
    kernel vec4 effectMask(__sample garment, __sample protect, float strength) {
        float amount = clamp(garment.r * (1.0 - protect.r) * strength, 0.0, 1.0);
        return vec4(amount, amount, amount, 1.0);
    }
    """

    static let denoiseAssemble = """
    kernel vec4 denoiseAssemble(__sample original, __sample lumaImage, __sample chromaSoft, float lumaMix, float chromaMix) {
        vec3 weights = vec3(0.299, 0.587, 0.114);
        float y0 = dot(original.rgb, weights);
        float yDenoised = dot(lumaImage.rgb, weights);
        float y = mix(y0, yDenoised, lumaMix);
        vec3 soft = mix(original.rgb, chromaSoft.rgb, chromaMix);
        float ySoft = dot(soft, weights);
        vec3 rgb = clamp(soft + vec3(y - ySoft), vec3(0.0), vec3(1.0));
        return vec4(rgb, original.a);
    }
    """

    static let blendMask = """
    kernel vec4 blendMask(__sample original, __sample processed, __sample mask) {
        return mix(original, processed, clamp(mask.r, 0.0, 1.0));
    }
    """

    static let structure = """
    kernel vec4 structureSobel(sampler src, float lowT, float highT) {
        vec2 d = destCoord();
        vec3 w = vec3(0.2126, 0.7152, 0.0722);
        float tl = dot(sample(src, samplerTransform(src, d + vec2(-1.0, 1.0))).rgb, w);
        float tc = dot(sample(src, samplerTransform(src, d + vec2(0.0, 1.0))).rgb, w);
        float tr = dot(sample(src, samplerTransform(src, d + vec2(1.0, 1.0))).rgb, w);
        float ml = dot(sample(src, samplerTransform(src, d + vec2(-1.0, 0.0))).rgb, w);
        float mr = dot(sample(src, samplerTransform(src, d + vec2(1.0, 0.0))).rgb, w);
        float bl = dot(sample(src, samplerTransform(src, d + vec2(-1.0, -1.0))).rgb, w);
        float bc = dot(sample(src, samplerTransform(src, d + vec2(0.0, -1.0))).rgb, w);
        float br = dot(sample(src, samplerTransform(src, d + vec2(1.0, -1.0))).rgb, w);
        float gx = ((tr + 2.0 * mr + br) - (tl + 2.0 * ml + bl)) / 4.0;
        float gy = ((bl + 2.0 * bc + br) - (tl + 2.0 * tc + tr)) / 4.0;
        float magnitude = sqrt(gx * gx + gy * gy);
        float t = clamp((magnitude - lowT) / max(highT - lowT, 0.0001), 0.0, 1.0);
        return vec4(t, t, t, 1.0);
    }
    """
}

final class KernelLibrary {
    static let shared = KernelLibrary()

    let recombine: CIColorKernel?
    let effectMask: CIColorKernel?
    let denoiseAssemble: CIColorKernel?
    let blendMask: CIColorKernel?
    let structure: CIKernel?
    let ridge: CIKernel?
    let subtract: CIColorKernel?
    let usedMetalLibrary: Bool

    private init() {
        if let url = Bundle.main.url(forResource: "Dewrinkle", withExtension: "ci.metallib"),
           let data = try? Data(contentsOf: url),
           let recombine = try? CIColorKernel(functionName: "dewrinkleRecombine", fromMetalLibraryData: data),
           let effectMask = try? CIColorKernel(functionName: "effectMask", fromMetalLibraryData: data),
           let denoiseAssemble = try? CIColorKernel(functionName: "denoiseAssemble", fromMetalLibraryData: data),
           let blendMask = try? CIColorKernel(functionName: "blendMask", fromMetalLibraryData: data),
           let structure = try? CIKernel(functionName: "structureSobel", fromMetalLibraryData: data),
           let ridge = try? CIKernel(functionName: "ridgeGate", fromMetalLibraryData: data),
           let subtract = try? CIColorKernel(functionName: "subtractLuma", fromMetalLibraryData: data) {
            self.recombine = recombine
            self.effectMask = effectMask
            self.denoiseAssemble = denoiseAssemble
            self.blendMask = blendMask
            self.structure = structure
            self.ridge = ridge
            self.subtract = subtract
            usedMetalLibrary = true
            return
        }

        recombine = CIColorKernel(source: KernelSources.recombine)
        effectMask = CIColorKernel(source: KernelSources.effectMask)
        denoiseAssemble = CIColorKernel(source: KernelSources.denoiseAssemble)
        blendMask = CIColorKernel(source: KernelSources.blendMask)
        structure = CIKernel(source: KernelSources.structure)
        ridge = CIKernel(source: KernelSources.ridge)
        subtract = CIColorKernel(source: KernelSources.subtractLuma)
        usedMetalLibrary = false
    }
}
