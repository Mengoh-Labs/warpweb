import CoreGraphics
import CoreVideo

/// A read-locked buffer lease outlives every lazy Core Graphics consumer.
private final class PixelBufferLease {
    let buffer: CVPixelBuffer
    init?(_ buffer: CVPixelBuffer) {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        self.buffer = buffer
    }
    deinit { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
}

public enum PixelBufferImage {
    /// Wrap opaque/premultiplied BGRA storage without an intermediate render or copy.
    /// The producer must not mutate the buffer while the returned image is retained.
    public static func make(_ buffer: CVPixelBuffer) -> CGImage? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              !CVPixelBufferIsPlanar(buffer), let lease = PixelBufferLease(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0, width <= Int.max/4, stride >= width*4,
              stride <= Int.max/height, let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let retained = Unmanaged.passRetained(lease)
        guard let provider = CGDataProvider(dataInfo:retained.toOpaque(), data:base, size:stride*height,
            releaseData:{ info, _, _ in
                if let info { Unmanaged<PixelBufferLease>.fromOpaque(info).release() }
            }) else { retained.release(); return nil }
        let space = CVImageBufferGetColorSpace(buffer)?.takeUnretainedValue() ?? CGColorSpace(name:CGColorSpace.sRGB)!
        return CGImage(width:width, height:height, bitsPerComponent:8, bitsPerPixel:32,
            bytesPerRow:stride, space:space,
            bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider:provider, decode:nil, shouldInterpolate:false, intent:.defaultIntent)
    }
}
