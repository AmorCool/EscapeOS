import Foundation

/// Minimal arbitrary-precision signed integer.
///
/// Self-contained (no external dependencies) and used only by the Apple SRP-6a
/// authentication engine. Magnitude is stored as big-endian base-2^32 limbs.
/// The implementation favors correctness over speed: multiplication is schoolbook,
/// division uses Knuth's Algorithm D. A `selfTest()` is provided so the math can
/// be validated on-device before trusting a real login.
struct BigInt: Equatable, Comparable, CustomStringConvertible {
    private var neg: Bool
    private var limbs: [UInt32]   // big-endian, no leading zero limbs (zero == [0])

    // MARK: - Constants

    private static let base = UInt64(1) << 32
    static let zero = BigInt(0)

    // MARK: - Initializers

    init(_ value: Int) {
        if value == 0 {
            self.neg = false
            self.limbs = [0]
        } else {
            self.neg = value < 0
            self.limbs = [UInt32(abs(value))]
        }
    }

    init(_ value: UInt32) {
        self.neg = false
        self.limbs = [value]
    }

    /// Parse a big-endian hex string (optionally 0x-prefixed).
    init?(hex: String) {
        let s = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard s.allSatisfy({ $0.isHexDigit }) else { return nil }
        var bytes = [UInt8]()
        var i = s.startIndex
        if s.count % 2 == 1 {
            bytes.append(UInt8(String(s[i...s.index(i, offsetBy: 0)]), radix: 16) ?? 0)
            i = s.index(after: i)
        }
        while i < s.endIndex {
            let next = s.index(i, offsetBy: 2)
            guard let b = UInt8(String(s[i..<next]), radix: 16) else { return nil }
            bytes.append(b)
            i = next
        }
        self.init(bytes: bytes)
    }

    /// Parse big-endian bytes.
    init(bytes: [UInt8]) {
        var limbs = [UInt32]()
        limbs.reserveCapacity((bytes.count + 3) / 4)
        var i = bytes.count % 4
        if i == 0 { i = 4 }
        var chunk: UInt32 = 0
        var count = 0
        for b in bytes {
            chunk = (chunk << 8) | UInt32(b)
            count += 1
            if count == i || count == 4 {
                limbs.append(chunk)
                chunk = 0
                count = 0
                if i != 4 && limbs.count == 1 { i = 4 }
            }
        }
        if limbs.isEmpty { limbs = [0] }
        while limbs.count > 1 && limbs[0] == 0 { limbs.removeFirst() }
        self.neg = false
        self.limbs = limbs
    }

    // MARK: - Conversion

    var bytes: [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(limbs.count * 4)
        for limb in limbs {
            out.append(UInt8((limb >> 24) & 0xFF))
            out.append(UInt8((limb >> 16) & 0xFF))
            out.append(UInt8((limb >> 8) & 0xFF))
            out.append(UInt8(limb & 0xFF))
        }
        while out.count > 1 && out[0] == 0 { out.removeFirst() }
        return out.isEmpty ? [0] : out
    }

    /// Fixed-width big-endian bytes, left-padded with zeros.
    func bytes(paddedTo width: Int) -> [UInt8] {
        let b = self.bytes
        if b.count >= width { return Array(b.suffix(width)) }
        return Array(repeating: 0, count: width - b.count) + b
    }

    var description: String { "\(neg ? "-" : "")\(limbs.map { String($0, radix: 16) }.joined())" }

    // MARK: - Helpers

    private var isZero: Bool { limbs.count == 1 && limbs[0] == 0 }

    private func magnitudeCompare(_ other: BigInt) -> Int {
        if limbs.count != other.limbs.count {
            return limbs.count < other.limbs.count ? -1 : 1
        }
        for (a, b) in zip(limbs, other.limbs) {
            if a != b { return a < b ? -1 : 1 }
        }
        return 0
    }

    static func < (lhs: BigInt, rhs: BigInt) -> Bool {
        if lhs.neg != rhs.neg { return lhs.neg }
        let c = lhs.magnitudeCompare(rhs)
        return lhs.neg ? c > 0 : c < 0
    }

    static func == (lhs: BigInt, rhs: BigInt) -> Bool {
        lhs.neg == rhs.neg && lhs.limbs == rhs.limbs
    }

    // MARK: - Addition / subtraction (signed)

    static func + (lhs: BigInt, rhs: BigInt) -> BigInt {
        if lhs.neg == rhs.neg {
            return BigInt(neg: lhs.neg, limbs: addMag(lhs.limbs, rhs.limbs))
        }
        // opposite signs -> subtract
        let c = lhs.magnitudeCompare(rhs)
        if c == 0 { return .zero }
        if c > 0 {
            return BigInt(neg: lhs.neg, limbs: subMag(lhs.limbs, rhs.limbs))
        }
        return BigInt(neg: rhs.neg, limbs: subMag(rhs.limbs, lhs.limbs))
    }

