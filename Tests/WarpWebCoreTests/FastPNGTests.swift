import Testing
import Foundation
import CoreGraphics
import ImageIO
import CWarpWeb

@Test func parallelPNGRoundTripsOpaquePixels() throws {
    let space = CGColorSpace(name:CGColorSpace.sRGB)!
    let profile = space.copyICCData()! as Data
    for (width,height) in [(1,1),(3,7),(257,131)] {
        let stride = width*4+12
        var pixels = [UInt8](repeating:0,count:stride*height)
        for y in 0..<height {
            for x in 0..<width {
                let p=y*stride+x*4
                pixels[p]=UInt8(truncatingIfNeeded:x*73+y*19)
                pixels[p+1]=UInt8(truncatingIfNeeded:x*11+y*97)
                pixels[p+2]=UInt8(truncatingIfNeeded:x^y)
                pixels[p+3]=255
            }
        }
        var length = 0
        let encoded = pixels.withUnsafeBufferPointer { rgba in
            profile.withUnsafeBytes { icc in
                warpweb_encode_png_rgba(rgba.baseAddress,width,height,stride,
                    icc.bindMemory(to:UInt8.self).baseAddress,icc.count,&length)
            }
        }
        let pointer = try #require(encoded)
        let data=Data(bytesNoCopy:pointer,count:length,deallocator:.free)
        let source=try #require(CGImageSourceCreateWithData(data as CFData,nil))
        let image=try #require(CGImageSourceCreateImageAtIndex(source,0,nil))
        #expect(image.width==width && image.height==height)
        #expect(image.colorSpace?.copyICCData() != nil)
        let context=try #require(CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
            space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
        let bytes=try #require(context.data).assumingMemoryBound(to:UInt8.self)
        for y in 0..<height {
            #expect(Array(UnsafeBufferPointer(start:bytes+y*width*4,count:width*4)) == Array(pixels[y*stride..<y*stride+width*4]))
        }
    }
}

@Test func parallelPNGRejectsUnsafeInputsAndTransparency() {
    var size=123
    let pixels:[UInt8]=[255,0,0,128]
    pixels.withUnsafeBufferPointer { p in
        #expect(warpweb_encode_png_rgba(p.baseAddress,1,1,4,nil,0,&size)==nil)
        #expect(size==0)
        #expect(warpweb_encode_png_rgba(p.baseAddress,0,1,4,nil,0,&size)==nil)
        #expect(warpweb_encode_png_rgba(p.baseAddress,1,1,3,nil,0,&size)==nil)
        #expect(warpweb_encode_png_rgba(p.baseAddress,Int.max,1,4,nil,0,&size)==nil)
        #expect(warpweb_encode_png_rgba(nil,1,1,4,nil,0,&size)==nil)
    }
}
