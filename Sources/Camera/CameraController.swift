import AVFoundation
import CoreImage
import Foundation
import Observation
import UIKit

struct LensPreset: Identifiable, Hashable {
    let base: CGFloat     // 等效焦段：0.5 / 1 / 3
    let label: String
    var id: String { label }
}

/// 采集层。只做一件事：把相机跑起来，并把帧 / 照片交给上层。
///
/// 变焦用**虚拟多摄设备**（Triple / DualWide），由系统在内部完成镜头切换与交叉淡化，
/// 全程不重建会话，所以是连续的、不卡顿的。
@Observable
final class CameraController: NSObject {

    // MARK: - 对外状态

    private(set) var isRunning = false
    private(set) var lenses: [LensPreset] = []
    private(set) var zoom: CGFloat = 1
    private(set) var position: AVCaptureDevice.Position = .back

    var exposureBias: Float = 0
    private(set) var exposureRange: ClosedRange<Float> = -8...8
    private(set) var focusPoint: CGPoint?

    var errorMessage: String?
    var lastCaptureInfo: String = "—"

    /// LUT 参数：预览与拍照都从这里取，保证一致
    var lutCube: LUTCube?
    var lutIntensity: Double = 1.0
    var lutEnabled: Bool = true

    // MARK: - 内部

    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let photoOutput = AVCapturePhotoOutput()
    @ObservationIgnored private let videoOutput = AVCaptureVideoDataOutput()
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "lutcam.session")
    @ObservationIgnored private let videoQueue = DispatchQueue(label: "lutcam.video")

    @ObservationIgnored private var device: AVCaptureDevice?
    @ObservationIgnored private var input: AVCaptureDeviceInput?
    @ObservationIgnored private var zoomBase: CGFloat = 1
    @ObservationIgnored private var previewFilter: CIFilter?
    @ObservationIgnored private let filterLock = NSLock()
    @ObservationIgnored private var pendingCapture: PhotoCaptureDelegate?

    @ObservationIgnored private var snapshot: CIImage?
    @ObservationIgnored private var lastSnapshotAt: TimeInterval = 0
    @ObservationIgnored private var didReportAspect = false

    private(set) var frameAspect: CGFloat = 9.0 / 16.0

    /// 每帧回调（已经套好 LUT），给预览渲染用
    @ObservationIgnored var onFrame: ((CIImage) -> Void)?

    // MARK: - 生命周期

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.device == nil { self.configure(position: .back) }
            if !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async { self.isRunning = self.session.isRunning }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    // MARK: - 配置

    private func configure(position target: AVCaptureDevice.Position) {
        session.beginConfiguration()
        session.sessionPreset = .photo

        guard let dev = Self.pickDevice(for: target),
              let devInput = try? AVCaptureDeviceInput(device: dev),
              session.canAddInput(devInput) else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.errorMessage = "找不到可用的摄像头" }
            return
        }

        session.addInput(devInput)
        input = devInput
        device = dev

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .quality
        }

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        applyConnections(for: target)
        session.commitConfiguration()

        publishDeviceState(dev, position: target)
    }

    private static func pickDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let candidates: [AVCaptureDevice.DeviceType] = position == .front
            ? [.builtInTrueDepthCamera, .builtInWideAngleCamera]
            : [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]

        for type in candidates {
            if let dev = AVCaptureDevice.default(type, for: .video, position: position) {
                return dev
            }
        }
        return nil
    }

    private func applyConnections(for position: AVCaptureDevice.Position) {
        if let conn = videoOutput.connection(with: .video) {
            if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
            if conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = (position == .front)
            }
        }
        if let conn = photoOutput.connection(with: .video) {
            if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
            if conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = false
            }
        }
    }

    /// 把设备能力同步到界面，并设置初始焦段
    private func publishDeviceState(_ dev: AVCaptureDevice, position: AVCaptureDevice.Position) {
        let hasUltraWide = dev.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        let base: CGFloat = hasUltraWide ? 0.5 : 1
        let presets = Self.buildPresets(device: dev, base: base, position: position)

        if (try? dev.lockForConfiguration()) != nil {
            dev.videoZoomFactor = max(1, 1 / base)
            dev.unlockForConfiguration()
        }

        // 设备可能返回退化的范围（min == max 或非有限值）。
        // 直接拿去构造 ClosedRange 会让 Slider 内部算出 NaN，SwiftUI 布局时崩溃。
        let biasLow = dev.minExposureTargetBias
        let biasHigh = dev.maxExposureTargetBias
        let range: ClosedRange<Float> = (biasHigh - biasLow) > 0.2 && biasHigh.isFinite && biasLow.isFinite
            ? biasLow...biasHigh
            : (-2)...2

        DispatchQueue.main.async {
            self.zoomBase = base
            self.lenses = presets
            self.zoom = 1
            self.position = position
            self.exposureRange = range
            self.exposureBias = dev.exposureTargetBias
        }
    }

    private static func buildPresets(device: AVCaptureDevice, base: CGFloat, position: AVCaptureDevice.Position) -> [LensPreset] {
        var bases: [CGFloat] = []

        let factors = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        if !factors.isEmpty {
            bases = [base] + factors.map { base * $0 }
        } else if !device.constituentDevices.isEmpty {
            bases = device.constituentDevices.map { constituent in
                switch constituent.deviceType {
                case .builtInUltraWideCamera: return 0.5
                case .builtInTelephotoCamera: return 3
                default: return 1
                }
            }
        } else {
            bases = [base]
        }

        // 后摄兜底给出三档，否则整条镜头栏会消失
        if position == .back && bases.count <= 1 { bases = [0.5, 1, 3] }

        var unique: [CGFloat] = []
        for value in bases.sorted() where !unique.contains(where: { abs($0 - value) < 0.01 }) {
            unique.append(value)
        }

        return unique.map { LensPreset(base: $0, label: Self.format($0)) }
    }

    private static func format(_ value: CGFloat) -> String {
        abs(value - value.rounded()) < 0.05
            ? String(format: "%.0f×", value)
            : String(format: "%.1f×", value)
    }

    // MARK: - 变焦

    func setZoom(_ value: CGFloat) {
        let clamped = max(zoomBase, min(value, 15))

        DispatchQueue.main.async {
            if abs(self.zoom - clamped) > 0.001 { self.zoom = clamped }
        }

        sessionQueue.async { [weak self] in
            guard let self, let device = self.device else { return }
            guard (try? device.lockForConfiguration()) != nil else { return }

            let factor = max(1, min(clamped / self.zoomBase, device.maxAvailableVideoZoomFactor))
            device.videoZoomFactor = factor
            device.unlockForConfiguration()
        }
    }

    /// 点镜头档位：带 ramp 过渡，比硬切自然
    func rampZoom(to value: CGFloat) {
        let clamped = max(zoomBase, min(value, 15))

        DispatchQueue.main.async {
            if abs(self.zoom - clamped) > 0.001 { self.zoom = clamped }
        }

        sessionQueue.async { [weak self] in
            guard let self, let device = self.device else { return }
            guard (try? device.lockForConfiguration()) != nil else { return }

            let factor = max(1, min(clamped / self.zoomBase, device.maxAvailableVideoZoomFactor))
            device.ramp(toVideoZoomFactor: factor, withRate: 9)
            device.unlockForConfiguration()
        }
    }

    /// 当前焦段落在哪一档，用于高亮
    var activeLensBase: CGFloat {
        var result = lenses.first?.base ?? 1
        for lens in lenses.sorted(by: { $0.base < $1.base }) where zoom >= lens.base - 0.01 {
            result = lens.base
        }
        return result
    }

    // MARK: - 前后摄

    func switchCamera() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let target: AVCaptureDevice.Position = self.position == .back ? .front : .back

            guard let dev = Self.pickDevice(for: target),
                  let devInput = try? AVCaptureDeviceInput(device: dev) else { return }

            self.session.beginConfiguration()
            if let current = self.input { self.session.removeInput(current) }

            guard self.session.canAddInput(devInput) else {
                if let current = self.input { self.session.addInput(current) }
                self.session.commitConfiguration()
                return
            }

            self.session.addInput(devInput)
            self.input = devInput
            self.device = dev
            self.applyConnections(for: target)
            self.session.commitConfiguration()

            self.publishDeviceState(dev, position: target)
            self.didReportAspect = false
        }
    }

    // MARK: - 对焦与曝光

    /// point 是设备坐标系（左上 0,0，右下 1,1）
    func focus(at point: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.device else { return }
            guard (try? device.lockForConfiguration()) != nil else { return }

            let clamped = CGPoint(
                x: min(max(point.x, 0.05), 0.95),
                y: min(max(point.y, 0.05), 0.95)
            )

            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = clamped
                if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = clamped
                if device.isExposureModeSupported(.autoExpose) { device.exposureMode = .autoExpose }
            }
            device.unlockForConfiguration()

            DispatchQueue.main.async { self.focusPoint = clamped }

            // 单次对焦后回到连续对焦，和原生相机一致
            self.sessionQueue.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, let device = self.device else { return }
                guard (try? device.lockForConfiguration()) != nil else { return }
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                device.unlockForConfiguration()
            }
        }
    }

    func setExposureBias(_ value: Float) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.device else { return }
            let clamped = min(max(value, device.minExposureTargetBias), device.maxExposureTargetBias)
            device.setExposureTargetBias(clamped, completionHandler: nil)
            DispatchQueue.main.async {
                if abs(self.exposureBias - clamped) > 0.01 { self.exposureBias = clamped }
            }
        }
    }

    // MARK: - LUT

    /// LUT 参数变了就调一次，重建预览滤镜
    func refreshPreviewFilter() {
        let built: CIFilter?
        if lutEnabled, let cube = lutCube {
            built = cube.filter(intensity: lutIntensity)
        } else {
            built = nil
        }
        filterLock.lock()
        previewFilter = built
        filterLock.unlock()
    }

    private func currentPreviewFilter() -> CIFilter? {
        filterLock.lock()
        defer { filterLock.unlock() }
        return previewFilter
    }

    // MARK: - 拍照

    func capturePhoto() async throws -> Data {
        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = .quality
        let cube = lutEnabled ? lutCube : nil
        let level = lutIntensity

        let raw: Data = try await withCheckedThrowingContinuation { cont in
            sessionQueue.async { [weak self] in
                guard let self else {
                    cont.resume(throwing: PhotoProcessor.ProcessingError.noData)
                    return
                }
                let delegate = PhotoCaptureDelegate { [weak self] result in
                    self?.pendingCapture = nil
                    cont.resume(with: result)
                }
                self.pendingCapture = delegate
                self.photoOutput.capturePhoto(with: settings, delegate: delegate)
            }
        }

        return PhotoProcessor.apply(cube: cube, intensity: level, to: raw)
    }

    /// 供缩略图使用的取景快照（未套 LUT），限频
    func currentSnapshot() -> CIImage? {
        snapshot
    }
}

// MARK: - 帧回调

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        if !didReportAspect {
            didReportAspect = true
            let w = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
            let h = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
            if w > 0, h > 0 {
                DispatchQueue.main.async { self.frameAspect = w / h }
            }
        }

        var image = CIImage(cvPixelBuffer: pixelBuffer, options: [.colorSpace: LUTCube.srgb])

        let now = Date().timeIntervalSinceReferenceDate
        if now - lastSnapshotAt > 0.8 {
            lastSnapshotAt = now
            snapshot = image
        }

        if let filter = currentPreviewFilter() {
            filter.setValue(image, forKey: kCIInputImageKey)
            if let out = filter.outputImage { image = out }
        }

        onFrame?(image)
    }
}

// MARK: - 拍照代理

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (Result<Data, Error>) -> Void
    private var finished = false

    init(completion: @escaping (Result<Data, Error>) -> Void) {
        self.completion = completion
    }

    private func finish(_ result: Result<Data, Error>) {
        guard !finished else { return }
        finished = true
        completion(result)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error { finish(.failure(error)); return }
        guard let data = photo.fileDataRepresentation() else {
            finish(.failure(PhotoProcessor.ProcessingError.noData))
            return
        }
        finish(.success(data))
    }
}
