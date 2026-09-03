import CommonCrypto
import Foundation
import Testing

@testable import KakaoLinearCore

@Suite("KakaoLinear Phase 0 Core")
struct KakaoLinearCoreTests {
  @Test("public reference vector로 database name을 유도한다")
  func databaseNameVector() throws {
    let result = try KakaoKeyDerivation.databaseName(
      userId: 1_000_000_001,
      uuid: "00000000-1111-2222-3333-444444444444"
    )
    #expect(
      result == "de345a8eb68ff0db3c1f8b94817936a00471d335162afc05cdfc758f638a33d427ea7742d4d420")
  }

  @Test("secure key는 256 lowercase hex다")
  func secureKeyShape() throws {
    let result = try KakaoKeyDerivation.secureKey(
      userId: 1_000_000_001,
      uuid: "00000000-1111-2222-3333-444444444444"
    )
    #expect(result.count == 256)
    #expect(result.allSatisfy { $0.isNumber || ("a"..."f").contains(String($0)) })
  }

  @Test("fixture room과 message pagination이 동일한 domain contract를 사용한다")
  func fixtureAdapter() throws {
    let fixture = try #require(
      Bundle.module.url(
        forResource: "sample",
        withExtension: "json",
        subdirectory: "Fixtures"
      ))
    let adapter = try FixtureKakaoArchiveAdapter(url: fixture)

    let rooms = try adapter.listRooms(limit: 30, query: "A업체")
    #expect(rooms.map(\.id) == ["room_123"])

    let messages = try adapter.listMessages(
      roomId: "room_123",
      beforeMessageId: "msg_103",
      limit: 100
    )
    #expect(messages.map(\.id) == ["msg_101", "msg_102"])
    #expect(messages[1].attachments.map(\.id) == ["att_102_0"])
  }

  @Test("invalid identifier를 조용히 허용하지 않는다")
  func invalidIdentifier() {
    #expect(throws: KakaoLinearError.self) {
      try KakaoIdentifiers.chatId(from: "123")
    }
    #expect(throws: KakaoLinearError.self) {
      try KakaoIdentifiers.attachmentParts(from: "att_bad")
    }
  }

  @Test("public Pkv2 reference ciphertext에서 full image를 복호화한다")
  func decryptsPkv2Reference() async throws {
    let logId: Int64 = 1_234_567_890_123
    let chatId: Int64 = 42
    let encryptedHex = """
      506b7632000102030405060708090a0b0c0d0e0f554b63056928134b57397f6a2e06f1f04faf2ce5a3905914af3afabf90b8605bc39e6f7ffe132a0bd65963bc6fdbc111d283724581b869f60e1c85fedaf14265380a50c41ab3efa9a46bade5e1bce7dc175f8fc5d06a29cc14bb8afbe382eb5bba3e676fd35b0c002fdf5621adedc2d344db8c97873ae4c62769b38524501062322c5258f86688e325f549a11696b3e68ed354979c4df585732c1d42b49afe3ac97b46997e39c43e9818cdd9870b7032d8da56cfe0663201a1daa321ad7a1ee6bbdb584d7b76ca562e05d26eeb3dd7b777c01c18e091bb177fef85bb1013c6b632c75112780f8f1b423dc5587e17ca1aacc3c8a585373fe2142cd299303fd1ec64340e58e9dabd4c6f1b2d5298eab53a925efb785f0eac9961d736046ba914fd
      """
    let encrypted = try hexData(encryptedHex)
    let temporary = FileManager.default.temporaryDirectory.appending(
      path: UUID().uuidString,
      directoryHint: .isDirectory
    )
    let container = temporary.appending(path: "container", directoryHint: .isDirectory)
    let account = container.appending(
      path: String(repeating: "a", count: 40), directoryHint: .isDirectory)
    let room = account.appending(
      path: sha1Hex(Data(String(String(chatId).reversed()).utf8)),
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: room, withIntermediateDirectories: true)
    let stem = sha1Hex(Data(String("p\(logId)".reversed()).utf8))
    try encrypted.write(to: room.appending(path: "\(stem).img"))

    let attachment = KakaoAttachment(
      id: "att_\(logId)_0",
      messageId: "msg_\(logId)",
      kind: .image,
      originalName: "../\u{202E}screenshot.jpg",
      hash: "91ed9414d7eb34fe648db42be27a0b7847dc8c8e",
      fullAvailable: true
    )
    let output = temporary.appending(path: "output", directoryHint: .isDirectory)
    let result = try await FullAttachmentResolver(container: container).resolve(
      attachment: attachment,
      chatId: chatId,
      logId: logId,
      messageType: 2,
      frameIndex: 0,
      outputDirectory: output
    )

    #expect(result.tier == .localFull)
    #expect(result.sha1 == "91ed9414d7eb34fe648db42be27a0b7847dc8c8e")
    #expect(result.fileURL.deletingLastPathComponent() == output)
    #expect(!result.fileURL.lastPathComponent.contains("\u{202E}"))
    #expect(
      try Data(contentsOf: result.fileURL) == hexData("ffd8ffe04b41544f4b2d504b56322d54455354ffd9"))
  }

  @Test("active account SHA-512에서 one-time user id를 복구한다")
  func recoversUserIdFromPreferenceHash() throws {
    let userId: Int64 = 4_242
    let uuid = "00000000-1111-2222-3333-444444444444"
    let home = FileManager.default.temporaryDirectory.appending(
      path: "kakao-auth-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let container = home.appending(
      path:
        "Library/Containers/com.kakao.KakaoTalkMac/Data/Library/Application Support/com.kakao.KakaoTalkMac",
      directoryHint: .isDirectory
    )
    let preferences = home.appending(
      path: "Library/Containers/com.kakao.KakaoTalkMac/Data/Library/Preferences",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: true)
    let databaseName = try KakaoKeyDerivation.databaseName(userId: userId, uuid: uuid)
    try Data().write(to: container.appending(path: databaseName))
    let hash = sha512Hex(Data(String(userId).utf8))
    let plist: [String: Any] = ["DESIGNATEDFRIENDSREVISION:\(hash)": true]
    let plistData = try PropertyListSerialization.data(
      fromPropertyList: plist,
      format: .binary,
      options: 0
    )
    try plistData.write(
      to: preferences.appending(path: "com.kakao.KakaoTalkMac.test.plist")
    )
    let resolved = try KakaoAuthResolver(
      paths: KakaoPaths(homeDirectory: home, dataDirectory: home.appending(path: "data")),
      environment: [
        "KAKAO_LINEAR_KAKAO_UUID": uuid,
        "KAKAO_LINEAR_MAX_USER_ID": "10000",
      ]
    ).resolve()
    #expect(resolved.userId == userId)
    #expect(resolved.databaseURL.lastPathComponent == databaseName)
  }

  private func hexData(_ input: String) throws -> Data {
    let hex = input.filter(\.isHexDigit)
    guard hex.count.isMultiple(of: 2) else {
      throw KakaoLinearError.invalidInput("test hex length")
    }
    var output = Data(capacity: hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      guard let byte = UInt8(hex[index..<next], radix: 16) else {
        throw KakaoLinearError.invalidInput("test hex byte")
      }
      output.append(byte)
      index = next
    }
    return output
  }

  private func sha1Hex(_ data: Data) -> String {
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
    data.withUnsafeBytes { buffer in
      _ = CC_SHA1(buffer.baseAddress, CC_LONG(data.count), &digest)
    }
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private func sha512Hex(_ data: Data) -> String {
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
    data.withUnsafeBytes { buffer in
      _ = CC_SHA512(buffer.baseAddress, CC_LONG(data.count), &digest)
    }
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}
