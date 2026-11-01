import CoreGraphics
import CoreImage
import Foundation

/// 解析好的 .cube LUT。
///
/// 内部只保存「原始 RGB 三元组」，按 CIColorCube 要求的顺序排列（r 变化最快）。
/// 生成滤镜时按 intensity 向 identity 插值，这样 0% = 原图、100% = 全量，
/// 而且预览和成片走的是同一套数学，不会出现「预览和照片不一致」。
struct LUTCube: Identifiable, Equatable {
    let id: String            // 文件名，唯一标识
    let title: String         // 显示名（TITLE 或文件名）
    let dimension: Int
    let kind: Kind
    let values: [Float]       // count * 3

    enum Kind: String {
        case threeD = "3D"
        case oneD = "1D→3D"
    }

    static let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    static func == (lhs: LUTCube, rhs: LUTCube) -> Bool { lhs.id == rhs.id }

    var count: Int { dimension * dimension * dimension }

    // MARK: - 滤镜

    func filter(intensity: Double) -> CIFilter? {
        let k = max(0, min(1, intensity))
        guard k > 0.001 else { return nil }

        guard let filter = CIFilter(name: "CIColorCubeWithColorSpace") else { return nil }
        filter.setValue(NSNumber(value: dimension), forKey: "inputCubeDimension")
        filter.setValue(cubeData(intensity: k), forKey: "inputCubeData")
        filter.setValue(Self.srgb, forKey: "inputColorSpace")
        return filter
    }

    private func cubeData(intensity k: Double) -> Data {
        let n = dimension
        let denom = Float(max(n - 1, 1))
        let kf = Float(k)

        var buffer = [Float](repeating: 0, count: count * 4)

        for i in 0..<count {
            // identity：该格点在立方体里的归一化坐标
            let r = Float(i % n) / denom
            let g = Float((i / n) % n) / denom
            let b = Float(i / (n * n)) / denom

            buffer[i * 4]     = r + (values[i * 3]     - r) * kf
            buffer[i * 4 + 1] = g + (values[i * 3 + 1] - g) * kf
            buffer[i * 4 + 2] = b + (values[i * 3 + 2] - b) * kf
            buffer[i * 4 + 3] = 1
        }

        return buffer.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // MARK: - 解析

    enum ParseError: LocalizedError {
        case empty
        case noSize
        case notEnoughData(expected: Int, actual: Int)

        var errorDescription: String? {
            switch self {
            case .empty: return "文件里没有读到颜色数据"
            case .noSize: return "缺少 LUT_3D_SIZE 或 LUT_1D_SIZE"
            case .notEnoughData(let e, let a): return "数据不完整，需要 \(e) 组，实际 \(a) 组"
            }
        }
    }

    static func parse(data: Data, id: String, fallbackTitle: String) throws -> LUTCube {
        guard var text = String(data: data, encoding: .utf8) else { throw ParseError.empty }
        // 去掉 UTF-8 BOM，否则第一行匹配不上
        text = text.replacingOccurrences(of: "\u{FEFF}", with: "")

        var title = fallbackTitle
        var size3D = 0
        var size1D = 0
        var domainMin: [Float] = [0, 0, 0]
        var domainMax: [Float] = [1, 1, 1]
        var raw: [Float] = []

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let upper = trimmed.uppercased()

            if upper.hasPrefix("TITLE") {
                if let open = trimmed.firstIndex(of: "\""),
                   let close = trimmed[trimmed.index(after: open)...].firstIndex(of: "\"") {
                    title = String(trimmed[trimmed.index(after: open)..<close])
                }
                continue
            }
            if upper.hasPrefix("LUT_3D_SIZE") {
                size3D = Self.intValue(in: trimmed) ?? 0
                continue
            }
            if upper.hasPrefix("LUT_1D_SIZE") {
                size1D = Self.intValue(in: trimmed) ?? 0
                continue
            }
            if upper.hasPrefix("DOMAIN_MIN") {
                domainMin = Self.floats(in: trimmed, count: 3) ?? domainMin
                continue
            }
            if upper.hasPrefix("DOMAIN_MAX") {
                domainMax = Self.floats(in: trimmed, count: 3) ?? domainMax
                continue
            }

            if let triple = Self.floats(in: trimmed, count: 3) {
                raw.append(contentsOf: triple)
            }
        }

        guard !raw.isEmpty else { throw ParseError.empty }
        let normalized = normalize(raw, min: domainMin, max: domainMax)

        if size3D > 1 {
            let need = size3D * size3D * size3D * 3
            guard normalized.count >= need else {
                throw ParseError.notEnoughData(expected: need / 3, actual: normalized.count / 3)
            }
            return LUTCube(
                id: id, title: title, dimension: size3D, kind: .threeD,
                values: Array(normalized[0..<need])
            )
        }

        if size1D > 1 {
            guard normalized.count >= size1D * 3 else {
                throw ParseError.notEnoughData(expected: size1D, actual: normalized.count / 3)
            }
            return LUTCube(
                id: id, title: title, dimension: size1D, kind: .oneD,
                values: expand1D(normalized, size: size1D)
            )
        }

        throw ParseError.noSize
    }

    // MARK: - 辅助

    /// 1D LUT 展开成等尺寸 3D：输出 (r,g,b) = (表[r].r, 表[g].g, 表[b].b)
    private static func expand1D(_ table: [Float], size: Int) -> [Float] {
        var out = [Float](repeating: 0, count: size * size * size * 3)
        var i = 0
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    out[i]     = table[r * 3]
                    out[i + 1] = table[g * 3 + 1]
                    out[i + 2] = table[b * 3 + 2]
                    i += 3
                }
            }
        }
        return out
    }

    private static func normalize(_ values: [Float], min lo: [Float], max hi: [Float]) -> [Float] {
        guard lo != [0, 0, 0] || hi != [1, 1, 1] else { return values }
        var out = values
        for i in stride(from: 0, to: out.count - 2, by: 3) {
            for c in 0..<3 {
                let span = hi[c] - lo[c]
                if span > 0 { out[i + c] = (out[i + c] - lo[c]) / span }
            }
        }
        return out
    }

    private static func intValue(in line: String) -> Int? {
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count >= 2 else { return nil }
        return Int(parts[1])
    }

    private static func floats(in line: String, count: Int) -> [Float]? {
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { Float($0) }
        guard parts.count >= count else { return nil }
        return Array(parts[0..<count])
    }
}
