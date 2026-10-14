import Foundation

/// WinZip AES extra field (0x9901).
struct ZipAESInfo {
    let keyBits: Int
    let compression: Int

    var saltLength: Int { keyBits / 16 }
    var keyLength: Int { keyBits / 8 }
}

/// Traditional PKWARE ZipCrypto and WinZip AES (128/192/256) for password zips.
enum ZipPassword {
    static func decryptZipCrypto(
        ciphertext: Data,
        password: String,
        crc32: UInt32,
        dosTime: UInt16,
        usesDataDescriptor: Bool
    ) throws -> Data {
        var lastError: Error = ZipReaderError.wrongPassword
        for bytes in passwordEncodings(password) {
            do {
                return try decryptZipCrypto(
                    ciphertext: ciphertext,
                    passwordBytes: bytes,
                    crc32: crc32,
                    dosTime: dosTime,
                    usesDataDescriptor: usesDataDescriptor
                )
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    static func decryptAES(ciphertext: Data, password: String, aes: ZipAESInfo) throws -> Data {
        var lastError: Error = ZipReaderError.wrongPassword
        for bytes in passwordEncodings(password) {
            do {
                return try decryptAES(ciphertext: ciphertext, passwordBytes: bytes, aes: aes)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func passwordEncodings(_ password: String) -> [[UInt8]] {
        var list: [[UInt8]] = [Array(password.utf8)]
        let latin = password.unicodeScalars.compactMap { $0.value < 256 ? UInt8($0.value) : nil }
        if latin != list[0] {
            list.append(latin)
        }
        return list.filter { !$0.isEmpty }
    }

    private static func decryptZipCrypto(
        ciphertext: Data,
        passwordBytes: [UInt8],
        crc32: UInt32,
        dosTime: UInt16,
        usesDataDescriptor: Bool
    ) throws -> Data {
        guard ciphertext.count >= 12 else {
            throw ZipReaderError.invalidArchive("Encrypted entry too small")
        }
        var keys = ZipCryptoKeys(password: passwordBytes)
        var plain = Data()
        plain.reserveCapacity(ciphertext.count)
        for byte in ciphertext {
            let p = byte ^ keys.nextDecryptByte()
            keys.update(p)
            plain.append(p)
        }
        let header = plain.prefix(12)
        let check = usesDataDescriptor ? UInt8((dosTime >> 8) & 0xff) : UInt8((crc32 >> 24) & 0xff)
        guard header.last == check else {
            throw ZipReaderError.wrongPassword
        }
        return Data(plain.dropFirst(12))
    }

    private static func decryptAES(ciphertext: Data, passwordBytes: [UInt8], aes: ZipAESInfo) throws -> Data {
        let saltLen = aes.saltLength
        let overhead = saltLen + 2 + 10
        guard ciphertext.count >= overhead else {
            throw ZipReaderError.invalidArchive("AES entry too small")
        }
        let salt = [UInt8](ciphertext.subdata(in: 0..<saltLen))
        let verify = [UInt8](ciphertext.subdata(in: saltLen..<(saltLen + 2)))
        let macStart = ciphertext.count - 10
        let encrypted = ciphertext.subdata(in: (saltLen + 2)..<macStart)
        let givenMac = [UInt8](ciphertext.subdata(in: macStart..<ciphertext.count))

        let derivedLen = aes.keyLength * 2 + 2
        var derived = [UInt8](repeating: 0, count: derivedLen)
        let status = passwordBytes.withUnsafeBufferPointer { pwd in
            salt.withUnsafeBufferPointer { saltPtr in
                zip_pbkdf2_sha1(
                    pwd.baseAddress, pwd.count,
                    saltPtr.baseAddress, salt.count,
                    1000,
                    &derived,
                    derivedLen
                )
            }
        }
        guard status == 0 else {
            throw ZipReaderError.invalidArchive("Key derivation failed")
        }

        let encKey = Array(derived[0..<aes.keyLength])
        let macKey = Array(derived[aes.keyLength..<(aes.keyLength * 2)])
        let pwdCheck = Array(derived[(aes.keyLength * 2)...])
        guard pwdCheck == verify else {
            throw ZipReaderError.wrongPassword
        }

        var computedMac = [UInt8](repeating: 0, count: 20)
        macKey.withUnsafeBufferPointer { keyPtr in
            encrypted.withUnsafeBytes { dataPtr in
                zip_hmac_sha1(
                    keyPtr.baseAddress, macKey.count,
                    dataPtr.bindMemory(to: UInt8.self).baseAddress, encrypted.count,
                    &computedMac
                )
            }
        }
        guard Array(computedMac.prefix(10)) == givenMac else {
            throw ZipReaderError.wrongPassword
        }

        return try aesCtrDecrypt(key: encKey, ciphertext: encrypted)
    }

    private static func aesCtrDecrypt(key: [UInt8], ciphertext: Data) throws -> Data {
        if ciphertext.isEmpty { return Data() }
        var output = Data()
        output.reserveCapacity(ciphertext.count)
        var counter: UInt64 = 1
        let bytes = [UInt8](ciphertext)
        var offset = 0
        while offset < bytes.count {
            let block = try aesECBEncrypt(key: key, counter: counter)
            let n = min(16, bytes.count - offset)
            for i in 0..<n {
                output.append(bytes[offset + i] ^ block[i])
            }
            offset += n
            counter += 1
        }
        return output
    }

    private static func aesECBEncrypt(key: [UInt8], counter: UInt64) throws -> [UInt8] {
        var nonce = [UInt8](repeating: 0, count: 16)
        var value = counter
        for i in 0..<8 {
            nonce[i] = UInt8(value & 0xff)
            value >>= 8
        }
        var out = [UInt8](repeating: 0, count: 16)
        let rc = key.withUnsafeBufferPointer { keyPtr in
            nonce.withUnsafeBufferPointer { inPtr in
                zip_aes_ecb_encrypt(keyPtr.baseAddress, key.count, inPtr.baseAddress, &out)
            }
        }
        guard rc == 0 else {
            throw ZipReaderError.invalidArchive("AES decrypt failed")
        }
        return out
    }
}

private struct ZipCryptoKeys {
    var k0: UInt32 = 305419896
    var k1: UInt32 = 591751049
    var k2: UInt32 = 878082192

    init(password: [UInt8]) {
        for b in password { update(b) }
    }

    mutating func update(_ byte: UInt8) {
        k0 = crc32(k0, byte)
        k1 = (k1 &+ (k0 & 0xff)) &* 134775813 &+ 1
        k2 = crc32(k2, UInt8((k1 >> 24) & 0xff))
    }

    mutating func nextDecryptByte() -> UInt8 {
        let temp = k2 | 2
        return UInt8(((temp &* (temp ^ 1)) >> 8) & 0xff)
    }

    private func crc32(_ crc: UInt32, _ byte: UInt8) -> UInt32 {
        ZipCryptoKeys.table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8)
    }

    private static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                if c & 1 != 0 {
                    c = 0xedb88320 ^ (c >> 1)
                } else {
                    c >>= 1
                }
            }
            return c
        }
    }()
}
