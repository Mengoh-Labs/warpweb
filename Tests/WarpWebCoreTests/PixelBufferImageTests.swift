import Testing
import Foundation
import CoreGraphics
import CoreVideo
import WarpWebCore

@Test func pixelBufferImageRetainsStorageAndHonorsBGRAAndStride() throws {
    let image = try autoreleasepool { () throws -> CGImage in
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil,3,5,kCVPixelFormatType_32BGRA,
            [kCVPixelBufferBytesPerRowAlignmentKey:64] as CFDictionary,&buffer) == kCVReturnSuccess)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels,[])
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        #expect(stride > 12)
        let bytes = try #require(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to:UInt8.self)
        for y in 0..<5 { for x in 0..<3 {
            let p = y*stride+x*4
            bytes[p]=UInt8(30+y); bytes[p+1]=UInt8(60+x); bytes[p+2]=120; bytes[p+3]=255
        } }
        CVPixelBufferUnlockBaseAddress(pixels,[])
        return try #require(PixelBufferImage.make(pixels))
    }
    let context = try #require(CGContext(data:nil,width:3,height:5,bitsPerComponent:8,bytesPerRow:12,
        space:CGColorSpace(name:CGColorSpace.sRGB)!,
        bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
    context.draw(image,in:CGRect(x:0,y:0,width:3,height:5))
    let output = try #require(context.data).assumingMemoryBound(to:UInt8.self)
    for p in stride(from:0,to:60,by:4) {
        #expect(Array(UnsafeBufferPointer(start:output+p,count:4)) == [120,UInt8(60+(p/4)%3),UInt8(30+p/12),255])
    }
}

@Test func pixelBufferImageRejectsOtherFormats() throws {
    var buffer: CVPixelBuffer?
    #expect(CVPixelBufferCreate(nil,4,4,kCVPixelFormatType_32ARGB,nil,&buffer) == kCVReturnSuccess)
    #expect(PixelBufferImage.make(try #require(buffer)) == nil)
}
