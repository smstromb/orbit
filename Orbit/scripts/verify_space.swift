import Foundation

@main struct VerifySpace {
    static func main() throws {
        let example = try DiskSpace(capacity: 1_000_000_000_000, free: 125_000_000_000)
        precondition(example.used == 875_000_000_000)
        precondition(example.capacityLabel == "1000.00 GB")
        precondition(example.freeLabel == "125.00 GB")
        precondition(example.usedLabel == "875.00 GB")
        precondition(example.usedUnits + example.freeUnits == example.capacityUnits)
        let overlap = example.reconciliation(scanned: 950_000_000_000)
        precondition(overlap.scannedLabel == "950.00 GB")
        precondition(overlap.operation == "−" && overlap.adjustmentLabel == "75.00 GB")
        precondition(overlap.scannedUnits + overlap.adjustmentUnits + example.freeUnits == example.capacityUnits)
        let unmeasured = example.reconciliation(scanned: 800_000_000_000)
        precondition(unmeasured.operation == "+" && unmeasured.adjustmentLabel == "75.00 GB")
        precondition(unmeasured.scannedUnits + unmeasured.adjustmentUnits + example.freeUnits == example.capacityUnits)
        // A sparse file's logical capacity must never enter physical disk totals.
        let sparse = example.reconciliation(scanned: 64_000_000_000)
        precondition(sparse.scannedLabel == "64.00 GB")
        let rounding = try DiskSpace(capacity: 1_004_000_000, free: 335_000_000)
        precondition(rounding.usedLabel == "0.66 GB")
        precondition(rounding.usedUnits + rounding.freeUnits == rounding.capacityUnits)
        do { _ = try DiskSpace(capacity: 1, free: 2); preconditionFailure("Invalid volume accepted") } catch {}
        let actual = try DiskSpace.read(path: FileManager.default.homeDirectoryForCurrentUser.path)
        precondition(actual.used + actual.free == actual.capacity)
        precondition(actual.usedUnits + actual.freeUnits == actual.capacityUnits)
        print("PASS: exact volume totals, visible rounding, overlap and unmeasured adjustments, sparse allocation, invalid counters, and live macOS counters")
        print("\(actual.usedLabel) used + \(actual.freeLabel) free = \(actual.capacityLabel) capacity")
    }
}
