import Foundation

public actor RoomFavoritesStore {
  private struct Payload: Codable {
    let roomIds: Set<String>
  }

  private let paths: AppSupportPaths

  public init(paths: AppSupportPaths = AppSupportPaths()) {
    self.paths = paths
  }

  public func load() throws -> Set<String> {
    guard FileManager.default.fileExists(atPath: paths.roomFavorites.path) else { return [] }
    do {
      return try JSONDecoder.kakaoLinear.decode(
        Payload.self,
        from: Data(contentsOf: paths.roomFavorites)
      ).roomIds
    } catch {
      throw KakaoLinearError.invalidInput("room-favorites.json을 읽을 수 없습니다.")
    }
  }

  /*
   변경 전 정책 - room 즐겨찾기 상태가 없어 최근 활동 순서로만 방을 찾을 수 있었다.
   변경 후 정책 - room id별 favorite 상태를 local JSON에 원자적으로 저장하고 GUI/CLI가 같은 store를 사용한다.
   변경 이유 - 반복해서 이슈를 만드는 업무방을 최근 메시지 노이즈와 무관하게 빠르게 찾기 위해서다.
   영향 범위 - Room Picker group과 rooms favorite/unfavorite/favorites CLI command에 적용된다.
   */
  public func setFavorite(roomId: String, isFavorite: Bool) throws -> Set<String> {
    guard !roomId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw KakaoLinearError.invalidInput("room id는 비어 있을 수 없습니다.")
    }
    var ids = try load()
    if isFavorite { ids.insert(roomId) } else { ids.remove(roomId) }
    try save(ids)
    return ids
  }

  public func toggle(roomId: String) throws -> Set<String> {
    let ids = try load()
    return try setFavorite(roomId: roomId, isFavorite: !ids.contains(roomId))
  }

  private func save(_ ids: Set<String>) throws {
    try paths.ensureDirectories()
    try JSONEncoder.kakaoLinear.encode(Payload(roomIds: ids)).write(
      to: paths.roomFavorites,
      options: .atomic
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: paths.roomFavorites.path
    )
  }
}
