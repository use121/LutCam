import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 把 LUT（以及必要时的数字曝光补偿）烘进照片。
///
/// 三条铁律（都是踩过坑总结的）：
/// 1. 保留原始元数据 —— 丢了 EXIF/方向信息，照片在相册里会横过来；
/// 2. 沿用原容器格式 —— 原图 JPEG 就出 JPEG，别乱转；
/// 3. 像素尺寸不变 —— 不把旋转烘进像素。
enum PhotoProcessor {

    enum ProcessingError: LocalizedError {
        case noData
        case decodeFailed
        case encodeFailed

        var errorDescription: String? {
            switch self {
            case .noData: return "没有拿到照片数据"
            case .decodeFailed: return "照片解码失败"
            case .encodeFailed: return "照片编码失败"
            }
        }
    }

    /// - Parameter digitalEV: 设备不接受 exposureTargetBias 时的数字补偿，
    ///   保证「取景框里看到的变化」和成片一致。设备接受时为 0。
    static func apply(cube: LUTCube?, intensity: Double, digitalEV: Float, to data: Data) -> Data {
        let needEV = abs(digitalEV) > 0.02
        let lutFilter = cube?.filter(intensity: intensity)

        guard needEV || lutFilter != nil else { return data }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return data }
        let sourceType = (CGImageSourceGetType(source) as String?) ?? UTType.jpeg.identifier
        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]

        guard var image = CIImage(data: data) else { return data }

        if needEV, let exposure = CIFilter(name: "CIExposureAdjust") {
            exposure.setValue(image, forKey: kCIInputImageKey)
            exposure.setValue(NSNumber(value: digitalEV), forKey: kCIInputEVKey)
            image = exposure.outputImage ?? image
        }

        if let lutFilter {
            lutFilter.setValue(image, forKey: kCIInputImageKey)
            image = lutFilter.outputImage ?? image
        }

        guard let cgImage = RenderPipeline.cgImage(from: image) else { return data }

        properties[kCGImageDestinationLossyCompressionQuality] = 0.94
        properties.removeValue(forKey: kCGImagePropertyPixelWidth)
        properties.removeValue(forKey: kCGImagePropertyPixelHeight)

        return encode(cgImage, type: sourceType, properties: properties) ?? data
    }

    private static func encode(_ image: CGImage, type: String, properties: [CFString: Any]) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            type as CFString,
            1,
            nil
        ) else { return nil }

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