    static func - (lhs: BigInt, rhs: BigInt) -> BigInt {
        BigInt(neg: !rhs.neg, limbs: rhs.limbs) + lhs
    }

    private static func addMag(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        var result = [UInt32]()
        result.reserveCapacity(max(a.count, b.count) + 1)
        var carry: UInt64 = 0
        var i = a.count - 1
        var j = b.count - 1
        while i >= 0 || j >= 0 || carry > 0 {
            var sum: UInt64 = carry
            if i >= 0 { sum += UInt64(a[i]); i -= 1 }
            if j >= 0 { sum += UInt64(b[j]); j -= 1 }
            result.append(UInt32(sum & 0xFFFFFFFF))
            carry = sum >> 32
        }
        return result.reversed()
    }

    private static func subMag(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        // assumes |a| >= |b|
        var result = [UInt32]()
        result.reserveCapacity(a.count)
        var borrow: Int64 = 0
        var i = a.count - 1
        var j = b.count - 1
        while i >= 0 {
            let bb: Int64 = j >= 0 ? Int64(b[j]) : 0
            var diff = Int64(a[i]) - bb - borrow
            if diff < 0 { diff += Int64(base); borrow = 1 } else { borrow = 0 }
            result.append(UInt32(diff & 0xFFFFFFFF))
            i -= 1; j -= 1
        }
        while result.count > 1 && result[result.count - 1] == 0 { result.removeLast() }
        return result.reversed()
    }

    // MARK: - Multiplication

    static func * (lhs: BigInt, rhs: BigInt) -> BigInt {
        if lhs.isZero || rhs.isZero { return .zero }
        let a = lhs.limbs
        let b = rhs.limbs
        var out = [UInt64](repeating: 0, count: a.count + b.count)
        for i in (0..<a.count).reversed() {
            var carry: UInt64 = 0
            for j in (0..<b.count).reversed() {
                let prod = UInt64(a[i]) * UInt64(b[j]) + out[i + j + 1] + carry
                out[i + j + 1] = prod & 0xFFFFFFFF
                carry = prod >> 32
            }
            out[i] += carry
        }
        var limbs = out.map { UInt32($0 & 0xFFFFFFFF) }
        while limbs.count > 1 && limbs[0] == 0 { limbs.removeFirst() }
        return BigInt(neg: lhs.neg != rhs.neg, limbs: limbs)
    }

    // MARK: - Division / Mod

    /// `self mod m`, always returning a non-negative result.
    func mod(_ m: BigInt) -> BigInt {
        precondition(!m.isZero, "mod by zero")
        let (_, r) = divided(by: m)
        // r has same sign as self in our divMod; normalize to positive
        if r.neg { return r + m }
        return r
    }

    func divided(by other: BigInt) -> (quotient: BigInt, remainder: BigInt) {
        precondition(!other.isZero, "div by zero")
        let a = self.limbs
        let b = other.limbs
        if magnitudeCompare(other) < 0 {
            return (.zero, self)
        }
        let (q, r) = BigInt.divModMag(a, b)
        let qNeg = (neg != other.neg) && !(q.count == 1 && q[0] == 0)
        let rNeg = neg
        return (
            BigInt(neg: qNeg, limbs: q),
            BigInt(neg: rNeg, limbs: r)
        )
    }

    // Knuth Algorithm D on positive big-endian magnitude arrays.
    private static func divModMag(_ uIn: [UInt32], _ vIn: [UInt32]) -> ([UInt32], [UInt32]) {
        var u = uIn; var v = vIn
        while u.count > 1 && u[0] == 0 { u.removeFirst() }
        while v.count > 1 && v[0] == 0 { v.removeFirst() }
        if u.count < v.count { return ([0], u) }

        let n = v.count
        let m = u.count - n
        // normalize by shifting left so v[0] has its top bit set
        let shift = v[0].leadingZeroBitCount
        u = shiftLeftBits(u, shift)
        v = shiftLeftBits(v, shift)
        while u.count < m + n + 1 { u.insert(0, at: 0) }

        var q = [UInt32](repeating: 0, count: m + 1)
        let vnHigh = UInt64(v[n - 1])
        let vnNext = n > 1 ? UInt64(v[n - 2]) : 0

        for j in (0...m).reversed() {
            let num = (UInt64(u[j + n]) << 32) | UInt64(u[j + n - 1])
            var qhat = num / vnHigh
            var rhat = num % vnHigh
            if qhat >= base {
                qhat = base - 1
                rhat = num - qhat * vnHigh
            }
            while qhat >= base || vnNext * qhat > ((rhat << 32) | UInt64(u[j + n - 2])) {
                qhat -= 1
                rhat += vnHigh
                if rhat >= base { break }
            }

            // multiply and subtract
            var borrow: Int64 = 0
            var carry: UInt64 = 0
            for i in 0..<n {
                let p = qhat * UInt64(v[i]) + carry
                carry = p >> 32
                let sub = Int64(u[j + i]) - Int64(p & 0xFFFFFFFF) - borrow
                u[j + i] = UInt32(bitPattern: Int32(truncatingIfNeeded: sub))
                borrow = sub < 0 ? 1 : 0
            }
            let subTop = Int64(u[j + n]) - Int64(carry) - borrow
            u[j + n] = UInt32(bitPattern: Int32(truncatingIfNeeded: subTop))

            if subTop < 0 {
                qhat -= 1
                var c: UInt64 = 0
                for i in 0..<n {
                    let s = UInt64(u[j + i]) + UInt64(v[i]) + c
                    u[j + i] = UInt32(s & 0xFFFFFFFF)
                    c = s >> 32
                }
                u[j + n] = UInt32((UInt64(u[j + n]) + c) & 0xFFFFFFFF)
            }
            q[j] = UInt32(qhat)
        }

        var rem = Array(u[0..<n])
        rem = shiftRightBits(rem, shift)
        while rem.count > 1 && rem[0] == 0 { rem.removeFirst() }
        while q.count > 1 && q[0] == 0 { q.removeFirst() }
        return (q, rem)
    }

