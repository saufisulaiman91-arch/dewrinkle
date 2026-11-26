import Foundation

/// Edge-aware feather. The mask follows the guide's luminance, so a brush edge
/// falls off on smooth satin and stays put on a seam.
public enum GuidedMask {
    public static func refine(_ mask: MaskBuffer, guide: [Float], radius: Float, epsilon: Float = 0.012) -> MaskBuffer {
        guard radius >= 0.4, guide.count == mask.values.count else { return mask }
        let width = mask.width
        let height = mask.height
        let meanI = GaussianBlur.plane(guide, width: width, height: height, sigma: radius)
        let meanP = GaussianBlur.plane(mask.values, width: width, height: height, sigma: radius)
        var product = [Float](repeating: 0, count: guide.count)
        var square = [Float](repeating: 0, count: guide.count)
        for index in guide.indices {
            product[index] = guide[index] * mask.values[index]
            square[index] = guide[index] * guide[index]
        }
        let meanIP = GaussianBlur.plane(product, width: width, height: height, sigma: radius)
        let meanII = GaussianBlur.plane(square, width: width, height: height, sigma: radius)
        var a = [Float](repeating: 0, count: guide.count)
        var b = [Float](repeating: 0, count: guide.count)
        for index in guide.indices {
            let variance = meanII[index] - meanI[index] * meanI[index]
            let covariance = meanIP[index] - meanI[index] * meanP[index]
            let coefficient = covariance / (variance + epsilon)
            a[index] = coefficient
            b[index] = meanP[index] - coefficient * meanI[index]
        }
        let meanA = GaussianBlur.plane(a, width: width, height: height, sigma: radius)
        let meanB = GaussianBlur.plane(b, width: width, height: height, sigma: radius)
        var output = mask
        for index in guide.indices {
            output.values[index] = clamp01(meanA[index] * guide[index] + meanB[index])
        }
        return output
    }
}
