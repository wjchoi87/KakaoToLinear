import Foundation

public struct MetadataRepository: Sendable {
  private let client: LinearClient
  private let cache: MetadataCache

  public init(client: LinearClient, cache: MetadataCache = MetadataCache()) {
    self.client = client
    self.cache = cache
  }

  public func teams(refresh: Bool = false) async throws -> [LinearTeam] {
    try await cache.value(key: "teams", ttl: 600, refresh: refresh) {
      try await client.teams()
    }
  }

  public func projects(teamId: String, refresh: Bool = false) async throws -> [LinearProject] {
    try await cache.value(key: "projects-\(teamId)", ttl: 300, refresh: refresh) {
      try await client.projects(teamId: teamId)
    }
  }

  public func statuses(teamId: String, refresh: Bool = false) async throws -> [LinearStatus] {
    try await cache.value(key: "statuses-\(teamId)", ttl: 1_800, refresh: refresh) {
      try await client.statuses(teamId: teamId)
    }
  }

  public func members(teamId: String, refresh: Bool = false) async throws -> [LinearMember] {
    try await cache.value(key: "members-\(teamId)", ttl: 1_800, refresh: refresh) {
      try await client.members(teamId: teamId)
    }
  }

  public func labels(teamId: String, refresh: Bool = false) async throws -> [LinearLabel] {
    try await cache.value(key: "labels-\(teamId)", ttl: 1_800, refresh: refresh) {
      try await client.labels(teamId: teamId)
    }
  }
}
