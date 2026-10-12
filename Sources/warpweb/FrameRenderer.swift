import AppKit
import CWarpWeb

struct PointerOverlay: Sendable {
    let point: CGPoint
    let kind: String
    let pressed: Bool
    func draw(in context: CGContext, scaleX: Double, scaleY: Double, height: Int) {
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x:point.x*scaleX,y:Double(height)-point.y*scaleY)
        context.scaleBy(x:scaleX,y:-scaleY)
        context.setLineJoin(.round); context.setLineCap(.round)
        if pressed || kind == "pointer" {
            context.setStrokeColor(CGColor(red:0.55,green:0.3,blue:1,alpha:1))
            context.setLineWidth(3)
            context.strokeEllipse(in:CGRect(x:-7,y:-7,width:14,height:14))
        }
        let path = CGMutablePath()
        if kind == "text" {
            path.move(to:CGPoint(x:0,y:-8)); path.addLine(to:CGPoint(x:0,y:8))
            path.move(to:CGPoint(x:-4,y:-8)); path.addLine(to:CGPoint(x:4,y:-8))
            path.move(to:CGPoint(x:-4,y:8)); path.addLine(to:CGPoint(x:4,y:8))
            context.addPath(path); context.setStrokeColor(CGColor(gray:1,alpha:1)); context.setLineWidth(4); context.strokePath()
            context.addPath(path); context.setStrokeColor(CGColor(gray:0.05,alpha:1)); context.setLineWidth(2); context.strokePath()
        } else {
            path.move(to:.zero)
            for point in [CGPoint(x:1,y:20),CGPoint(x:6,y:15),CGPoint(x:10,y:23),CGPoint(x:14,y:21),CGPoint(x:10,y:13),CGPoint(x:17,y:12)] { path.addLine(to:point) }
            path.closeSubpath()
            context.addPath(path); context.setFillColor(CGColor(gray:0.05,alpha:1))
            context.setStrokeColor(CGColor(gray:1,alpha:1)); context.setLineWidth(2); context.drawPath(using:.fillStroke)
        }
    }
}

/// Composition and the single final encoding run away from AppKit's input queue.
enum FrameRenderer {
    static func encode(_ image: CGImage, png: Bool = true) -> Response {
        guard let data = NSBitmapImageRep(cgImage:image).representation(using:png ? .png : .jpeg,
            properties:png ? [:] : [.compressionFactor:0.78]) else {
            return .json(["error":"Cannot encode browser frame"],status:503)
        }
        return Response(type:png ? "image/png" : "image/jpeg",data:data,imageEncoder:png ? "platform-png" : "platform-jpeg")
    }
    static func compose(background: CGImage, content: CGImage?, width: Int, height: Int,
                        logicalWidth: Double, logicalHeight: Double, header: Double, footer: Double, menu: CGRect?, pointer: PointerOverlay? = nil, raw: Bool = false) -> Response {
        guard let context = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            return .json(["error":"Cannot compose browser frame"],status:503)
        }
        let sx = Double(width)/logicalWidth, sy = Double(height)/logicalHeight
        context.interpolationQuality = .high
        context.draw(background,in:CGRect(x:0,y:0,width:width,height:height))
        if let content {
            context.draw(content,in:CGRect(x:0,y:footer*sy,width:Double(width),height:(logicalHeight-header-footer)*sy))
            if let menu {
                let crop = CGRect(x:menu.minX*sx,y:menu.minY*sy,width:menu.width*sx,height:menu.height*sy)
                    .intersection(CGRect(x:0,y:0,width:width,height:height))
                if !crop.isEmpty, let overlay = background.cropping(to:crop) {
                    context.draw(overlay,in:CGRect(x:crop.minX,y:Double(height)-crop.maxY,width:crop.width,height:crop.height))
                }
            }
        }
        pointer?.draw(in:context,scaleX:sx,scaleY:sy,height:height)
        if raw, let bytes = context.data {
            return Response(type:"image/rgba",data:Data(bytes:bytes,count:width*height*4),imageEncoder:"raw-rgba")
        }
        // ImageIO tags this DeviceRGB bitmap as sRGB. Preserve that interpretation
        // in the fast path instead of emitting an untagged image.
        let profile = (context.colorSpace?.copyICCData() ?? CGColorSpace(name:CGColorSpace.sRGB)?.copyICCData()) as Data?
        if let bytes = context.data, let profile {
            var length = 0
            let encoded = profile.withUnsafeBytes { icc in
                warpweb_encode_png_rgba(bytes.assumingMemoryBound(to:UInt8.self),width,height,context.bytesPerRow,
                    icc.bindMemory(to:UInt8.self).baseAddress,icc.count,&length)
            }
            if let encoded {
                return Response(type:"image/png",data:Data(bytesNoCopy:encoded,count:length,deallocator:.free),
                    imageEncoder:"parallel-png")
            }
        }
        guard let image = context.makeImage() else { return .json(["error":"Cannot compose browser frame"],status:503) }
        return encode(image)
    }
}

/// A single in-flight frame provides backpressure without blocking native input.
final class TerminalOutput: @unchecked Sendable {
    private let queue = DispatchQueue(label:"warpweb.terminal-output",qos:.userInitiated)
    func write(_ data: Data) { queue.sync { FileHandle.standardOutput.write(data) } }
    func send(_ data: Data) async {
        await withCheckedContinuation { continuation in
            queue.async {
                FileHandle.standardOutput.write(data)
                continuation.resume()
            }
        }
    }
}
