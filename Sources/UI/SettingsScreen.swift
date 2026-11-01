import SwiftUI

struct SettingsScreen: View {
    @Bindable var library: LUTLibrary
    let controller: CameraController

    @Environment(\.dismiss) private var dismiss
    @State private var showPicker = false
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            Form {
                lutSection
                intensitySection
                diagnosticSection
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showPicker) {
                DocumentPicker { url in
                    // 等选择器完全收起再处理，避免弹窗叠在一起
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if !library.importFile(at: url) {
                            importError = library.lastImportInfo
                        }
                    }
                }
                .ignoresSafeArea()
            }
            .alert("导入失败", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("好") { importError = nil }
            } message: {
                Text(importError ?? "")
            }
        }
    }

    // MARK: - LUT 列表

    private var lutSection: some View {
        Section {
            if library.entries.isEmpty {
                Text("还没有导入 LUT")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(library.entries) { entry in
                    Button {
                        library.select(entry.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title)
                                    .foregroundStyle(entry.isUsable ? .primary : .secondary)
                                Text(entry.detail)
                                    .font(.caption2)
                                    .foregroundStyle(entry.isUsable ? Color.secondary : Color.red)
                            }
                            Spacer()
                            if library.selectedID == entry.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        library.delete(library.entries[index].id)
                    }
                }
            }

            Button {
                showPicker = true
            } label: {
                Label("导入 .cube 文件", systemImage: "square.and.arrow.down")
            }

            Button {
                library.restorePresets()
            } label: {
                Label("恢复内置预设", systemImage: "arrow.counterclockwise")
            }
        } header: {
            Text("LUT")
        } footer: {
            Text("内置了 13 个胶片预设（理光正片、富士、柯达、港风、青橙等），首次启动自动装好，删了可以点「恢复内置预设」找回。也支持自己导入 .cube，3D 和 1D 都行。")
        }
    }

    // MARK: - 强度

    private var intensitySection: some View {
        Section {
            HStack {
                Text("强度")
                Spacer()
                Text("\(Int((library.intensity * 100).rounded()))%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Slider(value: $library.intensity, in: 0...1)
                .tint(.yellow)
                .disabled(library.selectedID == nil)
        } header: {
            Text("LUT 强度")
        } footer: {
            Text("0% 等于不套 LUT，100% 是全量。中间值可以保留更多原始色彩。")
        }
    }

    // MARK: - 诊断

    private var diagnosticSection: some View {
        Section("诊断") {
            VStack(alignment: .leading, spacing: 3) {
                Text("上次导入").font(.footnote)
                Text(library.lastImportInfo)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("镜头探测").font(.footnote)
                Text(controller.lenses.map(\.label).joined(separator: " / "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("上次拍摄").font(.footnote)
                Text(controller.lastCaptureInfo)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}
