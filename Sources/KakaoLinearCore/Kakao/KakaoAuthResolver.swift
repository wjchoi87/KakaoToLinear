import CommonCrypto
import Foundation

struct KakaoPaths: Sendable {
  let homeDirectory: URL
  let dataDirectory: URL

  init(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    dataDirectory: URL? = nil
  ) {
    self.homeDirectory = homeDirectory
    self.dataDirectory =
      dataDirectory
      ?? ProcessInfo.processInfo.environment["KAKAO_LINEAR_HOME"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
      }
      ?? homeDirectory.appending(
        path: "Library/Application Support/KakaoLinear",
        directoryHint: .isDirectory
      )
  }

  var container: URL {
    homeDirectory.appending(
      path:
        "Library/Containers/com.kakao.KakaoTalkMac/Data/Library/Application Support/com.kakao.KakaoTalkMac",
      directoryHint: .isDirectory
    )
  }

  var preferencesDirectory: URL {
    homeDirectory.appending(
      path: "Library/Containers/com.kakao.KakaoTalkMac/Data/Library/Preferences",
      directoryHint: .isDirectory
    )
  }

  var globalPreferences: URL {
    homeDirectory.appending(path: "Library/Preferences/com.kakao.KakaoTalkMac.plist")
  }

  var authCache: URL {
    dataDirectory.appending(path: "kakao/auth.json")
  }
}

struct ResolvedKakaoAuth: Sendable {
  let userId: Int64
  let uuid: String
  let databaseURL: URL
}

struct KakaoAuthResolver: Sendable {
  private static let emptyAccountHash =
    "31bca02094eb78126a517b206a88c73cfa9ec6f704c7030d18212cace820f025f00bf0ea68dbf3f3a5436ca63b53bf7bf80ad8d5de7d8359d0b7fed9dbc3ab99"

  private struct Cache: Codable {
    let userId: Int64
    let uuid: String
  }

  let paths: KakaoPaths
  let environment: [String: String]

  init(
    paths: KakaoPaths = KakaoPaths(),
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.paths = paths
    self.environment = environment
  }

