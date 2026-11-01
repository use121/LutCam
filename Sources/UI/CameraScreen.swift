import AVFoundation
import SwiftUI
import UIKit

struct CameraScreen: View {
    @State private var controller = CameraController()
    @State private var library = LUTLibrary()

    @State private var showSettings = false
    @State private var isCapturing = false
    @State private var toast: String?

    @State private var chromeCollapsed = false

    @State private var reticle: CGPoint?
    @State private var showExposure = false
    @State private var pinchBase: CGFloat = 1
    @State private var hideTask: Task<Void, Never>?

    private var minZoom: CGFloat { controller.lenses.first?.base ?? 1 }

    /// 优先取 keyWindow。`windows.first` 可能拿到零 insets 的辅助窗口，
    /// 会导致首帧布局错位、点击区域和视觉对不上。
    private var keyWindow: UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            if let window = scene.windows.first(where: { $0.isKeyWindow }) { return window }
        }
        return scenes.first?.windows.first
    }

    private var safeTop: CGFloat { keyWindow?.safeAreaInsets.top ?? 0 }
    private var safeBottom: CGFloat { keyWindow?.safeAreaInsets.bottom ?? 0 }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                MetalPreview(controller: controller, aspect: controller.aspect.ratio)
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

            shutterRow
                .padding(.horizontal, 26)
                .padding(.top, 2)
                .padding(.bottom, safeBottom + 10)
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: chromeCollapsed)
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
                cycleAspect()
            } label: {
                Text(controller.aspect.rawValue)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(controller.livePhotoEnabled ? Color.white.opacity(0.35) : Color.primary)
                    .frame(width: 46, height: 40)
                    .id("aspect-label-\(controller.aspect.rawValue)")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .disabled(controller.livePhotoEnabled)

            Button {
                controller.livePhotoEnabled.toggle()
                // 实况的静态图与视频必须同尺寸，画幅只能固定 4:3
                if controller.livePhotoEnabled { controller.aspect = .fourThree }
            } label: {
                Image(systemName: controller.livePhotoEnabled ? "livephoto" : "livephoto.slash")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(controller.livePhotoEnabled ? Color.yellow : Color.primary)
                    .frame(width: 40, height: 40)
                    .id("live-icon-\(controller.livePhotoEnabled)")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .tint(controller.livePhotoEnabled ? Color.yellow : Color.clear)
            .disabled(!controller.liveSupported)
            .opacity(controller.liveSupported ? 1 : 0.4)

            Button {
                chromeCollapsed.toggle()
            } label: {
                Image(systemName: chromeCollapsed ? "chevron.up" : "chevron.down")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(chromeCollapsed ? Color.yellow : Color.primary)
                    .frame(width: 40, height: 40)
                    // id 只挂图标：图标会跟着刷新，但按钮身份不变，点击不会被吞
                    .id("collapse-icon-\(chromeCollapsed)")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .tint(chromeCollapsed ? Color.yellow : Color.clear)

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

    /// 曝光补偿范围。
    ///
    /// 设备报的是 ±8 EV，那是传感器极限，拉满会直接全白/全黑。
    /// 这里统一收到 ±2 EV，和原生相机的滑条手感一致。
    private var safeExposureRange: ClosedRange<Double> {
        let deviceLow = Double(controller.exposureRange.lowerBound)
        let deviceHigh = Double(controller.exposureRange.upperBound)
        let low = max(deviceLow.isFinite ? deviceLow : -2, -2)
        let high = min(deviceHigh.isFinite ? deviceHigh : 2, 2)
        guard high - low > 0.2 else { return -2...2 }
        return low...high
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
    ///
    /// 要先算出取景框在屏幕上的位置（画幅会留黑边），再算源画面在取景框里被裁掉多少，
    /// 否则切到 16:9 / 1:1 之后对焦点会偏。
    private func devicePoint(from location: CGPoint, in size: CGSize) -> CGPoint {
        let sourceAspect = controller.frameAspect   // 源画面宽 / 高（竖屏）
        let frameAspect = controller.aspect.ratio   // 取景框目标宽 / 高

        guard size.width > 0, size.height > 0, sourceAspect > 0, frameAspect > 0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }

        // 取景框：居中，尽量大
        let viewAspect = size.width / size.height
        var frame = CGRect(origin: .zero, size: size)
        if frameAspect < viewAspect {
            let w = size.height * frameAspect
            frame = CGRect(x: (size.width - w) / 2, y: 0, width: w, height: size.height)
        } else {
            let h = size.width / frameAspect
            frame = CGRect(x: 0, y: (size.height - h) / 2, width: size.width, height: h)
        }

        // 取景框内的归一化坐标
        let fu = (location.x - frame.minX) / max(frame.width, 1)
        let fv = (location.y - frame.minY) / max(frame.height, 1)

        // 源画面按 aspect-fill 铺满取景框，反推被裁掉的部分
        var u: CGFloat
        var v: CGFloat
        if sourceAspect > frameAspect {
            let visible = frameAspect / sourceAspect
            u = 0.5 + (fu - 0.5) * visible
            v = fv
        } else {
            let visible = sourceAspect / frameAspect
            u = fu
            v = 0.5 + (fv - 0.5) * visible
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

    private func cycleAspect() {
        let all = CaptureAspect.allCases
        guard let index = all.firstIndex(of: controller.aspect) else {
            controller.aspect = .fourThree
            return
        }
        controller.aspect = all[(index + 1) % all.count]
    }

    private func capture() {
        guard !isCapturing else { return }
        isCapturing = true

        Task {
            var message: String
            var info: String

            do {
                let output = try await controller.capture(live: controller.livePhotoEnabled)
                try await PhotoWriter.save(photoData: output.photoData, movieURL: output.movieURL)

                let kind = output.movieURL != nil ? "实况照片" : "照片"
                let kb = max(1, output.photoData.count / 1024)
                // 顺手把体积显示出来，方便对比压缩效果
                message = "已保存\(kind) · \(kb) KB"
                info = "成功 · \(kind) · \(kb) KB"
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
