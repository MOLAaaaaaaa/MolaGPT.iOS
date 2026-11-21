import Foundation
import Compression

/// 精简 zip 读取器（只读）：解析中央目录，支持 stored(0) 与 deflate(8)。
/// 用于技能包、charX 角色卡、docx 文本抽取。用系统 Compression 框架解压，不引入第三方依赖
/// （ZIPFoundation 在 Linux 宿主交叉编译时会链接宿主机 libz）。
struct MiniZip {
    struct Entry {
        let path: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
        var isDirectory: Bool { path.hasSuffix("/") }
    }

    enum ZipError: LocalizedError {
        case notZip, unsupported(UInt16), corrupt, tooLarge
        var errorDescription: String? {
            switch self {
            case .notZip: return "不是有效的 zip 文件"
            case .unsupported(let m): return "不支持的压缩方式（\(m)）"
            case .corrupt: return "zip 文件已损坏"
            case .tooLarge: return "zip 内文件过大"
            }
        }
    }

    let data: Data
    let entries: [Entry]

    static func isZip(_ d: Data) -> Bool { d.starts(with: [0x50, 0x4B, 0x03, 0x04]) }

    init(_ data: Data) throws {
        self.data = data
        let bytes = [UInt8](data)
        guard bytes.count >= 22 else { throw ZipError.notZip }
        // 从末尾找 End of Central Directory（0x06054b50）
        var eocd = -1
        var i = bytes.count - 22
        let stop = max(0, bytes.count - 22 - 65_535)
        while i >= stop {
            if bytes[i] == 0x50 && bytes[i + 1] == 0x4B && bytes[i + 2] == 0x05 && bytes[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notZip }
        func u16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        let count = u16(eocd + 10)
        var p = u32(eocd + 16)
        var out: [Entry] = []
        for _ in 0..<count {
            guard p + 46 <= bytes.count, u32(p) == 0x02014b50 else { throw ZipError.corrupt }
            let method = UInt16(u16(p + 10))
            let csize = u32(p + 20), usize = u32(p + 24)
            let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32)
            let local = u32(p + 42)
            guard p + 46 + nameLen <= bytes.count else { throw ZipError.corrupt }
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            out.append(Entry(path: name, method: method, compressedSize: csize, uncompressedSize: usize, localHeaderOffset: local))
            p += 46 + nameLen + extraLen + commentLen
        }
        entries = out
    }

    var files: [Entry] { entries.filter { !$0.isDirectory && !$0.path.hasPrefix("__MACOSX/") && !$0.path.hasSuffix(".DS_Store") } }

    func entry(_ path: String) -> Entry? { entries.first { $0.path == path } }

    func extract(_ e: Entry, limit: Int = 64 * 1024 * 1024) throws -> Data {
        guard e.uncompressedSize <= limit else { throw ZipError.tooLarge }
        let o = e.localHeaderOffset
        guard o + 30 <= data.count else { throw ZipError.corrupt }
        let b = data.startIndex
        func u16(_ x: Int) -> Int { Int(data[b + x]) | Int(data[b + x + 1]) << 8 }
        let nameLen = u16(o + 26), extraLen = u16(o + 28)
        let start = o + 30 + nameLen + extraLen
        guard start + e.compressedSize <= data.count else { throw ZipError.corrupt }
        let payload = data.subdata(in: (b + start)..<(b + start + e.compressedSize))
        switch e.method {
        case 0: return payload
        case 8: return try Self.inflateRaw(payload, expected: e.uncompressedSize)
        default: throw ZipError.unsupported(e.method)
        }
    }

    func text(_ path: String) -> String? {
        guard let e = entry(path), let d = try? extract(e) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// 原始 DEFLATE 解压（Compression 的 ZLIB 算法即 raw deflate）。
    static func inflateRaw(_ input: Data, expected: Int) throws -> Data {
        if input.isEmpty { return Data() }
        var capacity = max(expected, input.count * 4, 1024)
        for _ in 0..<4 {
            var out = Data(count: capacity)
            let n = out.withUnsafeMutableBytes { dst in
                input.withUnsafeBytes { src in
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                              src.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_ZLIB)
                }
            }
            if n > 0 && (n < capacity || expected == n) { out.count = n; return out }
            capacity *= 4
        }
        throw ZipError.corrupt
    }

    /// zlib 流（2 字节头 + deflate + adler32）解压，PNG iTXt 压缩文本用。
    static func inflateZlib(_ input: Data) -> Data? {
        guard input.count > 6 else { return nil }
        return try? inflateRaw(input.subdata(in: (input.startIndex + 2)..<(input.endIndex - 4)), expected: input.count * 6)
    }
}
