import Foundation

/// 内置胶片预设。
///
/// `.cube` 文件随 App 打包，首次启动时复制到 LUT 目录，之后就和用户自己导入的
/// 完全一样 —— 可以选中、调强度、删除。
///
/// 用版本号控制：只在版本变化时补装一次，所以用户删掉的预设不会每次启动又冒出来。
enum PresetInstaller {

    /// 新增或调整预设时 +1。升级安装会重新补齐缺的文件。
    static let version = 1
    private static let key = "presets.installed.version"

    /// 首次启动（或升级后）安装一次。
    @discardableResult
    static func installIfNeeded(into folder: URL) -> Int {
        guard UserDefaults.standard.integer(forKey: key) < version else { return 0 }
        let count = copyBundled(into: folder)
        UserDefaults.standard.set(version, forKey: key)
        return count
    }

    /// 手动恢复：把被删掉的内置预设重新复制回来，已存在的不覆盖。
    @discardableResult
    static func restore(into folder: URL) -> Int {
        let count = copyBundled(into: folder)
        UserDefaults.standard.set(version, forKey: key)
        return count
    }

    private static func copyBundled(into folder: URL) -> Int {
        var urls = Bundle.main.urls(forResourcesWithExtension: "cube", subdirectory: nil) ?? []

        // 打包方式不同时，文件可能被放进 Presets 子目录
        if let nested = Bundle.main.urls(forResourcesWithExtension: "cube", subdirectory: "Presets") {
            urls += nested
        }

        var copied = 0
        for url in urls {
            let target = folder.appendingPathComponent(url.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: target.path) else { continue }
            if (try? FileManager.default.copyItem(at: url, to: target)) != nil {
                copied += 1
            }
        }
        return copied
    }
}
