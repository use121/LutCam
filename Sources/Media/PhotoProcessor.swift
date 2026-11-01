import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 把 LUT、曝光补偿和画幅裁切烘进照片。
///
/// 三条铁律（都是踩过坑总结的）：
/// 1. 保留原始元数据 —— 丢了 EXIF/方向信息，照片在相册里会横过来；
/// 2. 沿用原容器格式 —— 原图 JPEG 就出 JPEG，别乱转；
/// 3. 像素尺寸不变（除主动裁切外）—— 不把旋转烘进像素。
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

    /// - Parameters:
    ///   - digitalEV: 设备不接受 exposureTargetBias 时的数字补偿，保证预览与成片一致。
    ///   - aspect: 目标画幅；传 nil 表示不裁切。
    static func apply(
        cube: LUTCube?,
        intensity: Double,
        digitalEV: Float,
        aspect: CaptureAspect?,
        to data: Data
    ) -> Data {
        let needEV = abs(digitalEV) > 0.02
        let lutFilter = cube?.filter(intensity: intensity)
        let needCrop = aspect != nil

        guard needEV || lutFilter != nil || needCrop else { return data }

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

        if let aspect {
            image = crop(image, to: aspect.ratio)
        }

        guard let cgImage = RenderPipeline.cgImage(from: image) else { return data }

        properties[kCGImageDestinationLossyCompressionQuality] = 0.94
        properties.removeValue(forKey: kCGImagePropertyPixelWidth)
        properties.removeValue(forKey: kCGImagePropertyPixelHeight)

        return encode(cgImage, type: sourceType, properties: properties) ?? data
    }

    /// 居中裁切到目标宽高比（ratio = 宽 / 高）
    private static func crop(_ image: CIImage, to ratio: CGFloat) -> CIImage {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1, ratio > 0 else { return image }

        let current = extent.width / extent.height
        if abs(current - ratio) < 0.005 { return image }

        if current > ratio {
            // 比目标更宽 → 裁两侧
            let newWidth = extent.height * ratio
            let x = extent.origin.x + (extent.width - newWidth) / 2
            return image.cropped(to: CGRect(
                x: x, y: extent.origin.y,
                width: newWidth, height: extent.height
            ))
        } else {
            // 比目标更高 → 裁上下
            let newHeight = extent.width / ratio
            let y = extent.origin.y + (extent.height - newHeight) / 2
            return image.cropped(to: CGRect(
                x: extent.origin.x, y: y,
                width: extent.width, height: newHeight
            ))
        }
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
