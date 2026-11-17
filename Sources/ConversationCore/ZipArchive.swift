import Foundation
import CZlib

/// A small, bounded ZIP implementation. Supports ordinary stored/deflated ZIPs,
/// verifies CRCs, and never lets archive paths choose filesystem destinations.
public enum ZipArchive {
    public static let maxTotalBytes = 2 * 1024 * 1024 * 1024
    public static let maxArchiveBytes = 512 * 1024 * 1024
    private static let maxEntries = 20_000

    public static func validatePath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"),
              !path.unicodeScalars.contains(where: { $0.value < 32 }),
              !components.contains(where: { $0 == ".." || $0 == "." }),
              components.dropLast().allSatisfy({ !$0.isEmpty }) else {
            throw ConversationError.invalid("Unsafe archive path: \(path)")
        }
    }

    private static func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { bytes in
            UInt32(crc32(0, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(data.count)))
        }
    }

    private static func deflated(_ data: Data) throws -> Data {
        if data.isEmpty { return Data() }
        var stream = z_stream()
        let status = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS,
                                  8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw ConversationError.invalid("Could not initialize ZIP compression.") }
        defer { deflateEnd(&stream) }
        var output = Data(count: Int(deflateBound(&stream, uLong(data.count))))
        let result = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { buffer in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(data.count)
                stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(buffer.count)
                return deflate(&stream, Z_FINISH)
            }
        }
        guard result == Z_STREAM_END else { throw ConversationError.invalid("ZIP compression failed.") }
        output.count = Int(stream.total_out)
        return output
    }

    private static func inflated(_ data: Data, size: Int) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw ConversationError.invalid("Could not initialize ZIP decompression.")
        }
        defer { inflateEnd(&stream) }
        var output = Data(count: max(size, 1))
        let result = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { buffer in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(data.count)
                stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(buffer.count)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard result == Z_STREAM_END, stream.total_out == size, stream.total_in == data.count else {
            throw ConversationError.invalid("An archive entry is damaged or has an incorrect size.")
        }
        output.count = size
        return output
    }

    public static func encode(_ files: [String: Data]) throws -> Data {
        guard files.count <= maxEntries else { throw ConversationError.invalid("Too many archive entries.") }
        var output = Data(), directory = Data()
        var total = 0
        for name in files.keys.sorted() {
            try validatePath(name)
            let data = files[name]!
            total += data.count
            guard total <= maxTotalBytes else { throw ConversationError.invalid("Archive exceeds the 2 GB uncompressed limit. Export fewer conversations.") }
            let filename = Data(name.utf8)
            guard filename.count <= Int(UInt16.max) else { throw ConversationError.invalid("Archive filename is too long.") }
            let compressed = try deflated(data)
            let method: UInt16 = compressed.count < data.count ? 8 : 0
            let payload = method == 8 ? compressed : data
            let crc = checksum(data), offset = UInt32(output.count)
            output.appendLE(UInt32(0x04034b50)); output.appendLE(UInt16(20)); output.appendLE(UInt16(0x800))
            output.appendLE(method); output.appendLE(UInt16(0)); output.appendLE(UInt16(0x21))
            output.appendLE(crc); output.appendLE(UInt32(payload.count)); output.appendLE(UInt32(data.count))
            output.appendLE(UInt16(filename.count)); output.appendLE(UInt16(0))
            output.append(filename); output.append(payload)

            directory.appendLE(UInt32(0x02014b50)); directory.appendLE(UInt16(20)); directory.appendLE(UInt16(20))
            directory.appendLE(UInt16(0x800)); directory.appendLE(method)
            directory.appendLE(UInt16(0)); directory.appendLE(UInt16(0x21))
            directory.appendLE(crc); directory.appendLE(UInt32(payload.count)); directory.appendLE(UInt32(data.count))
            directory.appendLE(UInt16(filename.count)); directory.appendLE(UInt16(0)); directory.appendLE(UInt16(0))
            directory.appendLE(UInt16(0)); directory.appendLE(UInt16(0)); directory.appendLE(UInt32(0))
            directory.appendLE(offset); directory.append(filename)
        }
        let start = UInt32(output.count)
        output.append(directory)
        output.appendLE(UInt32(0x06054b50)); output.appendLE(UInt16(0)); output.appendLE(UInt16(0))
        output.appendLE(UInt16(files.count)); output.appendLE(UInt16(files.count))
        output.appendLE(UInt32(directory.count)); output.appendLE(start); output.appendLE(UInt16(0))
        guard output.count <= maxArchiveBytes else { throw ConversationError.invalid("Compressed archive exceeds 512 MB. Export fewer conversations.") }
        return output
    }

    public static func decode(_ data: Data) throws -> [String: Data] {
        guard data.count >= 22, data.count <= maxArchiveBytes else { throw ConversationError.invalid("Invalid ZIP or archive larger than 512 MB.") }
        var end: Int?
        for index in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) {
            if try data.u32(index) == 0x06054b50,
               index + 22 + Int(try data.u16(index + 20)) == data.count { end = index; break }
        }
        guard let end else { throw ConversationError.invalid("ZIP directory not found.") }
        let count = Int(try data.u16(end + 10))
        guard try data.u16(end + 4) == 0, try data.u16(end + 6) == 0,
              try data.u16(end + 8) == count, count <= maxEntries else {
            throw ConversationError.invalid("Multipart and ZIP64 archives are not supported.")
        }
        let directorySize = Int(try data.u32(end + 12))
        var cursor = Int(try data.u32(end + 16))
        guard cursor + directorySize == end else { throw ConversationError.invalid("Invalid ZIP directory size.") }
        var files: [String: Data] = [:]
        var seen = Set<String>()
        var total = 0
        for _ in 0..<count {
            guard try data.u32(cursor) == 0x02014b50 else { throw ConversationError.invalid("Invalid ZIP directory entry.") }
            let flags = try data.u16(cursor + 8), method = try data.u16(cursor + 10)
            let crc = try data.u32(cursor + 16)
            let compressed = Int(try data.u32(cursor + 20)), size = Int(try data.u32(cursor + 24))
            let nameLength = Int(try data.u16(cursor + 28)), extra = Int(try data.u16(cursor + 30)), comment = Int(try data.u16(cursor + 32))
            let attrs = try data.u32(cursor + 38), offset = Int(try data.u32(cursor + 42))
            let nameData = try data.chunk(cursor + 46, nameLength)
            guard let name = String(data: nameData, encoding: .utf8) else { throw ConversationError.invalid("Archive paths must be UTF-8.") }
            try validatePath(name)
            guard seen.insert(name).inserted else { throw ConversationError.invalid("Duplicate archive entry: \(name)") }
            guard (attrs >> 16) & 0xf000 != 0xa000 else { throw ConversationError.invalid("Symbolic links are not allowed in archives.") }
            guard flags & 1 == 0, method == 0 || method == 8 else { throw ConversationError.invalid("Encrypted or unsupported ZIP compression.") }
            total += size
            guard total <= maxTotalBytes else { throw ConversationError.invalid("Archive expands beyond the 2 GB limit.") }
            cursor += 46 + nameLength + extra + comment
            guard cursor <= end else { throw ConversationError.invalid("Invalid ZIP directory bounds.") }
            if name.hasSuffix("/") { continue }
            guard try data.u32(offset) == 0x04034b50 else { throw ConversationError.invalid("Invalid ZIP local entry.") }
            let localNameLength = Int(try data.u16(offset + 26)), localExtra = Int(try data.u16(offset + 28))
            let localName = try data.chunk(offset + 30, localNameLength)
            guard localName == nameData, try data.u16(offset + 8) == method else { throw ConversationError.invalid("ZIP entry headers disagree.") }
            let payloadOffset = offset + 30 + localNameLength + localExtra
            guard payloadOffset + compressed <= end - directorySize else { throw ConversationError.invalid("ZIP payload extends outside the data area.") }
            let payload = try data.chunk(payloadOffset, compressed)
            let value = method == 8 ? try inflated(payload, size: size) : payload
            guard value.count == size, checksum(value) == crc else { throw ConversationError.invalid("Archive checksum failed for \(name).") }
            files[name] = value
        }
        guard cursor == end else { throw ConversationError.invalid("ZIP entry count is incorrect.") }
        return files
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
    func chunk(_ offset: Int, _ length: Int) throws -> Data {
        guard offset >= 0, length >= 0, offset <= count, length <= count - offset else { throw ConversationError.invalid("Truncated ZIP archive.") }
        return subdata(in: offset..<(offset + length))
    }
    func u16(_ offset: Int) throws -> UInt16 {
        let bytes = try chunk(offset, 2)
        return UInt16(bytes[bytes.startIndex]) | UInt16(bytes[bytes.startIndex + 1]) << 8
    }
    func u32(_ offset: Int) throws -> UInt32 {
        let bytes = try chunk(offset, 4)
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[bytes.startIndex + $1]) << ($1 * 8) }
    }
}
