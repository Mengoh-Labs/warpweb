import Foundation

public enum TerminalEvent: Equatable, Sendable {
    case text(String), paste(String), key(String), control(UInt8)
    case modifiedKey(String, shift: Bool, alt: Bool, ctrl: Bool)
    case mouse(button: Int, column: Int, row: Int, released: Bool)
    case pixels(width: Int, height: Int)
    case graphics(String)
}

/// Incremental parser: terminal replies and unknown control sequences never become page text.
public struct TerminalInput {
    private var buffer: [UInt8] = []
    private var pasting = false
    private var discardedPaste = false
    public init() {}
    public mutating func flushEscape() -> [TerminalEvent] {
        guard !pasting, buffer == [27] else { return [] }
        buffer = []; return [.key("Escape")]
    }
    public mutating func feed(_ data: Data) -> [TerminalEvent] {
        buffer.append(contentsOf: data)
        if buffer.count > 65_536 && !pasting { buffer = []; return [] }
        var result: [TerminalEvent] = []
        while let first = buffer.first {
            if pasting {
                let endMarker: [UInt8] = [27,91,50,48,49,126]
                guard let end = (0..<max(0,buffer.count-5)).first(where: { Array(buffer[$0..<$0+6]) == endMarker }) else {
                    if buffer.count > 16_384 { buffer = Array(buffer.suffix(5)); discardedPaste = true }
                    break
                }
                if !discardedPaste, end <= 16_384, let text = String(bytes:buffer.prefix(end),encoding:.utf8) { result.append(.paste(text)) }
                buffer.removeFirst(end+6); pasting = false; discardedPaste = false; continue
            }
            if first == 27 {
                guard buffer.count >= 2 else { break }
                // A lone Escape key may be followed by an asynchronous terminal
                // acknowledgment. Preserve both rather than swallowing its prefix.
                if buffer[1] == 27 {
                    result.append(.key("Escape")); buffer.removeFirst(); continue
                }
                if buffer[1] == 95 { // APC / Kitty response
                    guard let end = (2..<max(2, buffer.count-1)).first(where: { buffer[$0] == 27 && buffer[$0+1] == 92 }) else { break }
                    let payload = String(decoding: buffer[2..<end], as: UTF8.self)
                    if payload.hasPrefix("G") { result.append(.graphics(String(payload.dropFirst()))) }
                    buffer.removeFirst(end+2); continue
                }
                if buffer[1] == 79 { // SS3 function/navigation keys
                    guard buffer.count >= 3 else { break }
                    let keys: [UInt8:String] = [80:"F1",81:"F2",82:"F3",83:"F4",65:"ArrowUp",66:"ArrowDown",67:"ArrowRight",68:"ArrowLeft",72:"Home",70:"End"]
                    if let key = keys[buffer[2]] { result.append(.key(key)) }
                    buffer.removeFirst(3); continue
                }
                if buffer[1] == 91 { // CSI
                    guard let end = (2..<buffer.count).first(where: { (64...126).contains(buffer[$0]) }) else { break }
                    let sequence = String(decoding: buffer[2...end], as: UTF8.self)
                    buffer.removeFirst(end+1)
                    if sequence == "200~" { pasting = true; continue }
                    if sequence.hasPrefix("<"), let last = sequence.last, last == "M" || last == "m" {
                        let values = sequence.dropFirst().dropLast().split(separator: ";").compactMap { Int($0) }
                        if values.count == 3 { result.append(.mouse(button: values[0], column: values[1], row: values[2], released: last == "m")) }
                    } else if sequence.hasPrefix("4;"), sequence.hasSuffix("t") {
                        let values = sequence.dropLast().split(separator: ";").compactMap { Int($0) }
                        if values.count == 3, values[1] > 0, values[2] > 0 { result.append(.pixels(width: values[2], height: values[1])) }
                    } else {
                        let keys = ["A":"ArrowUp", "B":"ArrowDown", "C":"ArrowRight", "D":"ArrowLeft", "Z":"BackTab", "3~":"Delete", "5~":"PageUp", "6~":"PageDown", "H":"Home", "F":"End", "P":"F1", "Q":"F2", "R":"F3", "S":"F4", "11~":"F1", "12~":"F2", "13~":"F3", "14~":"F4", "15~":"F5", "17~":"F6", "19~":"F8"]
                        if let key = keys[sequence] { result.append(.key(key)) }
                        else if let suffix = sequence.last {
                            let values = sequence.dropLast().split(separator:";").compactMap { Int($0) }
                            if values.count == 2, (2...8).contains(values[1]), let key = keys[suffix == "~" ? "\(values[0])~" : String(suffix)] {
                                let flags = values[1]-1
                                result.append(.modifiedKey(key,shift:flags & 1 != 0,alt:flags & 2 != 0,ctrl:flags & 4 != 0))
                            }
                        }
                    }
                    continue
                }
                if (32...126).contains(buffer[1]) {
                    result.append(.modifiedKey(String(UnicodeScalar(buffer[1])),shift:false,alt:true,ctrl:false))
                }
                buffer.removeFirst(2); continue
            }
            if first < 32 || first == 127 {
                result.append(.control(first)); buffer.removeFirst(); continue
            }
            let length: Int
            switch first { case 0..<128: length=1; case 194...223: length=2; case 224...239: length=3; case 240...244: length=4; default: buffer.removeFirst(); continue }
            guard buffer.count >= length else { break }
            if let text = String(bytes: buffer.prefix(length), encoding: .utf8) { result.append(.text(text)) }
            buffer.removeFirst(length)
        }
        return result
    }
}

public enum KittyGraphics {
    public static func probe(id: Int) -> String { "\u{1b}_Ga=q,i=\(id),f=24,s=1,v=1;AAAA\u{1b}\\" }
    public static func delete(_ id: Int) -> String { "\u{1b}_Ga=d,d=I,i=\(id),q=2;\u{1b}\\" }
    public static func frame(_ png: Data, id: Int, columns: Int, rows: Int, acknowledge: Bool = false) -> Data {
        // Warp foreground image layers intercept button events (upstream #15882).
        // A negative z-index keeps the image visible beneath the empty text grid
        // without introducing a foreground hit-test layer.
        let payload = Array(png.base64EncodedString().utf8)
        var output = Data("\u{1b}[1;1H".utf8)
        for offset in stride(from: 0, to: payload.count, by: 4096) {
            let end = min(offset+4096, payload.count)
            let metadata = offset == 0 ? "a=T,f=100,i=\(id),c=\(columns),r=\(rows),z=-1,C=1,q=\(acknowledge ? 0 : 2)," : ""
            output.append(Data("\u{1b}_G\(metadata)m=\(end == payload.count ? 0 : 1);".utf8))
            output.append(contentsOf: payload[offset..<end])
            output.append(Data("\u{1b}\\".utf8))
        }
        return output
    }
    /// Restrict terminal chrome to printable ASCII, so titles cannot inject escape commands or wrap via wide glyphs.
    public static func label(_ text: String) -> String {
        String(text.unicodeScalars.filter { (32...126).contains($0.value) })
    }
}

/// Four disjoint IDs for each live macOS PID. The high bit separates our IDs
/// from conventional small IDs used by other terminal applications.
public struct SessionGraphicsIDs: Sendable {
    public let probe: Int, sharedProbe: Int, first: Int, second: Int
    public init(processID: Int) {
        precondition((1...0x1fffffff).contains(processID))
        let base = 0x80000000 + processID * 4
        probe = base; sharedProbe = base + 1; first = base + 2; second = base + 3
    }
}
