import CryptoKit
import Security

/// Self-contained SRP-6a client implementing Apple's authentication variant.
///
/// Matches the constants and formulas used by StosSign/AltStore:
/// - Group: RFC 5054 2048-bit prime (N), generator g = 2
/// - k = SHA256(N | g_padded)   (pad g to size of N)
/// - x = SHA256(salt | SHA256(0x3A || PBKDF2(SHA256(password), salt, iters)))
/// - u = SHA256(A | B)
/// - S = (B - k·gˣ)^(a + u·x) mod N
/// - K = SHA256(S)
/// - M1 = SHA256( SHA256(N)⊕SHA256(g) | SHA256(user) | salt | A | B | SHA256(K) )
/// - M2 = SHA256( A | M1 | SHA256(K) )
enum SRP6a {
    static let sizeN = 256

    // RFC 5054 2048-bit safe prime.
    static let N: BigInt = BigInt(hex:
        "AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC319294" +
        "3DB56050A37329CBB4A099ED8193E0757767A13DD52312AB4B03310D" +
        "CD7F48A9DA04FD50E8083969EDB767B0CF6095179A163AB3661A05FB" +
        "D5FAAAE82918A9962F0B93B855F97993EC975EEAA80D740ADBF4FF74" +
        "7359D041D5C33EA71D281E446B14773BCA97B43A23FB801676BD207A" +
        "436C6481F1D2B9078717461A5B9D32E688F87748544523B524B0D57D" +
        "5EA77A2775D2ECFA032CFBDBF52FB3786160279004E57AE6AF874E73" +
        "03CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8E9DBFBB6" +
        "94B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F" +
        "9E4AFF73")!

    static let g: BigInt = BigInt(2)

    static let k: BigInt = {
        let h = sha256(N.bytes + pad(g.bytes, to: sizeN))
        return BigInt(bytes: h)
    }()

    // MARK: - Key generation

    /// Generate a fresh client ephemeral key pair. Returns (public key A, private a).
    static func generateKeys() -> (publicKey: [UInt8], privateKey: BigInt) {
        let a = BigInt(bytes: randomBytes(32))
        let A = g.modPow(a, modulus: N)
        return (A.bytes(paddedTo: sizeN), a)
    }

    // MARK: - Shared secret

    /// Compute the SRP shared secret S and the session key K.
    /// `x` is the final SRP x value (already derived by the caller).
    static func calculateSharedSecret(private a: BigInt, x: BigInt, salt: [UInt8], A: [UInt8], B: [UInt8]) -> (sharedSecret: BigInt, sessionKey: [UInt8]) {
        let Bb = BigInt(bytes: B)
        let u = BigInt(bytes: sha256(pad(A, to: sizeN) + pad(B, to: sizeN)))
        let gx = g.modPow(x, modulus: N)
        let kgx = (k * gx).mod(N)
        let base = (Bb - kgx).mod(N)
        let exponent = a + u * x
        let S = base.modPow(exponent, modulus: N)
        let K = sha256(S.bytes(paddedTo: sizeN))
        return (S, K)
    }

    // MARK: - Proofs

    static func clientProof(username: String, salt: [UInt8], A: [UInt8], B: [UInt8], K: [UInt8]) -> [UInt8] {
        let hn = sha256(N.bytes)
        let hg = sha256(pad(g.bytes, to: sizeN))
        let nxorG = xor(hn, hg)
        let hashUser = sha256(Array(username.utf8))
        let hk = sha256(K)
        let input = nxorG + hashUser + salt + pad(A, to: sizeN) + pad(B, to: sizeN) + hk
        return sha256(input)
    }

    static func serverProof(A: [UInt8], M1: [UInt8], K: [UInt8]) -> [UInt8] {
        let hk = sha256(K)
        return sha256(pad(A, to: sizeN) + M1 + hk)
    }

    // MARK: - Helpers

    static func sha256(_ data: [UInt8]) -> [UInt8] {
        Array(CryptoKit.SHA256.hash(data: Data(data)))
    }

    static func pad(_ data: [UInt8], to width: Int) -> [UInt8] {
        if data.count >= width { return Array(data.suffix(width)) }
        return Array(repeating: 0, count: width - data.count) + data
    }

    private static func xor(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        precondition(a.count == b.count, "xor length mismatch")
        return zip(a, b).map { $0 ^ $1 }
    }

    private static func randomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess { bytes = (0..<count).map { _ in UInt8.random(in: 0...255) } }
        return bytes
    }
}
