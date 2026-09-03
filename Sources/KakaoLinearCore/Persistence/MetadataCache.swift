import Foundation

public actor MetadataCache {
  private struct Entry<Value: Codable & Sendable>: Codable, Sendable {
    let expiresAt: Date
    let value: Value
  }

  private let paths: AppSupportPaths

  public init(paths: AppSupportPaths = AppSupportPaths()) {
    self.paths = paths
  }

  public func value<Value: Codable & Sendable>(
    key: String,
    ttl: TimeInterval,
    refresh: Bool,
    fetch: @Sendable () async throws -> Value
  ) async throws -> Value {
    let url = paths.metadataCache.appending(path: "\(safe(key)).json")
    if !refresh,
      let data = try? Data(contentsOf: url),
      let entry = try? JSONDecoder.kakaoLinear.decode(Entry<Value>.self, from: data),
      entry.expiresAt > Date()
    {
      return entry.value
    }
    let fetched = try await fetch()
    try paths.ensureDirectories()
    let entry = Entry(expiresAt: Date().addingTimeInterval(ttl), value: fetched)
    try JSONEncoder.kakaoLinear.encode(entry).write(to: url, options: .atomic)
    return fetched
  }

  public func clear() throws {
    guard FileManager.default.fileExists(atPath: paths.metadataCache.path) else { return }
    let files = try FileManager.default.contentsOfDirectory(
      at: paths.metadataCache,
      includingPropertiesForKeys: nil
    )
    for file in files where file.pathExtension == "json" {
      try FileManager.default.removeItem(at: file)
    }
  }

  private func safe(_ key: String) -> String {
    key.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
  }
}
