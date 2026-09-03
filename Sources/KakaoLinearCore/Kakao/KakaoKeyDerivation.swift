import CommonCrypto
import CryptoSwift
import Foundation

enum KakaoKeyDerivation {
  private static let rounds = 100_000
  private static let derivedLength = 128

  static func hashedDeviceUUID(_ uuid: String) -> String {
    let bytes = Array(uuid.utf8)
    let combined = bytes.sha1() + bytes.sha256()
    return Data(combined).base64EncodedString()
  }

  static func secureKey(userId: Int64, uuid: String) throws -> String {
    try validate(uuid: uuid)
    let hashed = hashedDeviceUUID(uuid)
    let parts = [
      "A", hashed, "|", "F", String(uuid.prefix(5)), "H",
      String(userId), "|", String(uuid.dropFirst(7)),
    ]
    let password = String(parts.joined(separator: "F").reversed())
    let saltOffset = Int(Double(uuid.utf8.count) * 0.3)
    let salt = String(uuid.dropFirst(saltOffset))
    let bytes = try pbkdf2(password: password, salt: salt)
    return bytes.toHexString()
  }

  static func databaseName(userId: Int64, uuid: String) throws -> String {
    try validate(uuid: uuid)
    let reversedUUID = String(uuid.reversed())
    let password = [".", "F", String(userId), "A", "F", reversedUUID, ".", "|"]
      .joined(separator: ".")
    let salt = String(hashedDeviceUUID(uuid).reversed())
    let bytes = try pbkdf2(password: password, salt: salt)
    let hex = bytes.toHexString()
    return String(hex.dropFirst(28).prefix(78))
  }

  private static func pbkdf2(password: String, salt: String) throws -> [UInt8] {
    let saltBytes = Array(salt.utf8)
    var derived = [UInt8](repeating: 0, count: derivedLength)
    let status = password.withCString { passwordPointer in
      saltBytes.withUnsafeBufferPointer { saltBuffer in
        derived.withUnsafeMutableBufferPointer { derivedBuffer in
          CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            passwordPointer,
            password.utf8.count,
            saltBuffer.baseAddress,
            saltBytes.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            UInt32(rounds),
            derivedBuffer.baseAddress,
            derivedLength
          )
        }
      }
    }
    guard status == kCCSuccess else {
      throw KakaoLinearError.kakaoDatabase("KakaoTalk PBKDF2 key derivation에 실패했습니다.")
    }
    return derived
  }

  private static func validate(uuid: String) throws {
    guard uuid.utf8.count == 36,
      uuid.allSatisfy({ $0.isHexDigit || $0 == "-" })
    else {
      throw KakaoLinearError.kakaoDatabase("유효한 IOPlatformUUID를 읽지 못했습니다.")
    }
  }
}
