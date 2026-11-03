import Foundation

struct DiskNode: Decodable {
    let name: String
    let parent: Int?
    let logical: UInt64
    let allocated: UInt64
    let kind: String
    var files: UInt64
    var folders: UInt64
    let issues: UInt64
    var children: [Int] = []
    var branch: Int = 0
    var level: Int = 0
    enum CodingKeys: String, CodingKey { case name, parent, logical, allocated, kind, files, folders, issues }
    var isFolder: Bool { kind == "folder" }
    func size(_ allocatedMode: Bool) -> UInt64 { allocatedMode ? allocated : logical }
}
struct ScanResult: Decodable { let root: String; let elapsed: Double; let workers: Int?; let engine: String?; var nodes: [DiskNode] }
struct ScanProgress: Decodable { let files: UInt64; let bytes: UInt64; let allocated: UInt64?; let workers: Int?; let waiting: Bool?; let path: String }

private struct BinaryHeader: Decodable {
    let version: Int
    let root: String
    let elapsed: Double
    let workers: Int
    let engine: String
    let nodeCount: Int
}
private enum WireError: Error { case invalidHeader, invalidRecord, truncatedStream }

// Decode incrementally. The app never holds a second copy of the complete scan
// as JSON/Data, and newlines in real filenames cannot affect binary framing.
func readScanStream(_ handle: FileHandle, progress: (ScanProgress) -> Void) throws -> ScanResult {
    var buffer = Data()
    var header: BinaryHeader?
    var nodes: [DiskNode] = []
    while true {
        let data = handle.availableData
        if data.isEmpty { throw WireError.truncatedStream }
        let previousCount = buffer.count
        buffer.append(data)
        if header == nil {
            var searchStart = previousCount
            while let newline = buffer[searchStart...].firstIndex(of: 10) {
                let line = buffer.prefix(upTo: newline)
                if line.starts(with: Data("{\"type\":\"progress\"".utf8)) {
                    progress(try JSONDecoder().decode(ScanProgress.self, from: line))
                } else if line.starts(with: Data("{\"type\":\"binary\"".utf8)) {
                    let decoded = try JSONDecoder().decode(BinaryHeader.self, from: line)
                    guard decoded.version == 1, decoded.nodeCount > 0, decoded.nodeCount < Int(UInt32.max) else { throw WireError.invalidHeader }
                    header = decoded
                    nodes.reserveCapacity(decoded.nodeCount)
                } else {
                    // The JSON mode remains useful for comparing against the original scanner.
                    return try JSONDecoder().decode(ScanResult.self, from: line)
                }
                buffer.removeSubrange(...newline)
                searchStart = 0
                if header != nil { break }
            }
        }
        guard let header else { continue }
        var consumed = 0
        try buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            while nodes.count < header.nodeCount && raw.count - consumed >= 31 {
                let base = consumed
                let parentValue = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: base, as: UInt32.self))
                let nameLength = Int(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: base + 4, as: UInt16.self)))
                guard raw.count - base >= 31 + nameLength else { break }
                let kindValue = raw[base + 6]
                let kind: String
                switch kindValue & 0x7f {
                case 0: kind = "folder"
                case 1: kind = "file"
                case 2: kind = "link"
                case 3: kind = "boundary"
                case 4: kind = "special"
                default: throw WireError.invalidRecord
                }
                let parent = parentValue == UInt32.max ? nil : Int(parentValue)
                guard (nodes.isEmpty && parent == nil) || (parent != nil && parent! < nodes.count) else { throw WireError.invalidRecord }
                guard let name = String(bytes: raw[(base + 31)..<(base + 31 + nameLength)], encoding: .utf8), !name.isEmpty else { throw WireError.invalidRecord }
                let logical = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: base + 7, as: UInt64.self))
                let allocated = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: base + 15, as: UInt64.self))
                let issues = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: base + 23, as: UInt64.self))
                nodes.append(DiskNode(name: name, parent: parent, logical: logical, allocated: allocated, kind: kind,
                    files: kind == "file" || kind == "link" ? 1 : 0,
                    folders: kind == "folder" && parent != nil || kindValue & 0x80 != 0 ? 1 : 0, issues: issues))
                consumed += 31 + nameLength
            }
        }
        buffer.removeSubrange(0..<consumed)
        if nodes.count == header.nodeCount {
            guard buffer.isEmpty else { throw WireError.invalidRecord }
            for i in nodes.indices.dropFirst().reversed() {
                let parent = nodes[i].parent!
                nodes[parent].files += nodes[i].files
                nodes[parent].folders += nodes[i].folders
            }
            return ScanResult(root: header.root, elapsed: header.elapsed, workers: header.workers, engine: header.engine, nodes: nodes)
        }
    }
}
