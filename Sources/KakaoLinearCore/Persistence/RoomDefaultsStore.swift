import Foundation

public actor RoomDefaultsStore {
  private let paths: AppSupportPaths

  public init(paths: AppSupportPaths = AppSupportPaths()) {
    self.paths = paths
  }

  public func get(roomId: String) throws -> RoomLinearDefaults? {
    try load()[roomId]
  }

  public func set(_ defaults: RoomLinearDefaults) throws {
    var mappings = try load()
    mappings[defaults.roomId] = defaults
    try paths.ensureDirectories()
    try JSONEncoder.kakaoLinear.encode(mappings).write(to: paths.roomMappings, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: paths.roomMappings.path
    )
  }

  private func load() throws -> [String: RoomLinearDefaults] {
    guard FileManager.default.fileExists(atPath: paths.roomMappings.path) else { return [:] }
    do {
      return try JSONDecoder.kakaoLinear.decode(
        [String: RoomLinearDefaults].self,
        from: Data(contentsOf: paths.roomMappings)
      )
    } catch {
      throw KakaoLinearError.invalidInput("room-mappings.json을 읽을 수 없습니다.")
    }
  }
}