  func databaseFiles() throws -> [URL] {
    let entries: [URL]
    do {
      entries = try FileManager.default.contentsOfDirectory(
        at: paths.container,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    } catch {
      throw KakaoLinearError.permission(
        "KakaoTalk 데이터 폴더를 읽을 수 없습니다. 실행 중인 Terminal 또는 KakaoToLinear.app에 Full Disk Access를 허용해주세요."
      )
    }

    return entries.filter { url in
      let name = url.lastPathComponent
      let stem = name.hasSuffix(".db") ? String(name.dropLast(3)) : name
      return stem.count == 78
        && stem.utf8.allSatisfy {
          (48...57).contains($0) || (97...102).contains($0)
        }
    }.sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  func resolve(allowRecovery: Bool = true) throws -> ResolvedKakaoAuth {
    let databaseFiles = try databaseFiles()
    guard !databaseFiles.isEmpty else {
      throw KakaoLinearError.kakaoDatabase("KakaoTalk SQLCipher database를 찾지 못했습니다.")
    }

    if let cached = readCache(),
      let database = try matchingDatabase(
        userId: cached.userId, uuid: cached.uuid, files: databaseFiles)
    {
      return ResolvedKakaoAuth(userId: cached.userId, uuid: cached.uuid, databaseURL: database)
    }

    let uuid = try environment["KAKAO_LINEAR_KAKAO_UUID"] ?? platformUUID()
    let signals = preferenceSignals()
    var candidates = signals.userIds
    if let override = environment["KAKAO_LINEAR_KAKAO_USER_ID"],
      let userId = Int64(override), userId > 0
    {
      candidates.insert(userId, at: 0)
    }

    for userId in unique(candidates) {
      if let database = try matchingDatabase(userId: userId, uuid: uuid, files: databaseFiles) {
        persistCache(Cache(userId: userId, uuid: uuid))
        return ResolvedKakaoAuth(userId: userId, uuid: uuid, databaseURL: database)
      }
    }

    if allowRecovery, let hash = signals.activeHash {
      let maxUserId =
        environment["KAKAO_LINEAR_MAX_USER_ID"].flatMap(Int64.init)
        ?? 1_000_000_000
      if let userId = recoverUserId(targetHash: hash, maxUserId: maxUserId),
        let database = try matchingDatabase(userId: userId, uuid: uuid, files: databaseFiles)
      {
        persistCache(Cache(userId: userId, uuid: uuid))
        return ResolvedKakaoAuth(userId: userId, uuid: uuid, databaseURL: database)
      }
    }

    throw KakaoLinearError.kakaoDatabase(
      allowRecovery
        ? "KakaoTalk account id를 자동 복구하지 못했습니다."
        : "KakaoTalk database key가 아직 준비되지 않았습니다."
    )
  }

  private func matchingDatabase(userId: Int64, uuid: String, files: [URL]) throws -> URL? {
    let expected = try KakaoKeyDerivation.databaseName(userId: userId, uuid: uuid)
    return files.first { url in
      url.lastPathComponent == expected || url.lastPathComponent == "\(expected).db"
    }
  }

  private func platformUUID() throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
    process.arguments = ["-rd1", "-c", "IOPlatformExpertDevice"]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw KakaoLinearError.kakaoDatabase("ioreg에서 IOPlatformUUID를 읽지 못했습니다.")
    }
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let pattern = #"\"IOPlatformUUID\"\s*=\s*\"([0-9A-Fa-f-]{36})\""#
    let regex = try NSRegularExpression(pattern: pattern)
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: range),
      let uuidRange = Range(match.range(at: 1), in: text)
    else {
      throw KakaoLinearError.kakaoDatabase("IOPlatformUUID 형식을 인식하지 못했습니다.")
    }
    return String(text[uuidRange])
  }

  private func preferenceSignals() -> (userIds: [Int64], activeHash: String?) {
    var files: [URL] = []
    if let entries = try? FileManager.default.contentsOfDirectory(
      at: paths.preferencesDirectory,
      includingPropertiesForKeys: nil
    ) {
      files.append(
        contentsOf: entries.filter {
          $0.lastPathComponent.hasPrefix("com.kakao.KakaoTalkMac") && $0.pathExtension == "plist"
        })
    }
    if FileManager.default.fileExists(atPath: paths.globalPreferences.path) {
      files.append(paths.globalPreferences)
    }

    var ids: [Int64] = []
    var activeHash: String?
    for url in files {
      guard let data = try? Data(contentsOf: url),
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
      else { continue }
      ids.append(contentsOf: extractUserIds(from: plist))
      if activeHash == nil { activeHash = extractActiveHash(from: plist) }
    }
    return (unique(ids), activeHash)
  }

  private func extractUserIds(from value: Any) -> [Int64] {
    let directKeys = Set(["userId", "user_id", "KAKAO_USER_ID", "userID"])
    if let dictionary = value as? [String: Any] {
      var output: [Int64] = []
      for (key, child) in dictionary {
        if directKeys.contains(key), let id = coerceInt64(child), id > 0 {
          output.append(id)
        }
        if key == "AlertKakaoIDsList", let values = child as? [Any] {
          output.append(contentsOf: values.compactMap(coerceInt64).filter { $0 > 0 })
        }
        output.append(contentsOf: extractUserIds(from: child))
      }
      return output
    }
    if let array = value as? [Any] {
      return array.flatMap(extractUserIds)
    }
    return []
  }

  private func extractActiveHash(from value: Any) -> String? {
    if let dictionary = value as? [String: Any] {
      for (key, child) in dictionary {
        if key.hasPrefix("DESIGNATEDFRIENDSREVISION:"),
          let hash = key.split(separator: ":", maxSplits: 1).last.map(String.init),
          hash != Self.emptyAccountHash,
          hash.count == 128,
          hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
          isTruthy(child)
        {
          return hash
        }
        if let nested = extractActiveHash(from: child) { return nested }
      }
    }
    if let array = value as? [Any] {
      for child in array {
        if let nested = extractActiveHash(from: child) { return nested }
      }
    }
    return nil
  }

  private func isTruthy(_ value: Any) -> Bool {
    if let bool = value as? Bool { return bool }
    if let number = value as? NSNumber { return number.intValue != 0 }
    return false
  }

  private func recoverUserId(targetHash: String, maxUserId: Int64) -> Int64? {
    guard maxUserId > 0, let target = hexBytes(targetHash) else { return nil }
    let workerCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
    let found = LockedUserId()
    DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
      var candidate = Int64(worker)
      var iterations = 0
      while candidate <= maxUserId {
        if iterations.isMultiple(of: 4_096), found.value != nil { return }
        let bytes = Array(String(candidate).utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
        bytes.withUnsafeBytes { buffer in
          _ = CC_SHA512(buffer.baseAddress, CC_LONG(bytes.count), &digest)
        }
        if digest == target {
          found.setIfEmpty(candidate)
          return
        }
        candidate += Int64(workerCount)
        iterations += 1
      }
    }
    return found.value
  }

  private func hexBytes(_ value: String) -> [UInt8]? {
    guard value.count.isMultiple(of: 2) else { return nil }
    var output: [UInt8] = []
    output.reserveCapacity(value.count / 2)
    var index = value.startIndex
    while index < value.endIndex {
      let end = value.index(index, offsetBy: 2)
      guard let byte = UInt8(value[index..<end], radix: 16) else { return nil }
      output.append(byte)
      index = end
    }
    return output
  }

  private func coerceInt64(_ value: Any) -> Int64? {
    if let number = value as? NSNumber { return number.int64Value }
    if let string = value as? String { return Int64(string) }
    return nil
  }

  private func unique(_ values: [Int64]) -> [Int64] {
    var seen = Set<Int64>()
    return values.filter { seen.insert($0).inserted }
  }

  private func readCache() -> Cache? {
    guard let data = try? Data(contentsOf: paths.authCache) else { return nil }
    return try? JSONDecoder().decode(Cache.self, from: data)
  }

  private func persistCache(_ cache: Cache) {
    do {
      let directory = paths.authCache.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let data = try JSONEncoder().encode(cache)
      try data.write(to: paths.authCache, options: .atomic)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: paths.authCache.path
      )
    } catch {
      // Cache failure must not block read-only Kakao access.
    }
  }
}
