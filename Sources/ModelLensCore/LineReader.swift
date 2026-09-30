import Foundation
import Darwin

struct LineReadReport {
    var offset: UInt64
    var lineNumber: Int
    var bytes: UInt64
    var rejectedLines: Int
}

enum LineReader {
    // A partial final line is deliberately re-read on the next scan. Oversize records are skipped,
    // never interpreted as absence of evidence, and are surfaced in diagnostics.
    static func read(url: URL, offset: UInt64 = 0, lineNumber: Int = 0,
                     consume: (Data, Int) -> Void) throws -> LineReadReport {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        var buffer = Data(), committed = offset, line = lineNumber, total: UInt64 = 0
        var discarded: UInt64 = 0, rejected = 0
        let maximum = 8 * 1024 * 1024
        var chunk = [UInt8](repeating: 0, count: 512 * 1024)
        while true {
            let count = Darwin.read(handle.fileDescriptor, &chunk, chunk.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            total += UInt64(count)
            buffer.append(contentsOf: chunk.prefix(count))
            // memchr scans bytes in the system library instead of walking a Foundation Data
            // collection one Swift element at a time. This matters for multi-GB Codex histories.
            let ends: [Int] = buffer.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return [] }
                var position = 0, offsets: [Int] = []
                while position < bytes.count, let match = memchr(base.advanced(by: position), 10, bytes.count - position) {
                    let end = base.distance(to: UnsafeRawPointer(match))
                    offsets.append(end); position = end + 1
                }
                return offsets
            }
            var start = 0
            for end in ends {
                let length = end - start
                line += 1
                if discarded == 0 && length <= maximum { autoreleasepool { consume(buffer.subdata(in: start..<end), line) } }
                else { rejected += 1 }
                committed += discarded + UInt64(length + 1)
                discarded = 0
                start = end + 1
            }
            buffer = Data(buffer[start...])
            if buffer.count > maximum {
                discarded += UInt64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        return LineReadReport(offset: committed, lineNumber: line, bytes: total, rejectedLines: rejected)
    }
}
