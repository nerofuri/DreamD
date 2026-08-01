import Foundation

struct Bitfield {
    private(set) var storage: [UInt8]
    let count: Int

    init(count: Int) {
        self.count = count
        storage = [UInt8](repeating: 0, count: (count + 7) / 8)
    }

    subscript(index: Int) -> Bool {
        get {
            guard index >= 0, index < count else { return false }
            return (storage[index >> 3] >> (7 - UInt8(index & 7))) & 1 == 1
        }
        set {
            guard index >= 0, index < count else { return }
            let mask: UInt8 = 1 << (7 - UInt8(index & 7))
            if newValue {
                storage[index >> 3] |= mask
            } else {
                storage[index >> 3] &= ~mask
            }
        }
    }

    var setCount: Int {
        var total = 0
        for i in 0..<count where self[i] { total += 1 }
        return total
    }

    var data: Data { Data(storage) }
}
