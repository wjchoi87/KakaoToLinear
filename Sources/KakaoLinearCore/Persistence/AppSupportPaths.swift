import Foundation

public struct AppSupportPaths: Sendable {
  public let root: URL

  public init(root: URL? = nil) {
    if let root {
      self.root = root
    } else if let override = ProcessInfo.processInfo.environment["KAKAO_LINEAR_HOME"],
      !override.isEmpty
    {
      self.root = URL(fileURLWithPath: override, isDirectory: true)
    } else {
      let base = FileManager.default.homeDirectoryForCurrentUser.appending(
        path: "Library/Application Support",
        directoryHint: .isDirectory
      )
      // 앱 이름이 KakaoToLinear로 바뀌어 경로도 바뀌었다.
      // 이전 이름(KakaoLinear)으로 데이터가 있으면 최초 1회 옮겨 기존 설정/대화 데이터를 보존한다.
      AppSupportPaths.migrateLegacyDataIfNeeded(in: base)
      self.root = base.appending(path: "KakaoToLinear", directoryHint: .isDirectory)
    }
  }

  // 옛 KakaoLinear 폴더 → KakaoToLinear 폴더 1회 마이그레이션.
  // KakaoLinear 폴더가 있고 KakaoToLinear 폴더가 없을 때만 rename한다.
  private static func migrateLegacyDataIfNeeded(in base: URL) {
    let legacy = base.appending(path: "KakaoLinear", directoryHint: .isDirectory)
    let current = base.appending(path: "KakaoToLinear", directoryHint: .isDirectory)
    let fm = FileManager.default
    guard fm.fileExists(atPath: legacy.path) && !fm.fileExists(atPath: current.path) else { return }
    try? fm.moveItem(at: legacy, to: current)
  }

  public var config: URL { root.appending(path: "config.json") }
  public var agentsMd: URL { root.appending(path: "agents.md") }
  public var roomMappings: URL { root.appending(path: "room-mappings.json") }
  public var roomFavorites: URL { root.appending(path: "room-favorites.json") }
  public var sources: URL { root.appending(path: "sources", directoryHint: .isDirectory) }
  public var drafts: URL { root.appending(path: "drafts", directoryHint: .isDirectory) }
  public var evidence: URL { root.appending(path: "evidence", directoryHint: .isDirectory) }
  public var cache: URL { root.appending(path: "cache", directoryHint: .isDirectory) }
  public var resolvedAttachments: URL {
    cache.appending(path: "resolved", directoryHint: .isDirectory)
  }
  public var metadataCache: URL {
    cache.appending(path: "linear-metadata", directoryHint: .isDirectory)
  }
  public var operations: URL { root.appending(path: "operations", directoryHint: .isDirectory) }
  public var logs: URL { root.appending(path: "logs", directoryHint: .isDirectory) }
  public var aiErrorLog: URL { logs.appending(path: "ai-errors.log") }

  public func ensureDirectories() throws {
    for directory in [
      root, sources, drafts, evidence, cache, resolvedAttachments, metadataCache, operations, logs,
    ] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: directory.path
      )
    }
  }
}
