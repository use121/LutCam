import Foundation
import Photos
import UniformTypeIdentifiers

/// 保存到系统相册。只申请 addOnly 权限，不读用户已有照片。
enum PhotoWriter {

    enum WriteError: LocalizedError {
        case denied
        case failed

        var errorDescription: String? {
            switch self {
            case .denied: return "没有相册写入权限，请到设置里打开"
            case .failed: return "保存到相册失败"
            }
        }
    }

    static func save(_ data: Data) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw WriteError.denied
        }

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.uniformTypeIdentifier = detectUTI(data)
            request.addResource(with: .photo, data: data, options: options)
        }
    }

    /// 按文件头判断真实格式，别信扩展名
    private static func detectUTI(_ data: Data) -> String {
        if data.count >= 3, data[0] == 0xFF, data[1] == 0xD8, data[2] == 0xFF {
            return UTType.jpeg.identifier
        }
        if data.count >= 12, data.subdata(in: 4..<8) == Data("ftyp".utf8) {
            let brand = String(data: data.subdata(in: 8..<12), encoding: .ascii) ?? ""
            if brand.hasPrefix("hei") || brand.hasPrefix("mif1") || brand.hasPrefix("msf1") {
                return UTType.heic.identifier
            }
        }
        return UTType.heic.identifier
    }
}
