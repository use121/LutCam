import AVFoundation
import SwiftUI
import UIKit

struct CameraScreen: View {
    @State private var controller = CameraController()
    @State private var library = LUTLibrary()

    @State private var showSettings = false
    @State private var isCapturing = false
    @State private var toast: String?

    @AppStorage("ui.chromeCollapsed") private var chromeCollapsed = false

    @State private var reticle: CGPoint?
    @State private var showExposure = false
    @State private var pinchBase: CGFloat = 1
    @State private var hideTask: Task<Void, Never>?

    private var minZoom: CGFloat { controller.lenses.first?.base ?? 1 }

    private var safeTop: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .windows.first?.safeAreaInsets.top ?? 0
    }
    private var safeBottom: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .windows.first?.safeAreaInsets.bottom ?? 0
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                MetalPreview(controller: controller)
                    .ignoresSafeArea()

                // 手势层：在预览之上、控件之下
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(pinchGesture)
                    .simultaneousGesture(
                        SpatialTapGesture()
                            .onEnded { value in handleTap(at: value.location, in: geo.size) }
                    )

                reticleView
                controls
                toastView
            }
        }
        .ignoresSafeArea()
        .onAppear {
            requestCamera()
            syncLUT()
            pinchBase = controller.zoom
        }
        .onDisappear { controller.stop() }
        .onChange(of: library.selectedID) { syncLUT() }
        .onChange(of: library.intensity) { syncLUT() }
        .onChange(of: library.isEnabled) { syncLUT() }
        .sheet(isPresented: $showSettings) {
            SettingsScreen(library: library, controller: controller)
        }
    }

    // MARK: - 控件

    private var controls: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 16)
                .padding(.top, safeTop + 6)

            Spacer(minLength: 0)

            exposureControl

            if !chromeCollapsed {
                intensityControl

                LUTStrip(library: library, snapshot: { controller.currentSnapshot() })
                    .padding(.bottom, 4)

                lensBar
                    .padding(.bottom, 4)
            }

            collapseToggle
                .padding(.vertical, 6)

            shutterRow
                .padding(.horizontal, 26)
                .padding(.top, 2)
                .padding(.bottom, safeBottom + 10)
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Button {
                showSettings = true
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(library.isEnabled && library.selectedID != nil ? Color.green : Color.white.opacity(0.35))
                        .frame(width: 7, height: 7)

                    Text(library.isEnabled && library.selectedID != nil ? library.selectedTitle : "原图")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .lineLimit(1)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .id("lutchip-\(library.selectedID ?? "none")-\(library.isEnabled)")

            Spacer()

            Button {
                showSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
        }
    }

    @ViewBuilder
    private var exposureControl: some View {
        if showExposure {
            HStack(spacing: 10) {
                Image(systemName: "sun.min")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                Slider(
                    value: Binding(
                        get: {
                            let range = safeExposureRange
                            return min(max(Double(controller.exposureBias), range.lowerBound), range.upperBound)
                        },
                        set: { controller.setExposureBias(Float($0)) }
                    ),
                    in: safeExposureRange
                )
                .tint(.yellow)
                .frame(width: 150)

                Image(systemName: "sun.max.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.yellow)

                Text(String(format: "%+.1f", Double(controller.exposureBias)))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
                    .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
            .padding(.bottom, 8)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    @ViewBuilder
    private var intensityControl: some View {
        if library.selectedID != nil, library.isEnabled {
            HStack(spacing: 10) {
                Text("强度")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                Slider(value: $library.intensity, in: 0...1)
                    .tint(.yellow)

                Text("\(Int((library.intensity * 100).rounded()))%")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.yellow)
                    .frame(width: 38, alignment: .trailing)
                    .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: .capsule)
            .padding(.horizontal, 40)
            .padding(.bottom, 6)
        }
    }

    @ViewBuilder
    private var lensBar: some View {
        if controller.lenses.count > 1 {
            HStack(spacing: 6) {
                ForEach(controller.lenses) { lens in
                    let active = abs(lens.base - controller.activeLensBase) < 0.01

                    Button {
                        pinchBase = lens.base
                        controller.rampZoom(to: lens.base)
                    } label: {
                        Text(lens.label)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(active ? Color.black : Color.primary)
                            .frame(width: 46, height: 30)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .tint(active ? Color.yellow : Color.clear)
                    .id("\(lens.label)-\(active)")
                }
            }
        }
    }

    /// 设备给的范围可能退化（min == max 或非有限），直接喂给 Slider 会算出 NaN 导致崩溃
    private var safeExposureRange: ClosedRange<Double> {
        let low = Double(controller.exposureRange.lowerBound)
        let high = Double(controller.exposureRange.upperBound)
        guard low.isFinite, high.isFinite, high - low > 0.2 else { return -2...2 }
        return low...high
    }

    /// 收起 / 展开底部选项（原图、滤镜条、镜头档位）
    private var collapseToggle: some View {
        Button {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                chromeCollapsed.toggle()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: chromeCollapsed ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                Text(chromeCollapsed ? "展开" : "收起")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
            }
            .foregroundStyle(.white.opacity(0.7))
            .frame(width: 54, height: 24)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .capsule)
        .id("collapse-\(chromeCollapsed)")
    }

    private var shutterRow: some View {
        HStack {
            Button {
                library.isEnabled.toggle()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: library.isEnabled ? "camera.filters" : "camera.filters.slash")
                        .font(.system(size: 17, weight: .medium))
                    Text(library.isEnabled ? "LUT 开" : "LUT 关")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                }
                .foregroundStyle(library.isEnabled ? Color.green : Color.white.opacity(0.55))
                .frame(width: 56, height: 56)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .id("luttoggle-\(library.isEnabled)")

            Spacer()

            Button {
                capture()
            } label: {
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.9), lineWidth: 4)
                        .frame(width: 78, height: 78)
                    Circle()
                        .fill(isCapturing ? Color.white.opacity(0.35) : Color.white)
                        .frame(width: 63, height: 63)
                }
            }
            .buttonStyle(.plain)
            .disabled(isCapturing)
            .scaleEffect(isCapturing ? 0.94 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: isCapturing)

            Spacer()

            Button {
                pinchBase = 1
                controller.switchCamera()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
        }
    }

    // MARK: - 对焦框

    @ViewBuilder
    private var reticleView: some View {
        if let point = reticle {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.yellow, lineWidth: 1.6)
                .frame(width: 76, height: 76)
                .position(point)
                .allowsHitTesting(false)
                .transition(.scale(scale: 1.35).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            VStack {
                Text(toast)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                Spacer()
            }
            .padding(.top, safeTop + 72)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    // MARK: - 手势

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                controller.setZoom(pinchBase * value.magnification)
            }
            .onEnded { value in
                pinchBase = max(minZoom, min(pinchBase * value.magnification, 15))
            }
    }

    private func handleTap(at location: CGPoint, in size: CGSize) {
        controller.focus(at: devicePoint(from: location, in: size))

        withAnimation(.spring(response: 0.26, dampingFraction: 0.66)) {
            reticle = location
            showExposure = true
        }

        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.3)) {
                    reticle = nil
                    showExposure = false
                }
            }
        }
    }

    /// 屏幕点 → 设备坐标。视频旋转 90°，设备 (0,0) 落在竖屏画面右上角。
    private func devicePoint(from location: CGPoint, in size: CGSize) -> CGPoint {
        let aspect = controller.frameAspect
        guard size.width > 0, size.height > 0, aspect > 0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }

        let viewAspect = size.width / size.height
        var u: CGFloat
        var v: CGFloat

        if aspect > viewAspect {
            let displayedWidth = size.height * aspect
            let offsetX = (size.width - displayedWidth) / 2
            u = (location.x - offsetX) / displayedWidth
            v = location.y / size.height
        } else {
            let displayedHeight = size.width / aspect
            let offsetY = (size.height - displayedHeight) / 2
            u = location.x / size.width
            v = (location.y - offsetY) / displayedHeight
        }

        u = min(max(u, 0), 1)
        v = min(max(v, 0), 1)

        return CGPoint(x: v, y: 1 - u)
    }

    // MARK: - 逻辑

    private func syncLUT() {
        controller.lutCube = library.selectedCube
        controller.lutIntensity = library.intensity
        controller.lutEnabled = library.isEnabled
        controller.refreshPipeline()
    }

    private func requestCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            controller.start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        controller.start()
                    } else {
                        showToast("没有相机权限，请到设置里打开")
                    }
                }
            }
        default:
            showToast("没有相机权限，请到设置里打开")
        }
    }

    private func capture() {
        guard !isCapturing else { return }
        isCapturing = true

        Task {
            var message: String
            var info: String

            do {
                let data = try await controller.capturePhoto()
                try await PhotoWriter.save(data)
                message = "已保存到相册"
                info = "成功 · \(max(1, data.count / 1024)) KB"
            } catch {
                message = "保存失败：\(error.localizedDescription)"
                info = message
            }

            await MainActor.run {
                controller.lastCaptureInfo = info
                isCapturing = false
                showToast(message)
            }
        }
    }

    private func showToast(_ text: String) {
        withAnimation(.easeOut(duration: 0.2)) { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            await MainActor.run {
                if toast == text {
                    withAnimation(.easeOut(duration: 0.3)) { toast = nil }
                }
            }
        }
    }
}
