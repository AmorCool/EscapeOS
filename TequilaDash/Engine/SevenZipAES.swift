import Foundation

/// 7-Zip AES-256 (method `06 F1 07 01`) with SHA-256 key derivation.
/// SWCompression parses encrypted folders but cannot decrypt; we do that here.
enum SevenZipAES {

    private static let tlsKey = "eos.sevenz.password"

    /// Password for the current extract, stored on this thread only.
    static var password: String? {
        get { Thread.current.threadDictionary[tlsKey] as? String }
        set {
            if let newValue, !newValue.isEmpty {
                Thread.current.threadDictionary[tlsKey] = newValue
            } else {
                Thread.current.threadDictionary.removeObject(forKey: tlsKey)
            }
        }
    }

    static func decrypt(data: Data, coder: SevenZipCoder) throws -> Data {
        guard coder.id == [0x06, 0xF1, 0x07, 0x01] else {
            throw SevenZipError.encryptionNotSupported
        }
        guard let password = password, !password.isEmpty else {
            throw SevenZipError.encryptionNotSupported
        }
        guard let props = coder.properties, !props.isEmpty else {
            throw SevenZipError.internalStructureError
        }
        guard let pw = password.data(using: .utf16LittleEndian), !pw.isEmpty else {
            throw ZipReaderError.wrongPassword
        }
        if data.isEmpty {
            return Data()
        }
        var out = Data(count: data.count)
        let cap = out.count
        var outLen = 0
        let rc = props.withUnsafeBufferPointer { propBuf -> Int32 in
            pw.withUnsafeBytes { pwBuf in
                data.withUnsafeBytes { dataBuf in
                    out.withUnsafeMutableBytes { outBuf in
                        sevenz_aes_decrypt(
                            propBuf.baseAddress, props.count,
                            pwBuf.bindMemory(to: UInt8.self).baseAddress, pw.count,
                            dataBuf.bindMemory(to: UInt8.self).baseAddress, data.count,
                            outBuf.bindMemory(to: UInt8.self).baseAddress, cap,
                            &outLen
                        )
                    }
                }
            }
        }
        if rc == -4 {
            throw SevenZipError.encryptionNotSupported
        }
        guard rc == 0 else {
            throw ZipReaderError.wrongPassword
        }
        return out.subdata(in: 0..<outLen)
    }
}
