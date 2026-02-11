import AVFoundation
import Flutter
import Foundation

final class UvcCameraTexture: NSObject, FlutterTexture {
    private let lock = NSLock()
    private var pixelBuffer: CVPixelBuffer?

    func update(pixelBuffer: CVPixelBuffer) {
        lock.lock()
        self.pixelBuffer = pixelBuffer
        lock.unlock()
    }

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        lock.lock()
        let buffer = pixelBuffer
        lock.unlock()

        guard let buffer else {
            return nil
        }
        return Unmanaged.passRetained(buffer)
    }
}
