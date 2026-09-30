import Darwin
import Foundation

/// Streams the complete lines of a file between two offsets (spec §5.1). The
/// checkpoint only ever moves past a newline, so a line Claude Code is still
/// writing is left whole for the next pass; a line longer than `maxLine` is
/// skipped and counted, never handed on. Each line comes with the offset just
/// after its newline; returning `true` stops the read there (a batch is full).
struct LineReader: Sendable {
    var chunkSize = 1 << 20
    /// The longest reply line in real Claude Code logs read on 2026-09-29 was
    /// 541 KB, the longest line of any kind 2.4 MB.
    var maxLine = 8 << 20

    struct Outcome: Equatable, Sendable {
        /// File offset just after the last newline read.
        var checkpoint: Int64
        var oversized = 0
        /// Bytes after the checkpoint, up to `end`: an unfinished line.
        var pendingBytes: Int64 = 0
        /// The callback asked to stop; the read resumes from `checkpoint`.
        var stopped = false
    }

    func read(fd: Int32, from start: Int64, to end: Int64, line: (Data, Int64) throws -> Bool) throws -> Outcome {
        var outcome = Outcome(checkpoint: start)
        var buffer = Data()          // bytes after the checkpoint (unless skipping)
        var skipping = false         // inside an oversized line
        var position = start
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        while position < end {
            let want = Int(min(Int64(chunkSize), end - position))
            let got = chunk.withUnsafeMutableBytes { pread(fd, $0.baseAddress, want, off_t(position)) }
            if got < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if got == 0 { break }
            let chunkStart = position
            position += Int64(got)
            var scanFrom = 0
            while let newline = chunk[scanFrom..<got].firstIndex(of: 0x0A) {
                if skipping || buffer.count + (newline - scanFrom) > maxLine {
                    skipping = false
                    outcome.oversized += 1
                } else {
                    buffer.append(contentsOf: chunk[scanFrom..<newline])
                    if !buffer.isEmpty, try line(buffer, chunkStart + Int64(newline + 1)) {
                        outcome.checkpoint = chunkStart + Int64(newline + 1)
                        outcome.stopped = true
                        return outcome
                    }
                }
                buffer.removeAll(keepingCapacity: true)
                scanFrom = newline + 1
                outcome.checkpoint = chunkStart + Int64(scanFrom)
            }
            if !skipping {
                buffer.append(contentsOf: chunk[scanFrom..<got])
                if buffer.count > maxLine {
                    skipping = true
                    buffer.removeAll()
                }
            }
        }
        outcome.pendingBytes = max(0, min(position, end) - outcome.checkpoint)
        return outcome
    }
}