    private static func shiftLeftBits(_ a: [UInt32], _ bits: Int) -> [UInt32] {
        guard bits > 0 else { return a }
        var out = a
        var carry: UInt32 = 0
        for i in (0..<out.count).reversed() {
            let cur = out[i]
            out[i] = (cur << UInt32(bits)) | carry
            carry = cur >> UInt32(32 - bits)
        }
        if carry != 0 { out = [carry] + out }
        return out
    }

    private static func shiftRightBits(_ a: [UInt32], _ bits: Int) -> [UInt32] {
        guard bits > 0 else { return a }
        var out = a
        var carry: UInt32 = 0
        for i in 0..<out.count {
            let cur = out[i]
            out[i] = (cur >> UInt32(bits)) | carry
            carry = cur << UInt32(32 - bits)
        }
        while out.count > 1 && out[0] == 0 { out.removeFirst() }
        return out
    }

    // MARK: - Modular exponentiation

    func modPow(_ exponent: BigInt, modulus: BigInt) -> BigInt {
        precondition(!modulus.isZero, "mod by zero")
        let m = modulus
        var result = BigInt(1)
        var base = self.mod(m)
        var e = exponent
        if e.neg { return .zero } // not needed for SRP (exponents positive)
        while !e.isZero {
            if (e.limbs.last ?? 0) & 1 == 1 {
                result = (result * base).mod(m)
            }
            base = (base * base).mod(m)
            // e = e >> 1
            e = BigInt(shiftRight: e)
        }
        return result
    }

    private init(shiftRight e: BigInt) {
        var limbs = e.limbs
        var carry: UInt32 = 0
        for i in 0..<limbs.count {
            let cur = limbs[i]
            limbs[i] = (cur >> 1) | UInt32(carry << 31)
            carry = cur & 1
        }
        while limbs.count > 1 && limbs[0] == 0 { limbs.removeFirst() }
        self.neg = false
        self.limbs = limbs
    }

    private init(neg: Bool, limbs: [UInt32]) {
        self.neg = neg
        self.limbs = limbs.isEmpty ? [0] : limbs
    }

    // MARK: - Self tests (run on-device to validate the math)

    static func selfTest() -> Bool {
        // 7^13 mod 100 == 7
        let a = BigInt(7).modPow(BigInt(13), modulus: BigInt(100))
        guard a == BigInt(7) else { return false }

        // (123456789 * 987654321) % 1000000007
        let prod = BigInt(123456789) * BigInt(987654321)
        let rem = prod.mod(BigInt(1000000007))
        // 123456789*987654321 = 121932631112635269 ; mod 1e9+7
        guard rem == BigInt(121932631112635269 % 1000000007) else { return false }

        // associativity sanity: a^b^c
        let x = BigInt(12345)
        let n = BigInt(hext: "AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC3192943DB56050A37329CBB4A099ED8193E0757767A13DD52312AB4B03310DCD7F48A9DA04FD50E8083969EDB767B0CF6095179A163AB3661A05FBD5FAAAE82918A9962F0B93B855F97993EC975EEAA80D740ADBF4FF747359D041D5C33EA71D281E446B14773BCA97B43A23FB801676BD207A436C6481F1D2B9078717461A5B9D32E688F87748544523B524B0D57D5EA77A2775D2ECFA032CFBDBF52FB3786160279004E57AE6AF874E7303CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8E9DBFBB694B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F9E4AFF73")!
        let e1 = x.modPow(BigInt(3), modulus: n)
        let e2 = (x.modPow(BigInt(2), modulus: n)).modPow(BigInt(3), modulus: n)
        guard e1 == e2 else { return false }

        return true
    }

    // convenience for tests
    private init?(hext: String) { self.init(hex: hext) }
}
