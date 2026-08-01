import Foundation
import CommonCrypto

enum AESCBC {
    /// AES-128-CBC decryption with PKCS7 padding, as used by HLS AES-128 segments.
    static func decrypt(_ data: Data, key: Data, iv: Data) -> Data? {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else { return nil }
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let status: CCCryptorStatus = out.withUnsafeMutableBytes { outBytes in
            data.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt),
                                CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count,
                                ivBytes.baseAddress,
                                inBytes.baseAddress, data.count,
                                outBytes.baseAddress, out.count,
                                &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.removeSubrange(moved..<out.count)
        return out
    }
}
