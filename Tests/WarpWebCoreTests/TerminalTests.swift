import Foundation
import Testing
@testable import WarpWebCore
@Test func fragmentedTerminalInput() {
    var parser = TerminalInput()
    #expect(parser.feed(Data([0xc3])) == [])
    #expect(parser.feed(Data([0xa9])) == [.text("é")])
    #expect(parser.feed(Data("\u{1b}[<0;12;".utf8)) == [])
    #expect(parser.feed(Data("5M\u{1b}[A\u{03}".utf8)) == [.mouse(button: 0, column: 12, row: 5, released: false), .key("ArrowUp"), .control(3)])
}
@Test func terminalRepliesAreNotTypedIntoPage() {
    var parser = TerminalInput()
    #expect(parser.feed(Data("\u{1b}_Gi=31;OK\u{1b}\\\u{1b}[4;900;1440t".utf8)) == [.graphics("i=31;OK"), .pixels(width: 1440, height: 900)])
    #expect(parser.feed(Data("\u{1b}[999~".utf8)) == [])
}
@Test func escapeBeforeAnImageAcknowledgmentPreservesBoth() {
    var parser = TerminalInput()
    #expect(parser.feed(Data([27])) == [])
    #expect(parser.feed(Data("\u{1b}_Gi=41;OK\u{1b}\\".utf8)) == [.key("Escape"), .graphics("i=41;OK")])
}
@Test func graphicsChunksRoundTrip() throws {
    let png = Data((0..<10000).map { UInt8($0 % 256) })
    let output = String(decoding: KittyGraphics.frame(png, id: 42, columns: 80, rows: 22), as: UTF8.self)
    let packets = output.components(separatedBy: "\u{1b}_G").dropFirst().map { String($0.prefix(while: {$0 != "\u{1b}"})) }
    #expect(packets.count > 1)
    #expect(packets.first?.hasPrefix("a=T,f=100,i=42,c=80,r=22,z=-1,C=1,q=2,m=1;") == true)
    var payload = ""
    for packet in packets { let data = String(packet.split(separator: ";",maxSplits:1)[1]); #expect(data.utf8.count <= 4096); payload += data }
    #expect(packets.last?.hasPrefix("m=0;") == true)
    #expect(Data(base64Encoded: payload) == png)
}
@Test func pageTitlesCannotInjectTerminalEscapes() {
    #expect(KittyGraphics.label("title\u{1b}]52;c;secret\u{07}\r\n") == "title]52;c;secret")
}

@Test func pasteIsAtomicAndDoesNotExecuteControlBytes() {
    var parser = TerminalInput()
    #expect(parser.feed(Data("\u{1b}[200~hello\n\u{11}\u{1b}[20".utf8)) == [])
    #expect(parser.flushEscape() == [])
    #expect(parser.feed(Data("1~".utf8)) == [.paste("hello\n\u{11}")])
    #expect(parser.feed(Data("\u{1b}[1;2D".utf8)) == [.modifiedKey("ArrowLeft",shift:true,alt:false,ctrl:false)])
}
@Test func oversizedPasteIsDiscardedUntilItsEnd() {
    var parser = TerminalInput()
    _ = parser.feed(Data("\u{1b}[200~".utf8))
    _ = parser.feed(Data(repeating:65,count:70_000))
    #expect(parser.feed(Data("\u{11}\u{1b}[201~x".utf8)) == [.text("x")])
}

@Test func browserFunctionAndModifiedShortcuts() {
    var parser = TerminalInput()
    #expect(parser.feed(Data("\u{1b}O".utf8)).isEmpty)
    #expect(parser.feed(Data("P\u{1b}[15~\u{1b}[1;2R".utf8)) == [.key("F1"),.key("F5"),.modifiedKey("F3",shift:true,alt:false,ctrl:false)])
    #expect(parser.feed(Data("\u{1b}[1;3C\u{1b}[6;5~\u{1b}+".utf8)) == [.modifiedKey("ArrowRight",shift:false,alt:true,ctrl:false),.modifiedKey("PageDown",shift:false,alt:false,ctrl:true),.modifiedKey("+",shift:false,alt:true,ctrl:false)])
    #expect(parser.feed(Data("\u{1b}OX".utf8)).isEmpty)
}

@Test func graphicsIDsAreDisjointAcrossProcesses() {
    let a = SessionGraphicsIDs(processID: 1), b = SessionGraphicsIDs(processID: 99999)
    let first = Set([a.probe,a.sharedProbe,a.first,a.second])
    let second = Set([b.probe,b.sharedProbe,b.first,b.second])
    #expect(first.count == 4 && second.count == 4 && first.isDisjoint(with: second))
    #expect(first.union(second).allSatisfy { $0 > 0 && $0 <= Int(UInt32.max) })
    #expect(KittyGraphics.probe(id:b.probe).contains("i=\(b.probe),"))
}
