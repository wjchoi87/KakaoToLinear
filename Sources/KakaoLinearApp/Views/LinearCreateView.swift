import KakaoLinearCore
import SwiftUI

struct LinearCreateView: View {
   @ObservedObject var state: AppState

   var body: some View {
     ScrollView {
       VStack(alignment: .leading, spacing: 18) {
         HStack {
          Button {
           state.step = .review
           } label: {
           Label("수정", systemImage: "chevron.left")
           }
         Spacer()
          }
         Text("Linear 이슈 생성").font(.title2.bold())
         Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
          metadataRow("Team") {
           Picker("Team", selection: teamBinding) {
            ForEach(state.teams) { Text("\($0.name) (\($0.key))").tag($0.id) }
             }
              .labelsHidden()
           }
          metadataRow("Project") {
           ProjectPicker(selectedId: optionalBinding(\.projectId), projects: state.projects)
              .labelsHidden()
           }
          metadataRow("Status") {
           Picker("Status", selection: optionalBinding(\.statusId)) {
            Text("Team 기본값").tag(String?.none)
            ForEach(state.statuses) { Text($0.name).tag(Optional($0.id)) }
             }
              .labelsHidden()
           }
          metadataRow("Assignee") {
           Picker("Assignee", selection: optionalBinding(\.assigneeId)) {
            Text("미지정").tag(String?.none)
            ForEach(state.members) { Text($0.name).tag(Optional($0.id)) }
             }
              .labelsHidden()
           }
          metadataRow("Priority") {
           Picker("Priority", selection: $state.linearOptions.priority) {
            ForEach(LinearPriority.allCases, id: \.self) { Text(priorityName($0)).tag($0) }
             }
              .labelsHidden()
           }
          }
         GroupBox("Labels") {
          if state.labels.isEmpty {
           Text("사용 가능한 label이 없습니다.").foregroundStyle(.secondary)
           } else {
           LazyVGrid(columns: [GridItem(.adaptive(minimum: 130))], alignment: .leading) {
            ForEach(state.labels) { label in
             Toggle(
              label.name,
              isOn: Binding(
               get: { state.linearOptions.labelIds.contains(label.id) },
               set: { _ in state.toggleLabel(label.id) }
                )
               )
               .toggleStyle(.checkbox)
             }
            }
            }
          }
         GroupBox("생성할 이슈") {
          VStack(alignment: .leading, spacing: 8) {
           Text(state.draft?.title ?? "").font(.headline)
           Text(state.draft?.summary ?? "").foregroundStyle(.secondary)
           Label("첨부 \(state.source?.resolvedAttachments.count ?? 0)개", systemImage: "paperclip")
             .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
           }
         HStack {
          Text("같은 draft를 재시도해도 이슈는 중복 생성되지 않습니다.")
             .font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button("이슈 생성") { Task { await state.createIssue() } }
             .buttonStyle(.borderedProminent)
             .disabled(state.linearOptions.teamId.isEmpty)
             .keyboardShortcut(.defaultAction)
           }
          }
         .padding(20)
        }
      }

   private var teamBinding: Binding<String> {
    Binding(
      get: { state.linearOptions.teamId },
      set: { value in Task { await state.changeTeam(value) } }
       )
     }

   private func optionalBinding(
      _ keyPath: WritableKeyPath<LinearIssueOptions, String?>
     ) -> Binding<String?> {
    Binding(
      get: { state.linearOptions[keyPath: keyPath] },
      set: { state.linearOptions[keyPath: keyPath] = $0 }
       )
     }

   private func metadataRow<Content: View>(
      _ label: String,
      @ViewBuilder content: () -> Content
     ) -> some View {
    GridRow {
      Text(label).foregroundStyle(.secondary).frame(width: 86, alignment: .trailing)
      content().frame(maxWidth: .infinity, alignment: .leading)
       }
     }

   private func priorityName(_ priority: LinearPriority) -> String {
    switch priority {
    case .none: "No priority"
    case .urgent: "Urgent"
    case .high: "High"
    case .medium: "Medium"
    case .low: "Low"
     }
     }
}

// MARK: - ProjectPicker (검색 가능한 드롭다운)
private struct ProjectPicker: View {
  @Binding var selectedId: String?
  let projects: [LinearProject]
  @State private var query = ""

  var selectedProject: LinearProject? {
    projects.first { $0.id == selectedId }
  }

  var filteredProjects: [LinearProject] {
    guard !query.isEmpty else { return projects }
    let lowerQuery = query.lowercased()
    return projects.filter { $0.name.localizedCaseInsensitiveContains(lowerQuery) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let selectedProject {
        Text(selectedProject.name)
          .font(.body)
          .foregroundColor(.primary)
      } else {
        Text("선택 안 함")
          .font(.body)
          .foregroundColor(.secondary)
      }
      TextField("프로젝트 검색", text: $query)
        .textFieldStyle(.roundedBorder)
        .autocorrectionDisabled()
      List(filteredProjects, id: \.id) { project in
        Button {
          selectedId = project.id
          query = ""
        } label: {
          Text(project.name)
            .foregroundColor(.primary)
        }
        .buttonStyle(.plain)
      }
      .listStyle(.bordered)
      .frame(height: 140)
    }
  }
}
