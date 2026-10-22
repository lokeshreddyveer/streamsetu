import Foundation
import Compression

enum GzipError: Error, LocalizedError {
    case notGzip, corrupt, tooLarge
    var errorDescription: String? {
        switch self {
        case .notGzip: "Not a gzip file."
        case .corrupt: "The guide file is corrupt."
        case .tooLarge: "The guide file is far larger than a guide should be, so it was not unpacked."
        }
    }
}

/// Streaming gzip decompression to a file (constant memory, even for multi-hundred-MB guides).
enum GzipInflater {
    static func isGzip(_ url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        let h = (try? fh.read(upToCount: 2)) ?? Data()
        return h.count == 2 && h[h.startIndex] == 0x1f && h[h.startIndex + 1] == 0x8b
    }

    /// The most a guide may grow to once unpacked. A real guide is tens of megabytes; a tiny file that unpacks to gigabytes is refused before it fills the disk.
    static let maxOutput: Int64 = 1_500_000_000

    static func inflate(from src: URL, to dst: URL, maxOutput: Int64 = GzipInflater.maxOutput) throws {
        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }
        let head = try input.read(upToCount: 4096) ?? Data()
        guard head.count > 18, head[0] == 0x1f, head[1] == 0x8b else { throw GzipError.notGzip }

        // RFC 1952 header: 10 fixed bytes + optional extra / name / comment / header CRC
        let flags = head[3]
        var pos = 10
        if flags & 0x04 != 0 { pos += 2 + (Int(head[pos]) | Int(head[pos + 1]) << 8) }
        if flags & 0x08 != 0 { while pos < head.count, head[pos] != 0 { pos += 1 }; pos += 1 }
        if flags & 0x10 != 0 { while pos < head.count, head[pos] != 0 { pos += 1 }; pos += 1 }
        if flags & 0x02 != 0 { pos += 2 }
        guard pos < head.count else { throw GzipError.corrupt }
        try input.seek(toOffset: UInt64(pos))

        FileManager.default.createFile(atPath: dst.path, contents: nil)
        let output = try FileHandle(forWritingTo: dst)
        defer { try? output.close() }

        let bufSize = 128 * 1024
        let srcBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        let dstBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { srcBuf.deallocate(); dstBuf.deallocate() }

        var stream = compression_stream(dst_ptr: dstBuf, dst_size: bufSize, src_ptr: UnsafePointer(srcBuf), src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw GzipError.corrupt }
        defer { compression_stream_destroy(&stream) }
        // compression_stream_init zeroes every field, so the output buffer must be set afterwards.
        stream.dst_ptr = dstBuf
        stream.dst_size = bufSize
        stream.src_size = 0

        var inputEnded = false
        var finished = false
        var written: Int64 = 0
        while !finished {
            if stream.src_size == 0, !inputEnded {
                let chunk = try input.read(upToCount: bufSize) ?? Data()
                if chunk.isEmpty { inputEnded = true }
                else {
                    chunk.copyBytes(to: srcBuf, count: chunk.count)
                    stream.src_ptr = UnsafePointer(srcBuf)
                    stream.src_size = chunk.count
                }
            }
            let status = compression_stream_process(&stream, inputEnded ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
            switch status {
            case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                let produced = bufSize - stream.dst_size
                if produced > 0 {
                    written += Int64(produced)
                    if written > maxOutput { try? FileManager.default.removeItem(at: dst); throw GzipError.tooLarge }
                    try output.write(contentsOf: Data(bytes: dstBuf, count: produced))
                }
                stream.dst_ptr = dstBuf
                stream.dst_size = bufSize
                if status == COMPRESSION_STATUS_END { finished = true }
                else if inputEnded, produced == 0 { finished = true }
            default:
                throw GzipError.corrupt
            }
            try Task.checkCancellation()
        }
    }
}
