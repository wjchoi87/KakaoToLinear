import AppKit
import Foundation
import KakaoLinearCore
import SwiftUI

@MainActor
final class AppState: ObservableObject {
  static let shared = AppState()

  enum Step: Int, CaseIterable {
    case rooms
    case messages
    case review
    case linear
    case result
    case settings
  }

  @Published var step: Step = .rooms
  @Published var rooms: [KakaoRoom] = []
  @Published var messages: [KakaoMessage] = []
  @Published var selectedRoom: KakaoRoom?
  @Published var selectedMessageIds = Set<String>()
  @Published var favoriteRoomIds = Set<String>()
  @Published var source: SourceBundle?
  @Published var draft: IssueDraft?
  @Published var evidence: EvidenceAnalysis?
  @Published var revisionInstruction = ""
  @Published var teams: [LinearTeam] = []
  @Published var projects: [LinearProject] = []
  @Published var statuses: [LinearStatus] = []
  @Published var members: [LinearMember] = []
  @Published var labels: [LinearLabel] = []
  @Published var linearOptions = LinearIssueOptions(teamId: "")
  @Published var result: LinearIssueResult?
  @Published var doctor: DoctorReport?
  @Published var isLoading = false
  @Published var errorMessage: String?
  @Published var showingSource = false
  @Published var showingSettings = false

  private let runtime = KakaoLinearRuntime()
  private let adapter: any KakaoArchiveAdapter
  private let fixtureMode: Bool
  private var selectionAnchorIndex: Int?

  init() {
    if let path = ProcessInfo.processInfo.environment["KAKAO_LINEAR_FIXTURE"],
      let fixture = try? FixtureKakaoArchiveAdapter(url: URL(fileURLWithPath: path))
    {
      adapter = fixture
      fixtureMode = true
    } else {
      adapter = NativeKakaoArchiveAdapter()
      fixtureMode = false
    }
  }

  func start() async {
    favoriteRoomIds = (try? await runtime.roomFavorites.load()) ?? []
    await refreshDoctor()
    if doctor?.fullDiskAccess == true { await loadRooms() }
  }

  func refreshDoctor() async {
    if fixtureMode {
      doctor = DoctorReport(
        kakaoRunning: true,
        accessibility: true,
        fullDiskAccess: true,
        kakaoDatabase: true
      )
      return
    }
    let ai = try? await runtime.aiProvider()
    let linear = try? await runtime.linearClient()
    doctor = await DoctorService().run(adapter: adapter, aiProvider: ai, linearClient: linear)
  }

  func loadRooms(query: String? = nil) async {
    guard doctor?.fullDiskAccess == true else {
      errorMessage = "Full Disk Access를 허용한 뒤 권한 상태를 다시 확인해주세요."
      return
    }
    await perform {
      self.favoriteRoomIds = try await self.runtime.roomFavorites.load()
      let adapter = self.adapter
      self.rooms = try await Task.detached {
        try adapter.listRooms(limit: 100, query: query)
      }.value
    }
  }

