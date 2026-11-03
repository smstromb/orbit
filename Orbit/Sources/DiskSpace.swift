import Foundation

struct DiskSpace {
    let capacity: UInt64
    let free: UInt64
    let capturedAt: Date
    var used: UInt64 { capacity - free }

    init(capacity: UInt64, free: UInt64, capturedAt: Date = Date()) throws {
        guard capacity > 0, free <= capacity else { throw CocoaError(.fileReadCorruptFile) }
        self.capacity = capacity; self.free = free; self.capturedAt = capturedAt
    }
    static func read(path: String) throws -> DiskSpace {
        let values = try FileManager.default.attributesOfFileSystem(forPath: path)
        guard let total = values[.systemSize] as? NSNumber, let free = values[.systemFreeSize] as? NSNumber else { throw CocoaError(.fileReadUnknown) }
        return try DiskSpace(capacity: total.uint64Value, free: free.uint64Value)
    }

    // Round the capacity and free figures together, then derive displayed used
    // space, so the visible equation is exact even at the chosen GB precision.
    static func displayUnits(_ bytes: UInt64) -> Int64 {
        Int64(bytes / 10_000_000 + (bytes % 10_000_000 >= 5_000_000 ? 1 : 0))
    }
    static func format(units: Int64) -> String { String(format: "%.2f GB", Double(units) / 100) }
    var capacityUnits: Int64 { Self.displayUnits(capacity) }
    var freeUnits: Int64 { Self.displayUnits(free) }
    var usedUnits: Int64 { capacityUnits - freeUnits }
    var capacityLabel: String { Self.format(units: capacityUnits) }
    var freeLabel: String { Self.format(units: freeUnits) }
    var usedLabel: String { Self.format(units: usedUnits) }

    func reconciliation(scanned: UInt64) -> AllocationReconciliation {
        AllocationReconciliation(scannedUnits: Self.displayUnits(scanned), usedUnits: usedUnits)
    }
}

struct AllocationReconciliation {
    let scannedUnits: Int64
    let usedUnits: Int64
    var adjustmentUnits: Int64 { usedUnits - scannedUnits }
    var scannedLabel: String { DiskSpace.format(units: scannedUnits) }
    var adjustmentLabel: String { DiskSpace.format(units: abs(adjustmentUnits)) }
    var operation: String { adjustmentUnits < 0 ? "−" : "+" }
    var reason: String { adjustmentUnits < 0 ? "overlap / estimate adjustment" : "other used space" }
}
