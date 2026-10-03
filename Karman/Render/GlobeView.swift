import MetalKit
import SwiftUI
import UIKit

/// SwiftUI host for the Metal globe with pan / pinch / tilt / tap gestures.
struct GlobeView: UIViewRepresentable {
    let controller: GlobeController
    let satellites: SatelliteEngine
    var onIntroFinished: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.backgroundColor = .black
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .invalid
        view.sampleCount = 1
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 120
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.autoResizeDrawable = true
        #if targetEnvironment(simulator)
        view.contentScaleFactor = 2.0
        #else
        view.contentScaleFactor = min(context.environment.displayScale, 2.6)
        #endif
        if let renderer = GlobeRenderer(controller: controller, satellites: satellites) {
            renderer.onIntroFinished = onIntroFinished
            view.device = renderer.device
            view.delegate = renderer
            context.coordinator.renderer = renderer
        }
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        let tilt = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTilt(_:)))
        tilt.minimumNumberOfTouches = 2
        tilt.maximumNumberOfTouches = 2
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        tap.require(toFail: doubleTap)
        for g in [pan, pinch, tilt, tap, doubleTap] as [UIGestureRecognizer] {
            g.delegate = context.coordinator
            view.addGestureRecognizer(g)
        }
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.renderer?.onIntroFinished = onIntroFinished
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let controller: GlobeController
        var renderer: GlobeRenderer?
        private var lastPinch: CGFloat = 1

        init(controller: GlobeController) { self.controller = controller }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard controller.introStart == nil, let view = g.view else { return }
            let t = g.translation(in: view)
            g.setTranslation(.zero, in: view)
            switch g.state {
            case .began, .changed:
                controller.pan(by: CGSize(width: t.x, height: t.y), viewHeight: view.bounds.height)
            case .ended, .cancelled:
                controller.endPan(velocity: g.velocity(in: view), viewHeight: view.bounds.height)
            default: break
            }
        }

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            guard controller.introStart == nil else { return }
            switch g.state {
            case .began:
                lastPinch = 1
            case .changed:
                controller.zoom(by: g.scale / lastPinch)
                lastPinch = g.scale
            default: break
            }
        }

        @objc func handleTilt(_ g: UIPanGestureRecognizer) {
            guard controller.introStart == nil, let view = g.view else { return }
            let t = g.translation(in: view)
            g.setTranslation(.zero, in: view)
            if abs(t.y) > abs(t.x) { controller.adjustTilt(by: t.y) }
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard controller.introStart == nil, let renderer, let view = g.view else { return }
            let item = renderer.pick(at: g.location(in: view))
            controller.onTap?(item)
        }

        @objc func handleDoubleTap(_ g: UITapGestureRecognizer) {
            guard controller.introStart == nil, let renderer, let view = g.view else { return }
            if let hit = renderer.globeHit(at: g.location(in: view)) {
                let d = max(controller.minDistance, 1 + (controller.pose.distance - 1) * 0.45)
                controller.focus(on: hit, distance: d, duration: 0.9)
            }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            (g is UIPinchGestureRecognizer && other is UIPanGestureRecognizer) || (g is UIPanGestureRecognizer && other is UIPinchGestureRecognizer)
        }
    }
}
