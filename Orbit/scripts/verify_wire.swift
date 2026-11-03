import Foundation

@main struct VerifyWire {
    static func main() {
        do { try verify() }
        catch { fputs("Invalid scan stream: \(error)\n", stderr); exit(1) }
    }
    static func verify() throws {
        let start = Date()
        let stream = try FileHandle(forReadingFrom: URL(fileURLWithPath: CommandLine.arguments[1]))
        let actual = try readScanStream(stream) { _ in }
        let elapsed = Date().timeIntervalSince(start)
        if CommandLine.arguments.count > 2 {
            let referenceStream = try FileHandle(forReadingFrom: URL(fileURLWithPath: CommandLine.arguments[2]))
            let expected = try readScanStream(referenceStream) { _ in }
            precondition(actual.nodes.count == expected.nodes.count, "Node count differs")
            func paths(_ result: ScanResult) -> [String: DiskNode] {
                var names = [String](repeating: "", count: result.nodes.count)
                var output: [String: DiskNode] = [:]
                for (id, node) in result.nodes.enumerated() {
                    names[id] = (node.parent.map { names[$0] } ?? "") + "/" + node.name
                    output[names[id]] = node
                }
                return output
            }
            let reference = paths(expected)
            for (path, node) in paths(actual) {
                guard let other = reference[path] else { preconditionFailure("Missing path: \(path)") }
                precondition(node.logical == other.logical && node.kind == other.kind && node.files == other.files && node.folders == other.folders && node.issues == other.issues, "Metadata differs for \(path)")
                if node.isFolder { precondition(node.allocated == other.allocated, "Allocated total differs for \(path)") }
            }
        }
        let root = actual.nodes[0]
        print("{\"nodes\":\(actual.nodes.count),\"files\":\(root.files),\"logical\":\(root.logical),\"decode_seconds\":\(elapsed)}")
    }
}
