import CoreImage
import Foundation

/// 全 App 统一的渲染上下文。
///
/// 关键：工作空间和输出空间都锁死 sRGB。
/// 早期版本预览用 DeviceRGB、成片用默认线性空间，
/// 同一个 LUT 在两种空间里跑出来的结果差很多（成片明显更浓郁）。
enum RenderPipeline {
    static let context = CIContext(options: [
        .workingColorSpace: LUTCube.srgb,
        .outputColorSpace: LUTCube.srgb,
        .cacheIntermediates: false
    ])

    static func cgImage(from image: CIImage) -> CGImage? {
        context.createCGImage(
            image,
            from: image.extent,
            format: .RGBA8,
            colorSpace: LUTCube.srgb
        )
    }
}
