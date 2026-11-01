import CoreImage
import Foundation
import Observation
import UIKit

struct LUTEntry: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let isUsable: Bool
}

/// 管理本地 LUT 文件：导入、列表、选中、缩略图。
@Observable
final class LUTLibrary {

    private(set) var entries: [LUTEntry] = []

    var selectedID: String?
    var intensity: Double = 1.0
    var isEnabled: Bool = true

    /// 最近一次导入的结果，显示在设置页，方便定位问题
    var lastImportInfo: String = "—"

    @ObservationIgnored private let folder: URL
    @ObservationIgnored private var cache: [String: LUTCube] = [:]
    @ObservationIgnored private let cacheLock = NSLock()
    @ObservationIgnored private var thumbs: [String: UIImage] = [:]

    private static let selectedKey = "lut.selected"

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        folder = docs.appendingPathComponent("LUTs", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // 内置胶片预设：首次启动装进来，之后和用户导入的一样对待
        PresetInstaller.installIfNeeded(into: folder)

        selectedID = UserDefaults.standard.string(forKey: Self.selectedKey)
        refresh()
    }

    // MARK: - 列表

    func refresh() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?
            .filter { $0.lowercased().hasSuffix(".cube") }
            .sorted() ?? []

        entries = names.map { name in
            if let cube = load(name) {
                return LUTEntry(id: name, title: cube.title, detail: "\(cube.kind.rawValue) · \(cube.dimension)³", isUsable: true)
            }
            return LUTEntry(id: name, title: (name as NSString).deletingPathExtension, detail: "解析失败", isUsable: false)
        }

        // 选中的文件被删掉了
        if let id = selectedID, !names.contains(id) {
            selectedID = nil
            UserDefaults.standard.removeObject(forKey: Self.selectedKey)
        }
    }

    func load(_ name: String) -> LUTCube? {
        cacheLock.lock()
        let hit = cache[name]
        cacheLock.unlock()
        if let hit { return hit }

        let url = folder.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url),
              let cube = try? LUTCube.parse(data: data, id: name, fallbackTitle: (name as NSString).deletingPathExtension)
        else { return nil }

        cacheLock.lock()
        cache[name] = cube
        cacheLock.unlock()
        return cube
    }

    // MARK: - 导入

    @discardableResult
    func importFile(at url: URL) -> Bool {
        lastImportInfo = "开始：\(url.lastPathComponent)"

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: url)
            guard !data.isEmpty else {
                lastImportInfo = "失败：文件为空"
                return false
            }

            // 有些来源会丢扩展名，这里补回来
            var name = url.lastPathComponent
            if !name.lowercased().hasSuffix(".cube") { name += ".cube" }

            // 先解析，确认是合法 LUT 再落盘
            let cube = try LUTCube.parse(data: data, id: name, fallbackTitle: (name as NSString).deletingPathExtension)

            let target = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.removeItem(at: target)
            }
            try data.write(to: target)

            cacheLock.lock()
            cache[name] = cube
            cacheLock.unlock()

            refresh()
            select(name)
            lastImportInfo = "成功：\(cube.title) · \(cube.kind.rawValue) · \(cube.dimension)³"
            return true

        } catch {
            lastImportInfo = "失败：\(error.localizedDescription)"
            return false
        }
    }

    /// 把删掉的内置预设补回来
    @discardableResult
    func restorePresets() -> Int {
        let count = PresetInstaller.restore(into: folder)
        cacheLock.lock()
        cache.removeAll()
        cacheLock.unlock()
        thumbs.removeAll()
        refresh()
        lastImportInfo = count > 0 ? "已恢复 \(count) 个内置预设" : "内置预设都在，没有需要恢复的"
        return count
    }

    // MARK: - 选择

    func select(_ id: String?) {
        selectedID = id
        if let id {
            UserDefaults.standard.set(id, forKey: Self.selectedKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.selectedKey)
        }
        isEnabled = id != nil
    }

    func delete(_ id: String) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(id))
        cacheLock.lock()
        cache[id] = nil
        cacheLock.unlock()
        thumbs[id] = nil
        if selectedID == id { select(nil) }
        refresh()
    }

    var selectedCube: LUTCube? {
        guard let selectedID else { return nil }
        return load(selectedID)
    }

    var selectedTitle: String {
        selectedCube?.title ?? "未选择"
    }

    // MARK: - 缩略图

    /// 用当前取景画面做底图，把每个 LUT 渲染成小图。
    func thumbnail(for id: String, base: CIImage?, size: CGFloat = 132) -> UIImage? {
        cacheLock.lock()
        let hit = thumbs[id]
        cacheLock.unlock()
        if let hit { return hit }

        guard let cube = load(id),
              let thumb = Self.renderThumbnail(cube: cube, base: base, size: size) else { return nil }

        cacheLock.lock()
        thumbs[id] = thumb
        cacheLock.unlock()
        return thumb
    }

    func plainThumbnail(base: CIImage?, size: CGFloat = 132) -> UIImage? {
        cacheLock.lock()
        let hit = thumbs["__none__"]
        cacheLock.unlock()
        if let hit { return hit }

        guard let thumb = Self.renderThumbnail(cube: nil, base: base, size: size) else { return nil }

        cacheLock.lock()
        thumbs["__none__"] = thumb
        cacheLock.unlock()
        return thumb
    }

    private static func renderThumbnail(cube: LUTCube?, base: CIImage?, size: CGFloat) -> UIImage? {
        let rect = CGRect(x: 0, y: 0, width: size, height: size)

        var image: CIImage
        if let base, base.extent.width > 1, base.extent.height > 1 {
            let e = base.extent
            let side = min(e.width, e.height)
            let crop = CGRect(
                x: e.origin.x + (e.width - side) / 2,
                y: e.origin.y + (e.height - side) / 2,
                width: side, height: side
            )
            let cropped = base.cropped(to: crop)
            let scale = size / side
            image = cropped
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(
                    translationX: -crop.origin.x * scale,
                    y: -crop.origin.y * scale
                ))
        } else {
            let gradient = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: 0, y: size),
                "inputPoint1": CIVector(x: size, y: 0),
                "inputColor0": CIColor(red: 0.22, green: 0.30, blue: 0.52),
                "inputColor1": CIColor(red: 0.88, green: 0.66, blue: 0.45)
            ])?.outputImage
            image = (gradient ?? CIImage(color: .gray)).cropped(to: rect)
        }

        if let cube, let filter = cube.filter(intensity: 1.0) {
            filter.setValue(image, forKey: kCIInputImageKey)
            image = filter.outputImage ?? image
        }

        guard let cg = RenderPipeline.cgImage(from: image) else { return nil }
        return UIImage(cgImage: cg)
    }

    func invalidateThumbnails() {
        cacheLock.lock()
        thumbs.removeAll()
        cacheLock.unlock()
    }
}
