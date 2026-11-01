import SwiftUI

/// 底部横向 LUT 滤镜条。每个 LUT 用当前取景画面实时渲染成缩略图。
struct LUTStrip: View {
    let library: LUTLibrary
    let snapshot: () -> CIImage?

    @State private var thumbs: [String: UIImage] = [:]

    private var signature: String {
        library.entries.map { "\($0.id)-\($0.isUsable)" }.joined(separator: "|")
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                item(id: nil, title: "原图")
                ForEach(library.entries.filter(\.isUsable)) { entry in
                    item(id: entry.id, title: entry.title)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .task(id: signature) {
            await buildThumbnails()
        }
    }

    private func item(id: String?, title: String) -> some View {
        let selected = library.selectedID == id
        let image = thumbs[id ?? "__none__"]

        return Button {
            library.select(id)
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.white.opacity(0.12))
                    }
                }
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            selected ? Color.yellow : Color.white.opacity(0.18),
                            lineWidth: selected ? 2 : 0.8
                        )
                }

                Text(title)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(selected ? Color.yellow : Color.white.opacity(0.7))
                    .lineLimit(1)
                    .frame(width: 62)
            }
        }
        .buttonStyle(.plain)
    }

    private func buildThumbnails() async {
        let base = snapshot()
        let ids = library.entries.filter(\.isUsable).map(\.id)
        let lib = library

        let result: [String: UIImage] = await Task.detached(priority: .userInitiated) {
            var out: [String: UIImage] = [:]
            if let plain = lib.plainThumbnail(base: base) { out["__none__"] = plain }
            for id in ids {
                if let thumb = lib.thumbnail(for: id, base: base) { out[id] = thumb }
            }
            return out
        }.value

        thumbs = result
    }
}
