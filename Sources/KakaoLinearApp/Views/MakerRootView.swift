import AppKit
import KakaoLinearCore
import SwiftUI

struct MakerRootView: View {
  @ObservedObject var state: AppState

  var body: some View {
    VStack(spacing: 0) {
      ProgressHeader(step: state.step, showingSettings: $state.showingSettings)
      if let doctor = state.doctor, !doctor.fullDiskAccess || !doctor.accessibility {
        PermissionBanner(report: doctor) {
          state.showingSettings = true
        }
      }
      if let error = state.errorMessage {
        ErrorBanner(message: error) { state.errorMessage = nil }
      }
      Group {
        switch state.step {
        case .rooms: RoomPickerView(state: state)
        case .messages: MessagePickerView(state: state)
        case .review: ReviewView(state: state)
        case .linear: LinearCreateView(state: state)
        case .result: ResultView(state: state)
        case .settings: Color.clear
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .frame(minWidth: 680, idealWidth: 760, minHeight: 600, idealHeight: 720)
    .overlay {
      if state.isLoading {
        ZStack {
          Color.black.opacity(0.12).ignoresSafeArea()
          ProgressView().controlSize(.large).padding(24).background(.regularMaterial).clipShape(
            .rect(cornerRadius: 12))
        }
      }
    }
    .task {
      if state.rooms.isEmpty { await state.start() }
    }
    .sheet(isPresented: $state.showingSource) {
      SourceSheet(source: state.source)
    }
    .sheet(isPresented: $state.showingSettings) {
      SettingsView(onSaved: { Task { await state.refreshDoctor() } })
    }
  }
}

private struct ProgressHeader: View {
  let step: AppState.Step
  let showingSettings: Binding<Bool>
  private let labels = ["채팅방", "메시지", "AI 검토", "Linear", "완료"]

  var body: some View {
    HStack(spacing: 8) {
      ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
        HStack(spacing: 6) {
          Image(
            systemName: index < step.rawValue ? "checkmark.circle.fill" : "\(index + 1).circle.fill"
          )
          .foregroundStyle(index <= step.rawValue ? Color.accentColor : .secondary)
          Text(label).font(.caption.weight(index == step.rawValue ? .semibold : .regular))
        }
        if index < labels.count - 1 { Divider().frame(width: 20) }
      }
      Spacer()
      Button {
        NSApp.keyWindow?.close()
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.plain)
      .accessibilityLabel("창 닫기")
      Button {
        showingSettings.wrappedValue = true
      } label: {
        Image(systemName: "gearshape")
      }
      .buttonStyle(.plain)
      .accessibilityLabel("설정")
      .padding(.leading, 4)
    }
    .padding(.horizontal, 18)
    .frame(height: 48)
    .background(Color(nsColor: .windowBackgroundColor))
    .overlay(alignment: .bottom) { Divider() }
  }
}

private struct PermissionBanner: View {
  let report: DoctorReport
  let action: () -> Void

  var body: some View {
    HStack {
      Image(systemName: "lock.trianglebadge.exclamationmark").foregroundStyle(.orange)
      Text(permissionText).font(.callout)
      Spacer()
      Button("권한 확인", action: action).controlSize(.small)
    }
    .padding(.horizontal, 16)
    .frame(minHeight: 42)
    .background(Color.orange.opacity(0.1))
  }

  private var permissionText: String {
    if !report.fullDiskAccess { return "KakaoTalk 대화를 읽으려면 Full Disk Access가 필요합니다." }
    return "현재 채팅방과 download fallback에는 Accessibility 권한이 필요합니다."
  }
}

private struct ErrorBanner: View {
  let message: String
  let dismiss: () -> Void

  var body: some View {
    HStack(alignment: .top) {
      Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
      Text(message).font(.callout).textSelection(.enabled)
      Spacer()
      Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain)
    }
    .padding(12)
    .background(Color.red.opacity(0.09))
  }
}

private struct SourceSheet: View {
  let source: SourceBundle?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("선택한 원문").font(.title2.bold())
        Spacer()
        Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      if let source {
        Text("선택하지 않은 메시지는 AI로 전송되지 않습니다.")
          .font(.callout).foregroundStyle(.secondary)
        List(source.messages) { message in
          VStack(alignment: .leading, spacing: 5) {
            Text("\(message.senderName) · \(message.timestamp.formatted())")
              .font(.caption).foregroundStyle(.secondary)
            Text(message.text ?? "[\(message.type.rawValue)]").textSelection(.enabled)
          }
          .padding(.vertical, 4)
        }
      } else {
        ContentUnavailableView("원문이 없습니다", systemImage: "text.bubble")
      }
    }
    .padding(20)
    .frame(minWidth: 560, minHeight: 460)
  }
}