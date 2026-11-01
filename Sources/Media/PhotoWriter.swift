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

    /// 保存一张照片；带 movieURL 时尝试保存为实况照片。
    /// 实况配对失败会自动退回普通照片，不会白拍。
    static func save(photoData: Data, movieURL: URL?) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw WriteError.denied
        }

        let movie = validatedMovie(movieURL)

        do {
            try await perform(photoData: photoData, movieURL: movie)
        } catch {
            guard movie != nil else { throw error }
            // 实况配对失败 → 退一步只存静态图
            try await perform(photoData: photoData, movieURL: nil)
        }
    }

    private static func perform(photoData: Data, movieURL: URL?) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()

            let photoOptions = PHAssetResourceCreationOptions()
            photoOptions.uniformTypeIdentifier = detectUTI(photoData)
            request.addResource(with: .photo, data: photoData, options: photoOptions)

            if let movieURL {
                let videoOptions = PHAssetResourceCreationOptions()
                videoOptions.uniformTypeIdentifier = UTType.quickTimeMovie.identifier
                videoOptions.shouldMoveFile = false
                request.addResource(with: .pairedVideo, fileURL: movieURL, options: videoOptions)
            }
        }
    }

    private static func validatedMovie(_ url: URL?) -> URL? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size > 1024 else { return nil }
        return url
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
