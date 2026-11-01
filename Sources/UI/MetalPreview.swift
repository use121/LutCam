import MetalKit
import SwiftUI
import UIKit

/// 用 MTKView 直接画 CIImage，比 SwiftUI Image 逐帧转换快得多。
///
/// 支持画幅：按目标宽高比在画面里留黑边，取景框看到的构图就是拍出来的构图。
struct MetalPreview: UIViewRepresentable {
    let controller: CameraController
    /// 目标画幅，宽 / 高
    let aspect: CGFloat

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.framebufferOnly = false
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 60
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.isUserInteractionEnabled = false

        let renderer = PreviewRenderer(view: view)
        renderer.setAspectRatio(aspect)
        context.coordinator.renderer = renderer

        controller.onFrame = { [weak renderer] image in
            renderer?.submit(image)
        }
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.renderer?.setAspectRatio(aspect)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var renderer: PreviewRenderer?
    }
}

/// CIImage → Metal 纹理。
final class PreviewRenderer {
    private let context: CIContext
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let lock = NSLock()
    private var latest: CIImage?
    private var aspectRatio: CGFloat = 3.0 / 4.0
    private weak var view: MTKView?

    init(view: MTKView) {
        self.view = view
        self.device = view.device ?? MTLCreateSystemDefaultDevice()!
        self.queue = device.makeCommandQueue()!
        self.context = CIContext(mtlDevice: device, options: [
            .workingColorSpace: LUTCube.srgb,
            .outputColorSpace: LUTCube.srgb,
            .cacheIntermediates: false
        ])
    }

    func setAspectRatio(_ ratio: CGFloat) {
        lock.lock()
        aspectRatio = ratio
        lock.unlock()
    }

    func submit(_ image: CIImage) {
        lock.lock()
        latest = image
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.draw()
        }
    }

    private func draw() {
        guard let view, let drawable = view.currentDrawable else { return }

        lock.lock()
        let image = latest
        let ratio = aspectRatio
        lock.unlock()

        guard let image else { return }

        let width = CGFloat(drawable.texture.width)
        let height = CGFloat(drawable.texture.height)
        let full = CGRect(x: 0, y: 0, width: width, height: height)

        // 画幅目标区域（居中，尽量大）
        var target = full
        if ratio > 0 {
            let fullRatio = width / height
            if ratio < fullRatio {
                let w = height * ratio
                target = CGRect(x: (width - w) / 2, y: 0, width: w, height: height)
            } else {
                let h = width / ratio
                target = CGRect(x: 0, y: (height - h) / 2, width: width, height: h)
            }
        }

        // aspect-fill 到目标区域
        let scale = max(target.width / image.extent.width, target.height / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let positioned = scaled.transformed(by: CGAffineTransform(
            translationX: target.midX - scaled.extent.midX,
            y: target.midY - scaled.extent.midY
        ))

        // 铺在黑底上，目标区域之外就是黑边
        let canvas = CIImage(color: .black).cropped(to: full)
        let composited = positioned.composited(over: canvas)

        guard let buffer = queue.makeCommandBuffer() else { return }

        context.render(
            composited,
            to: drawable.texture,
            commandBuffer: buffer,
            bounds: full,
            colorSpace: LUTCube.srgb
        )

        buffer.present(drawable)
        buffer.commit()
    }
}
