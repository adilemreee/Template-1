import AVFoundation
import CoreMotion
import SwiftUI
import UIKit

/// Device orientation for the Sky Lens: the rotation from local (north, west, up) coordinates
/// into the device frame, read from Core Motion's fused attitude once per frame.
@MainActor
final class SkyLensMotion {
    private let manager = CMMotionManager()
    private(set) var deviceFromLocal: Mat3?
    private(set) var calibration: CMMagneticFieldCalibrationAccuracy = .uncalibrated
    private(set) var usesTrueNorth = false
    /// Votes on whether `rotationMatrix` maps local → device (columns) or device → local (rows),
    /// settled by comparing its vertical against measured gravity.
    private var columnVotes = 0

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 60
        let frames = CMMotionManager.availableAttitudeReferenceFrames()
        let frame: CMAttitudeReferenceFrame = frames.contains(.xTrueNorthZVertical) ? .xTrueNorthZVertical : .xMagneticNorthZVertical
        usesTrueNorth = frame == .xTrueNorthZVertical
        manager.showsDeviceMovementDisplay = true
        manager.startDeviceMotionUpdates(using: frame)
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }

    func update() {
        guard let motion = manager.deviceMotion else { return }
        let m = motion.attitude.rotationMatrix
        let matrix = Mat3(r0: SIMD3(m.m11, m.m12, m.m13), r1: SIMD3(m.m21, m.m22, m.m23), r2: SIMD3(m.m31, m.m32, m.m33))
        let g = SIMD3(motion.gravity.x, motion.gravity.y, motion.gravity.z)
        let len = (g * g).sum().squareRoot()
        if len > 0.5 {
            let up = -g / len
            let byColumn = (SIMD3(m.m13, m.m23, m.m33) * up).sum()
            let byRow = (SIMD3(m.m31, m.m32, m.m33) * up).sum()
            if abs(byColumn - byRow) > 0.25 { columnVotes = max(-30, min(30, columnVotes + (byColumn > byRow ? 1 : -1))) }
        }
        deviceFromLocal = columnVotes >= 0 ? matrix : matrix.transposed
        calibration = motion.magneticField.accuracy
    }
}

/// The back camera behind the Sky Lens. Frames are only shown, never recorded or uploaded.
@MainActor
final class SkyLensCamera {
    private struct Box: @unchecked Sendable { let session: AVCaptureSession }
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "karman.skylens.camera")
    private var configured = false
    /// Vertical field of view as displayed in portrait (aspect fill shows the sensor's long side).
    private(set) var verticalFOV: Double?

    static var isAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }
    static var isDenied: Bool {
        let s = AVCaptureDevice.authorizationStatus(for: .video)
        return s == .denied || s == .restricted
    }

    static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    func start() {
        if !configured { configure() }
        let box = Box(session: session)
        queue.async { if !box.session.isRunning { box.session.startRunning() } }
    }

    func stop() {
        let box = Box(session: session)
        queue.async { if box.session.isRunning { box.session.stopRunning() } }
    }

    private func configure() {
        configured = true
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.beginConfiguration()
        session.sessionPreset = .high
        if session.canAddInput(input) { session.addInput(input) }
        session.commitConfiguration()
        verticalFOV = Double(device.activeFormat.videoFieldOfView)
    }
}

/// Live camera preview layer for SwiftUI.
struct SkyLensCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
