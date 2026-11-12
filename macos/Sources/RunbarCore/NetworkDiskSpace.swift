import Foundation

public typealias NetworkDiskSpaceProvider = @Sendable (URL) -> Int64?

public enum NetworkDiskSpace {
    public static func available(at directory: URL) -> Int64? {
        var location = directory
        location.removeAllCachedResourceValues()
        guard let values = try? location.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
              let bytes = values.volumeAvailableCapacity, bytes >= 0 else { return nil }
        return Int64(bytes)
    }
    static func requireAvailable(at directory: URL, reserve: Int64, additional: Int64,
                                 provider: NetworkDiskSpaceProvider = { available(at: $0) }, operation: String) throws {
        // Unknown capacity is not a fabricated "disk full" condition. SQLite
        // and the file writer still report actual allocation / permission errors.
        guard let available = provider(directory), available >= 0 else { return }
        let sum = max(0, reserve).addingReportingOverflow(max(0, additional))
        let required = sum.overflow ? Int64.max : sum.partialValue
        guard available < required else { return }
        throw NetworkStorageError(code: nil, extendedCode: nil, operation: operation,
            detail: "磁盘剩余 \(ByteCountFormatter.string(fromByteCount: available, countStyle: .binary))；本次写入与系统预留需要 \(ByteCountFormatter.string(fromByteCount: required, countStyle: .binary))。释放空间后点击「继续」，已缓存记录保留。",
            spaceProtection: true, availableDiskBytes: available, requiredDiskBytes: required)
    }
}
