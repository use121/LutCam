import MetalKit
import SwiftUI
import UIKit

/// 用 MTKView 直接画 CIImage，比 SwiftUI Image 逐帧转换快得多。
struct MetalPreview: UIViewRepresentable {
    let controller: CameraController

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
        context.coordinator.renderer = renderer
        controller.onFrame = { [weak renderer] image in
            renderer?.submit(image)
        }
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

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
        lock.unlock()

        guard let image else { return }

        let target = CGRect(
            x: 0, y: 0,
            width: CGFloat(drawable.texture.width),
            height: CGFloat(drawable.texture.height)
        )

        // aspect-fill：等比放大到铺满，居中裁切
        let scale = max(target.width / image.extent.width, target.height / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let offsetX = (target.width - scaled.extent.width) / 2
        let offsetY = (target.height - scaled.extent.height) / 2
        let centered = scaled.transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))

        guard let buffer = queue.makeCommandBuffer() else { return }

        context.render(
            centered,
            to: drawable.texture,
            commandBuffer: buffer,
            bounds: target,
            colorSpace: LUTCube.srgb
        )

        buffer.present(drawable)
        buffer.commit()
    }
}
