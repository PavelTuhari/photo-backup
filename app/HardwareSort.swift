import Foundation

// Integer columns for the NEON radix sort. Name order is a Finder rank
// computed once; later clicks only permute these integers.
enum HardwareColumn {
    case name
    case created
    case year
    case kind
    case size
    case pixels

    var headerKey: String {
        switch self {
        case .name: return "name"
        case .created: return "created"
        case .year: return "year"
        case .kind: return "kind"
        case .size: return "size"
        case .pixels: return "pixels"
        }
    }

    init?(headerKey: String) {
        switch headerKey {
        case "name": self = .name
        case "created": self = .created
        case "year": self = .year
        case "kind": self = .kind
        case "size": self = .size
        case "pixels": self = .pixels
        default: return nil
        }
    }
}

struct SortKeys: Sendable {
    var created: [UInt64] = []
    var size: [UInt64] = []
    var pixels: [UInt64] = []
    var year: [UInt64] = []
    var kind: [UInt64] = []
    var nameRank: [UInt64] = []

    var count: Int { created.count }

    static func make(files: [FileRecord]) -> SortKeys {
        let count = files.count
        var keys = SortKeys()
        keys.created = [UInt64](repeating: 0, count: count)
        keys.size = [UInt64](repeating: 0, count: count)
        keys.pixels = [UInt64](repeating: 0, count: count)
        keys.year = [UInt64](repeating: 0, count: count)
        keys.kind = [UInt64](repeating: 0, count: count)
        keys.nameRank = [UInt64](repeating: 0, count: count)

        var order = Array(0..<count)
        order.sort { lhs, rhs in
            let compared = files[lhs].name.localizedStandardCompare(files[rhs].name)
            if compared == .orderedSame { return lhs < rhs }
            return compared == .orderedAscending
        }
        for (rank, index) in order.enumerated() {
            keys.nameRank[index] = UInt64(rank)
        }

        for (index, file) in files.enumerated() {
            keys.created[index] = dateKey(file.created)
            keys.size[index] = UInt64(bitPattern: file.size)
            keys.pixels[index] = UInt64(max(file.pixelCount, 0))
            keys.year[index] = UInt64(UInt(file.year) ?? 0)
            // "Видео" sorts before "Фото", matching the Russian labels.
            keys.kind[index] = file.isVideo ? 0 : 1
        }
        return keys
    }

    func permute(_ indices: inout [UInt32], column: HardwareColumn, descending: Bool) {
        let count = indices.count
        guard count >= 2 else { return }
        let keys = values(for: column)
        keys.withUnsafeBufferPointer { keyBuf in
            indices.withUnsafeMutableBufferPointer { indexBuf in
                guard let keyPtr = keyBuf.baseAddress, let indexPtr = indexBuf.baseAddress else { return }
                m_series_radix_u64(keyPtr, indexPtr, UInt32(count), Int32(descending ? 1 : 0))
            }
        }
    }

    private func values(for column: HardwareColumn) -> [UInt64] {
        switch column {
        case .name: return nameRank
        case .created: return created
        case .year: return year
        case .kind: return kind
        case .size: return size
        case .pixels: return pixels
        }
    }
}

func dateKey(_ created: TimeInterval) -> UInt64 {
    let millis = Int64((created * 1000).rounded())
    // Flip the sign bit so negative capture dates sort before the epoch.
    return UInt64(bitPattern: millis) ^ (1 << 63)
}