  func toggleFavorite(_ room: KakaoRoom) async {
    do {
      favoriteRoomIds = try await runtime.roomFavorites.toggle(roomId: room.id)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func chooseRoom(_ room: KakaoRoom) async {
    await perform {
      self.selectedRoom = room
      self.selectedMessageIds.removeAll()
      self.selectionAnchorIndex = nil
      let adapter = self.adapter
      self.messages = try await Task.detached {
        try adapter.listMessages(roomId: room.id, beforeMessageId: nil, limit: 100)
      }.value
      self.step = .messages
    }
  }

  func loadEarlierMessages() async {
    guard let room = selectedRoom, let first = messages.first else { return }
    await perform {
      let adapter = self.adapter
      let older = try await Task.detached {
        try adapter.listMessages(roomId: room.id, beforeMessageId: first.id, limit: 100)
      }.value
      self.messages = older + self.messages
    }
  }

  /// 최신 100개 대화를 다시 불러와 대화내역을 최신화한다. (하단 "최신 메세지" 버튼)
  func refreshLatest() async {
    guard let room = selectedRoom else { return }
    await perform {
      self.selectedMessageIds.removeAll()
      self.selectionAnchorIndex = nil
      let adapter = self.adapter
      self.messages = try await Task.detached {
        try adapter.listMessages(roomId: room.id, beforeMessageId: nil, limit: 100)
      }.value
    }
  }

  func selectMessage(at index: Int, modifier: MessageSelectionModifier) {
    let result = MessageSelectionPolicy.apply(
      orderedIds: messages.map(\.id),
      current: selectedMessageIds,
      anchorIndex: selectionAnchorIndex,
      clickedIndex: index,
      modifier: modifier
    )
    selectedMessageIds = result.selectedIds
    selectionAnchorIndex = result.anchorIndex
  }

  func selectAllVisible() {
    selectedMessageIds = Set(messages.map(\.id))
    selectionAnchorIndex = messages.isEmpty ? nil : 0
  }

  func clearMessageSelection() {
    selectedMessageIds.removeAll()
    selectionAnchorIndex = nil
  }

  /// 첨부를 실제 파일로 확보하여 미리보기/저장에 쓸 수 있게 한다.
  /// 비동기 resolve이므로 UI에서는 Task로 호출한다.
  func resolveAttachment(_ attachment: KakaoAttachment) async throws -> ResolvedAttachment {
    let dir = FileManager.default.temporaryDirectory.appending(
      path: "kakaotolinear-attachments-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return try await adapter.resolveAttachment(id: attachment.id, outputDirectory: dir)
  }

  func selectFrom(_ index: Int) {
    guard messages.indices.contains(index) else { return }
    for candidate in index..<messages.count { selectedMessageIds.insert(messages[candidate].id) }
    selectionAnchorIndex = index
  }

  func selectThrough(_ index: Int) {
    guard messages.indices.contains(index) else { return }
    for candidate in 0...index { selectedMessageIds.insert(messages[candidate].id) }
    selectionAnchorIndex = index
  }

  func compose() async {
    guard let room = selectedRoom, !selectedMessageIds.isEmpty else { return }
    await perform {
      let source = try await SourceService(adapter: self.adapter, store: self.runtime.artifacts)
        .create(
          selection: SourceSelection(
            roomId: room.id,
            messageIds: Array(self.selectedMessageIds)
          ))
      let provider = try await self.runtime.aiProvider()
      let config = try await self.runtime.configuration.load()
      let composer = IssueComposer(provider: provider, store: self.runtime.artifacts)
      self.evidence = try await composer.analyze(
        sourceId: source.id, agentsInstructions: config.linear.agentsMd)
      let draft = try await composer.compose(
        sourceId: source.id,
        agentsInstructions: config.linear.agentsMd,
        evidence: self.evidence
      )
      self.source = source
      self.draft = draft
      self.step = .review
    }
  }

  func revise() async {
    guard let draft, !revisionInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return
    }
    await perform {
      let reviewed = try await DraftRevisionService(store: self.runtime.artifacts)
        .persistManualEdits(draft)
      let provider = try await self.runtime.aiProvider()
      let config = try await self.runtime.configuration.load()
      let composer = IssueComposer(provider: provider, store: self.runtime.artifacts)
      // 같은 source는 evidence cache를 재사용. "사진 다시 분석해"는 force로 다시 실행.
      self.evidence = try await composer.analyze(
        sourceId: reviewed.sourceId,
        agentsInstructions: config.linear.agentsMd,
        forceRefresh: self.revisionInstruction.contains("사진 다시 분석")
          || self.revisionInstruction.contains("첨부파일 기준으로 다시")
      )
      self.draft = try await composer.revise(
        draftId: reviewed.id,
        instruction: self.revisionInstruction,
        agentsInstructions: config.linear.agentsMd,
        evidence: self.evidence
      )
      self.revisionInstruction = ""
    }
  }

  func prepareLinear() async {
    guard let source, let draft else { return }
    await perform {
      self.draft = try await DraftRevisionService(store: self.runtime.artifacts)
        .persistManualEdits(draft)
      let client = try await self.runtime.linearClient()
      let repository = MetadataRepository(client: client)
      self.teams = try await repository.teams()
      let saved = try await self.runtime.roomDefaults.get(roomId: source.room.id)
      let config = try await self.runtime.configuration.load()
      let preferred = saved?.options.teamId ?? config.linear.defaultTeam
      let team = self.teams.first { $0.id == preferred || $0.key == preferred } ?? self.teams.first
      guard let team else {
        throw KakaoLinearError.linearAPI("사용 가능한 Linear team이 없습니다.")
      }
      self.linearOptions = saved?.options ?? LinearIssueOptions(teamId: team.id)
      self.linearOptions.teamId = team.id
      try await self.loadTeamMetadata(client: client, teamId: team.id)
      self.step = .linear
    }
  }

  func changeTeam(_ teamId: String) async {
    linearOptions.teamId = teamId
    linearOptions.projectId = nil
    linearOptions.statusId = nil
    linearOptions.assigneeId = nil
    linearOptions.labelIds = []
    await perform {
      let client = try await self.runtime.linearClient()
      try await self.loadTeamMetadata(client: client, teamId: teamId)
    }
  }

  func toggleLabel(_ id: String) {
    if linearOptions.labelIds.contains(id) {
      linearOptions.labelIds.removeAll { $0 == id }
    } else {
      linearOptions.labelIds.append(id)
    }
  }

  func createIssue() async {
    guard let draft else { return }
    await perform {
      let client = try await self.runtime.linearClient()
      self.result = try await IssueCreator(
        client: client,
        artifacts: self.runtime.artifacts,
        defaults: self.runtime.roomDefaults
      ).create(draftId: draft.id, options: self.linearOptions)
      self.step = .result
    }
  }

  func reset() async {
    step = .rooms
    selectedRoom = nil
    messages = []
    selectedMessageIds = []
    source = nil
    draft = nil
    evidence = nil
    result = nil
    revisionInstruction = ""
    await loadRooms()
  }

  private func loadTeamMetadata(client: LinearClient, teamId: String) async throws {
    let repository = MetadataRepository(client: client)
    async let projects = repository.projects(teamId: teamId)
    async let statuses = repository.statuses(teamId: teamId)
    async let members = repository.members(teamId: teamId)
    async let labels = repository.labels(teamId: teamId)
    self.projects = try await projects
    self.statuses = try await statuses
    self.members = try await members
    self.labels = try await labels
  }

  private func perform(_ operation: () async throws -> Void) async {
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      try await operation()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
