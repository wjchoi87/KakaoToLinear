import AppKit
import KakaoLinearCore
import SwiftUI
import UniformTypeIdentifiers
import Vision

struct MessagePickerView: View {
  @ObservedObject var state: AppState
  @State private var previewItem: PreviewItem?
  @State private var backEventMonitor: Any?
  @State private var highlightMessageId: String?

  var body: some View {
    GeometryReader { geometry in
      VStack(spacing: 0) {
        HStack {
          Button {
            state.step = .rooms
          } label: {
            Label("채팅방", systemImage: "chevron.left")
          }
          Divider().frame(height: 18)
          Text(state.selectedRoom?.title ?? "메시지").font(.headline)
          Spacer()
          Button("이전 메시지 100개") { Task { await state.loadEarlierMessages() } }
        }
        .padding(16)
        .fixedSize(horizontal: false, vertical: true)
        Divider()
        Group {
          if state.messages.isEmpty {
            ContentUnavailableView("메시지가 없습니다", systemImage: "text.bubble")
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
            messageList
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        Divider()
        footer
      }
      .frame(
        width: geometry.size.width,
        height: geometry.size.height,
        alignment: .top
      )
      .sheet(item: $previewItem) { item in
        AttachmentPreviewView(item: item)
      }
      .onAppear { installBackMonitor() }
      .onDisappear { removeBackMonitor() }
    }
  }

  private func scrollToBottom() {
    NotificationCenter.default.post(name: .scrollMessagesToBottom, object: nil)
  }

  // 마우스 뒤로가기(3번)와 Esc 처리를 위한 로컬 이벤트 모니터.
  private func installBackMonitor() {
    guard backEventMonitor == nil else { return }
    backEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .keyDown]) {
      event in
      // 마우스 뒤로가기 버튼 → 채팅방 목록으로.
      if event.type == .otherMouseDown, event.buttonNumber == 3, state.step == .messages {
        state.step = .rooms
        return nil
      }
      // Esc(키코드 53) → 전체 해제.
      if event.type == .keyDown, event.keyCode == 53 {
        state.clearMessageSelection()
        return nil
      }
      return event
    }
  }

  private func removeBackMonitor() {
    if let monitor = backEventMonitor {
      NSEvent.removeMonitor(monitor)
      backEventMonitor = nil
    }
  }

  // MARK: - 메시지 리스트 (말풍선)

  private var messageList: some View {
    ScrollViewReader { proxy in
      ScrollView(.vertical) {
        // 메시지를 위아래로 쌓는다.
        VStack(spacing: 14) {
          ForEach(Array(state.messages.enumerated()), id: \.element.id) { index, message in
            MessageBubble(
              message: message,
              replyMessage: message.replyToMessageId.flatMap { id in
                state.messages.first { $0.id == id }
              },
              isMine: isMine(message),
              showSenderInfo: showsSenderInfo(at: index),
              selected: state.selectedMessageIds.contains(message.id),
              highlighted: message.id == highlightMessageId,
              select: {
                state.selectMessage(at: index, modifier: selectionModifier())
              },
              resolveAttachment: {
                try await state.resolveAttachment($0)
              },
              presentPreview: { item in
                previewItem = item
              },
              onJumpToReply: { id in
                scrollToMessage(id, in: proxy)
              }
            )
            .id(message.id)
            .contextMenu {
              MessageContextMenu(
                message: message,
                resolveAttachment: {
                  try? await state.resolveAttachment($0)
                },
                presentPreview: { item in
                  previewItem = item
                }
              )
            }
          }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 4)
        // 최하단 스크롤용 앵커 마커. 항상 렌더되어 끝까지 스크롤이 가능하다.
        Color.clear
          .frame(height: 1)
          .id("messages-tail")
      }
      .scrollIndicators(.hidden)
      .onChange(of: state.messages.last?.id) {
        guard state.messages.isEmpty == false else { return }
        scrollToBottom(in: proxy)
      }
      .onAppear {
        guard state.messages.isEmpty == false else { return }
        scrollToBottom(in: proxy)
      }
      .onReceive(NotificationCenter.default.publisher(for: .scrollMessagesToBottom)) { _ in
        scrollToBottom(in: proxy)
      }
    }
  }

  private func scrollToBottom(in proxy: ScrollViewProxy) {
    guard state.messages.isEmpty == false else { return }
    // 콘텐츠 최하단 마커로 스크롤해 절대 바닥에 정확히 붙인다.
    proxy.scrollTo("messages-tail", anchor: .bottom)
    DispatchQueue.main.async {
      proxy.scrollTo("messages-tail", anchor: .bottom)
    }
  }

  private func scrollToMessage(_ id: String, in proxy: ScrollViewProxy) {
    withAnimation(.easeInOut(duration: 0.25)) {
      proxy.scrollTo(id, anchor: .center)
    }
    // 원문으로 이동하면 잠시 테두리를 반짝여 눈에 띄게 한다.
    highlightMessageId = id
    Task {
      try? await Task.sleep(nanoseconds: 1_400_000_000)
      if highlightMessageId == id { withAnimation { highlightMessageId = nil } }
    }
  }

  // 같은 발신자가 같은 분(minute)에 연달아 보낸 메시지는 첫 메시지에만 발신자/시각 정보를 보여준다.
  private func showsSenderInfo(at index: Int) -> Bool {
    guard index > 0, index < state.messages.count else { return true }
    let previous = state.messages[index - 1]
    let current = state.messages[index]
    let sameSender =
      previous.senderId != nil
      ? previous.senderId == current.senderId : previous.senderName == current.senderName
    let sameMinute = Calendar.current.isDate(
      previous.timestamp, equalTo: current.timestamp, toGranularity: .minute)
    return !(sameSender && sameMinute)
  }

  // MARK: - 하단 푸터

  private var footer: some View {
    HStack {
      Text("\(state.selectedMessageIds.count)개 선택").foregroundStyle(.secondary)
      Button("전체 선택") { state.selectAllVisible() }
        .keyboardShortcut("a", modifiers: .command)
      Button("전체 해제") { state.clearMessageSelection() }
      // 최신화: 최신 대화를 다시 불러오고 스크롤을 맨 아래로 이동한다.
      Button("최신 메세지") { scrollToLatest() }
      Spacer()
      Text("⌘클릭 추가 · ⇧클릭 범위 · 선택한 메시지만 AI 전송")
        .font(.caption).foregroundStyle(.secondary)
      Button("정리") { Task { await state.compose() } }
        .buttonStyle(.borderedProminent)
        .disabled(state.selectedMessageIds.isEmpty)
        .keyboardShortcut(.defaultAction)
    }
    .padding(16)
    .fixedSize(horizontal: false, vertical: true)
  }

  // 최신 대화를 다시 불러오고, 로드된 뒤 최하단으로 스크롤한다.
  private func scrollToLatest() {
    Task {
      await state.refreshLatest()
      NotificationCenter.default.post(name: .scrollMessagesToBottom, object: nil)
    }
  }

  private func selectionModifier() -> MessageSelectionModifier {
    let modifiers = NSEvent.modifierFlags.intersection([.command, .shift])
    if modifiers.contains(.command), modifiers.contains(.shift) { return .commandShift }
    if modifiers.contains(.command) { return .command }
    if modifiers.contains(.shift) { return .shift }
    return .none
  }

  /// Native adapter는 currentUserId 기준으로 isMine을 채운다. 과거 JSON은 senderName=="나"로 fallback.
  private func isMine(_ message: KakaoMessage) -> Bool {
    message.isMine || message.senderName == "나"
  }
}

// MARK: - PreviewItem (이미지/파일 미리보기 시트 대상)

struct PreviewItem: Identifiable {
  let id = UUID()
  let url: URL
  let name: String
  let kind: AttachmentKind
}

// MARK: - 말풍선 행

private struct MessageBubble: View {
  let message: KakaoMessage
  let replyMessage: KakaoMessage?
  let isMine: Bool
  let showSenderInfo: Bool
  let selected: Bool
  let highlighted: Bool
  let select: () -> Void
  let resolveAttachment: (KakaoAttachment) async throws -> ResolvedAttachment
  let presentPreview: (PreviewItem) -> Void
  let onJumpToReply: (String) -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      // 좌측 크게 보이는 체크박스. 선택 여부를 한눈에 보이게 한다.
      Image(systemName: selected ? "checkmark.circle.fill" : "circle")
        .font(.title2)
        .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
        .onTapGesture { select() }
        .help("메시지 선택")

      HStack(alignment: .bottom, spacing: 8) {
        if isMine { Spacer(minLength: 24) }
        VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
          // 같은 분 연속 메시지는 첫 메시지에만 발신자/시각 정보를 표시한다.
          if showSenderInfo {
            HStack(spacing: 6) {
              Text(message.senderName).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
              Text(message.timestamp, style: .time).font(.caption2).foregroundStyle(.tertiary)
            }
          }
          Group {
            if isAttachmentOnly {
              // 이미지/파일만 있는 메시지는 말풍선 배경을 없애고 첨부 타일 자체를 표시한다.
              // (이미지 썸네일/파일 타일이 각자의 배경을 가지므로 "너비 고정"없이 내용 크기로 보인다)
              bubbleBody
            } else {
              bubbleBody.background(bubbleBackground)
            }
          }
          // 말풍선 폭은 내용 텍스트의 실제 폭에 맞춰 계산한다(짧으면 좁게, 길면 줄바꿈).
          // 첨부 메시지는 nil을 반환해 첨부 타일이 내용에 맞게 폭을 결정하게 한다.
          .modifier(
            MeasuredBubbleWidth(width: bubbleWidth(), alignment: isMine ? .trailing : .leading)
          )
          .contentShape(Rectangle())
          .overlay {
            if highlighted {
              RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.orange, lineWidth: 3)
                .animation(
                  .easeInOut(duration: 0.9).repeatCount(3, autoreverses: true), value: highlighted
                )
            }
          }
        }
        if !isMine { Spacer(minLength: 24) }
      }
      .contentShape(Rectangle())
      .onTapGesture { select() }
    }
  }

  @ViewBuilder
  private var bubbleBody: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let replyQuoteText = message.replyQuoteText {
        ReplyQuote(
          replyAuthorName: message.replyAuthorName,
          replyBody: replyQuoteText,
          onTap: {
            if let id = message.replyToMessageId { onJumpToReply(id) }
          }
        )
      } else if let reply = replyMessage {
        // 파싱된 인용 원문이 없으면 로드된 원본 메시지를 fallback로 표시한다.
        ReplyQuote(
          replyAuthorName: reply.senderName,
          replyBody: replyBody(from: reply),
          onTap: {
            if let id = message.replyToMessageId { onJumpToReply(id) }
          }
        )
      }
      let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines)
      if let text, !text.isEmpty {
        Text(text)
          .textSelection(.enabled)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
      }
      if message.attachments.isEmpty == false {
        AttachmentStrip(
          isMine: isMine,
          message: message,
          resolveAttachment: resolveAttachment,
          presentPreview: presentPreview
        )
      }
      // 내가 보낸 메시지에는 항상 보낸 시각을 표시한다.
      if isMine {
        Text(message.timestamp, style: .time)
          .font(.caption2)
          .foregroundStyle(.white.opacity(0.8))
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .foregroundStyle(isMine ? Color.white : Color.primary)
  }

  @ViewBuilder
  private var bubbleBackground: some View {
    let color = isMine ? Color.accentColor : Color.secondary.opacity(0.18)
    RoundedRectangle(cornerRadius: 14, style: .continuous)
      .fill(selected ? color.opacity(0.75) : color)
  }

  private func replyBody(from reply: KakaoMessage) -> String {
    let text = reply.text?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let text, !text.isEmpty { return text }
    if let name = reply.attachments.first?.originalName { return "📎 \(name)" }
    return "첨부 메시지"
  }

  // 말풍선 폭을 "항상" 계산해서 내보냄(multi case). nil을 반환하지 않아
  // Spacer/HStack이 버블을 전체 폭으로 펼치는 것을 구조적으로 막는다.
  private func bubbleWidth() -> CGFloat {
    let cap: CGFloat = isMine ? 380 : 460
    var width: CGFloat = 48

    // 답글 인용
    if let quote = message.replyQuoteText?.trimmingCharacters(in: .whitespacesAndNewlines),
      !quote.isEmpty
    {
      let q =
        ceil((quote as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width)
        + 24  // 인용 내부 여백/화살표
      width = max(width, q)
    }

    // 본문 텍스트
    if let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
      let t =
        ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width)
        + 24  // 좌우 패딩 12+12
      width = max(width, t)
    }

    // 첨부(이미지/파일): 콘텐츠 폭
    for attachment in message.attachments {
      if attachment.kind == .image {
        width = max(width, 172)  // 160 썸네일 + 좌우 패딩
      } else {
        let name = attachment.originalName ?? attachment.id
        let n =
          ceil(
            (name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width)
          + 56  // 아이콘+정보+여백
        width = max(width, n)
      }
    }

    return min(max(width, 48), cap)
  }

  // 첨부(이미지/파일)만 있고 텍스트/답글이 없는 메시지인지. 이런 경우 말풍선 배경 없이 첨부 타일만 표시한다.
  private var isAttachmentOnly: Bool {
    if message.attachments.isEmpty { return false }
    let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return text.isEmpty && message.replyToMessageId == nil
  }
}

// 항상 명시된 폭을 적용한다.
private struct MeasuredBubbleWidth: ViewModifier {
  let width: CGFloat
  let alignment: Alignment

  func body(content: Content) -> some View {
    content.frame(width: width, alignment: alignment)
  }
}

// 답장 인용 블록

private struct ReplyQuote: View {
  let replyAuthorName: String?
  let replyBody: String
  let onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      VStack(alignment: .leading, spacing: 2) {
        Text("\(authorName)의 메시지에 답장")
          .font(.caption2)
          .foregroundStyle(.secondary)
        Text(replyBody)
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.leading)
          .lineLimit(2)
      }
      .padding(8)
      .frame(minWidth: 0, maxWidth: 320, alignment: .leading)
      .background(Color.black.opacity(0.08))
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("원본 메시지로 이동")
  }

  private var authorName: String {
    if let replyAuthorName, !replyAuthorName.isEmpty { return replyAuthorName }
    return "상대방"
  }
}

// MARK: - 첨부 표시 + 미리보기/저장

private struct AttachmentStrip: View {
  let isMine: Bool
  let message: KakaoMessage
  let resolveAttachment: (KakaoAttachment) async throws -> ResolvedAttachment
  let presentPreview: (PreviewItem) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(message.attachments) { attachment in
        if attachment.kind == .image {
          imageThumbnail(attachment)
        } else {
          fileRow(attachment)
        }
      }
    }
  }

  // 이미지: 썸네일처럼 작게 표시하고 클릭 시 미리보기를 연다.
  private func imageThumbnail(_ attachment: KakaoAttachment) -> some View {
    Button {
      Task {
        guard let resolved = try? await resolveAttachment(attachment) else { return }
        presentPreview(
          PreviewItem(
            url: resolved.fileURL, name: resolved.attachment.originalName ?? "image", kind: .image))
      }
    } label: {
      ThumbnailImage(attachment: attachment, resolveAttachment: resolveAttachment)
        .frame(width: 160, height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
          Image(systemName: "magnifyingglass.circle.fill")
            .font(.title3)
            .foregroundStyle(.white.opacity(0.9))
            .padding(4)
        }
    }
    .buttonStyle(.plain)
    .contentShape(Rectangle())
    .help(attachment.originalName ?? "이미지 미리보기")
  }

  // 파일: 파일명과 파일 정보를 보여주고 클릭 시 저장.
  private func fileRow(_ attachment: KakaoAttachment) -> some View {
    Button {
      Task { await save(attachment) }
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "doc.fill")
          .foregroundStyle(isMine ? Color.white.opacity(0.9) : Color.secondary)
        VStack(alignment: .leading, spacing: 1) {
          Text(attachment.originalName ?? attachment.id)
            .lineLimit(1)
            .foregroundStyle(isMine ? Color.white : Color.primary)
          Text(fileInfo(attachment))
            .font(.caption2)
            .foregroundStyle(isMine ? Color.white.opacity(0.75) : Color.secondary)
        }
        Spacer()
        Image(systemName: "arrow.down.circle")
          .foregroundStyle(isMine ? Color.white.opacity(0.9) : Color.secondary)
      }
      .padding(10)
      .frame(maxWidth: 300, alignment: .leading)
      .background(Color.black.opacity(isMine ? 0.12 : 0.05))
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .buttonStyle(.plain)
    .help("파일 저장")
  }

  private func fileInfo(_ attachment: KakaoAttachment) -> String {
    var parts: [String] = []
    if let ext = attachment.originalName?.split(separator: ".").last, !ext.isEmpty {
      parts.append(ext.uppercased())
    } else if let mime = attachment.mimeType {
      parts.append(mime)
    }
    if let bytes = attachment.byteSize {
      parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
    }
    return parts.joined(separator: " · ")
  }

  private func save(_ attachment: KakaoAttachment) async {
    guard let resolved = try? await resolveAttachment(attachment) else { return }
    let panel = NSSavePanel()
    panel.title = "파일 저장"
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = attachment.originalName ?? resolved.fileURL.lastPathComponent
    if panel.runModal() == .OK, let destination = panel.url {
      try? FileManager.default.copyItem(at: resolved.fileURL, to: destination)
    }
  }
}

// 비동기 해석 후 썸네일을 그리는 뷰.
private struct ThumbnailImage: View {
  let attachment: KakaoAttachment
  let resolveAttachment: (KakaoAttachment) async throws -> ResolvedAttachment
  @State private var image: NSImage?
  @State private var failed = false

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image).resizable().scaledToFill()
      } else if failed {
        ZStack {
          Color.secondary.opacity(0.15)
          Image(systemName: "photo").font(.title).foregroundStyle(.secondary)
        }
      } else {
        ZStack {
          Color.secondary.opacity(0.15)
          ProgressView().controlSize(.small)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .clipped()
    .task {
      if image == nil, !failed {
        await load()
      }
    }
  }

  private func load() async {
    do {
      let resolved = try await resolveAttachment(attachment)
      if let nsImage = NSImage(contentsOf: resolved.fileURL) {
        image = nsImage
      } else {
        failed = true
      }
    } catch {
      failed = true
    }
  }
}

// MARK: - 이미지/파일 미리보기 시트

private struct AttachmentPreviewView: View {
  let item: PreviewItem
  @Environment(\.dismiss) private var dismiss
  @State private var scale: CGFloat = 1
  @State private var pan: CGSize = .zero
  @State private var ocrText: String?
  @State private var showingOCR = false
  @State private var isOCRInProgress = false
  @State private var hoveringImage = false
  @State private var ocrDidRun = false
  @State private var ocrBoxes: [OCRBox] = []
  @State private var escMonitor: Any?

  private static let maxScale: CGFloat = 2
  private static let minScale: CGFloat = 1

  private var nsImage: NSImage? {
    item.kind == .image ? NSImage(contentsOf: item.url) : nil
  }

  var body: some View {
    VStack(spacing: 16) {
      Text(item.name).font(.headline)
      if item.kind == .image {
        if let image = nsImage {
          // 휠 줌 + 드래그 패닝을 AppKit 뷰로 처리한다.
          ZoomableImageView(
            image: image,
            scale: $scale,
            offset: $pan,
            maxScale: Self.maxScale
          )
          .frame(width: 640, height: 460)
          .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          .overlay {
            // 마우스를 올리면 자동으로 텍스트를 인식하고, 원래 위치 위에 텍스트를 얹어
            // 이미지 위에서 직접 드래그 선택/복사할 수 있게 한다.
            if hoveringImage, !ocrBoxes.isEmpty {
              OCRTextOverlay(
                boxes: ocrBoxes, imageSize: image.size, scale: scale, offset: pan,
                containerSize: CGSize(width: 640, height: 460))
            }
          }
          .onHover { hovering in
            hoveringImage = hovering
            if hovering && !ocrDidRun && !isOCRInProgress {
              ocrDidRun = true
              Task { await performOCR(silent: true) }
            }
          }
          // 확대 시 보이는 영역에 맞춰 다시 OCR한다.
          .onChange(of: scale) {
            if hoveringImage && !isOCRInProgress {
              Task { await performOCR(silent: true) }
            }
          }
        } else {
          Label("이미지를 불러올 수 없습니다", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
            .frame(maxHeight: 460)
        }
      } else {
        VStack(spacing: 8) {
          Image(systemName: "doc.fill").font(.system(size: 48)).foregroundStyle(.secondary)
          Text(item.name).font(.callout)
        }
        .frame(maxHeight: 460)
      }
      HStack {
        if item.kind == .image {
          Text("\(Int(scale * 100))%").font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button("100%") { resetZoom() }
          if isOCRInProgress {
            ProgressView().controlSize(.small)
          } else {
            Button("텍스트 인식") { Task { await performOCR() } }
          }
        } else {
          Spacer()
        }
        Button("닫기") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("저장…") { save() }
          .buttonStyle(.borderedProminent)
      }
    }
    .padding(24)
    .frame(width: 680, height: 560)
    .onAppear { installEscMonitor() }
    .onDisappear { removeEscMonitor() }
    .sheet(isPresented: $showingOCR) {
      OCRResultView(item: item, text: ocrText ?? "")
    }
  }

  // SwiftUI sheet에서 esc(keyboardShortcut/.onExitCommand)가 안 먹는 문제가 있어,
  // AppKit 로컬 키 이벤트 모니터로 esc를 확실히 캐치해 시트를 닫는다.
  private func installEscMonitor() {
    guard escMonitor == nil else { return }
    escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      if event.keyCode == 53 {  // esc
        if showingOCR {
          showingOCR = false
        } else {
          dismiss()
        }
        return nil
      }
      return event
    }
  }

  private func removeEscMonitor() {
    if let monitor = escMonitor {
      NSEvent.removeMonitor(monitor)
      escMonitor = nil
    }
  }

  // Apple Vision 프레임워크로 이미지 텍스트를 인식한다(온디바이스, 네트워크 불필요).
  // silent=true면(호버 시) 시트를 띄우지 않고 text만 채운다.
  // 줌 상태(scale>1)에서는 화면에 보이는 영역을 잘라 그 위에서 다시 OCR한다.
  private func performOCR(silent: Bool = false) async {
    guard let image = nsImage else {
      ocrText = nil
      if !silent { showingOCR = true }
      return
    }
    isOCRInProgress = true
    defer { isOCRInProgress = false }

    let sourcePx = CGSize(width: image.size.width, height: image.size.height)
    var cropOrigin: CGPoint?
    var cropPixels: CGSize?
    let workingImage: NSImage
    if scale > 1.01, let crop = visibleCropImage(from: image) {
      workingImage = crop
      cropOrigin = visibleCropOrigin()
      cropPixels = CGSize(width: crop.size.width, height: crop.size.height)
    } else {
      workingImage = image
    }
    guard let cgImage = workingImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      return
    }

    let request = VNRecognizeTextRequest { request, error in
      guard error == nil else { return }
      let observations = request.results as? [VNRecognizedTextObservation] ?? []
      var boxes: [OCRBox] = []
      for obs in observations {
        guard let candidate = obs.topCandidates(1).first else { continue }
        var rect = obs.boundingBox
        // crop 영역에서 OCR한 경우 → 전체 이미지 Vision 좌표로 되돌린다.
        if let origin = cropOrigin, let pixels = cropPixels {
          rect = Self.mapCropBox(
            rect, cropOrigin: origin, cropPixels: pixels, sourcePixels: sourcePx)
        }
        boxes.append(OCRBox(text: candidate.string, normalizedRect: rect))
      }
      let joined = boxes.map(\.text).joined(separator: "\n")
      Task { @MainActor in
        ocrText = joined.isEmpty ? nil : joined
        ocrBoxes = joined.isEmpty ? [] : boxes
        if !silent { showingOCR = true }
      }
    }
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    // 한국어/영어를 함께 인식한다(기본은 영어뿐이라 한글 텍스트가 누락될 수 있다).
    request.recognitionLanguages = ["ko-KR", "en-US"]
    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    try? handler.perform([request])
  }

  // 줌 상태에서 화면에 보이는 이미지 영역의 origin(전체 이미지 픽셀 좌표, 좌상단 원점).
  private func visibleCropOrigin() -> CGPoint? {
    guard let image = nsImage else { return nil }
    let container = CGSize(width: 640, height: 460)
    let available = CGRect(x: 12, y: 12, width: container.width - 24, height: container.height - 24)
    let fitW =
      (image.size.width > 0)
      ? min(available.width / image.size.width, available.height / image.size.height)
        * image.size.width : available.width
    let fitH =
      (image.size.height > 0)
      ? min(available.width / image.size.width, available.height / image.size.height)
        * image.size.height : available.height
    guard fitW > 0, fitH > 0, scale > 0 else { return nil }
    let uHalf = (available.width / 2) / (fitW * scale)
    let vHalf = (available.height / 2) / (fitH * scale)
    let uCenter = 0.5 - pan.width / (fitW * scale)
    let vCenter = 0.5 - pan.height / (fitH * scale)
    let uMin = max(0, uCenter - uHalf)
    let vMin = max(0, vCenter - vHalf)
    return CGPoint(x: uMin * image.size.width, y: vMin * image.size.height)
  }

  private func visibleCropSize() -> CGSize? {
    guard let image = nsImage else { return nil }
    let container = CGSize(width: 640, height: 460)
    let availableW = container.width - 24
    let availableH = container.height - 24
    let fitW =
      (image.size.width > 0)
      ? min(availableW / image.size.width, availableH / image.size.height) * image.size.width
      : availableW
    let fitH =
      (image.size.height > 0)
      ? min(availableW / image.size.width, availableH / image.size.height) * image.size.height
      : availableH
    guard fitW > 0, fitH > 0, scale > 0 else { return nil }
    let uHalf = (availableW / 2) / (fitW * scale)
    let vHalf = (availableH / 2) / (fitH * scale)
    let uCenter = 0.5 - pan.width / (fitW * scale)
    let vCenter = 0.5 - pan.height / (fitH * scale)
    let uMin = max(0, uCenter - uHalf)
    let vMin = max(0, vCenter - vHalf)
    let uMax = min(1, uCenter + uHalf)
    let vMax = min(1, vCenter + vHalf)
    return CGSize(
      width: max(1, (uMax - uMin) * image.size.width),
      height: max(1, (vMax - vMin) * image.size.height))
  }

  // 눈에 보이는 영역을 잘라낸 해상도 이미지를 만든다.
  private func visibleCropImage(from image: NSImage) -> NSImage? {
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let origin = visibleCropOrigin(), let size = visibleCropSize()
    else { return nil }
    let rect = CGRect(origin: origin, size: size)
    guard rect.maxX <= CGFloat(cg.width), rect.maxY <= CGFloat(cg.height), rect.minX >= 0,
      rect.minY >= 0
    else { return nil }
    guard let cropped = cg.cropping(to: rect) else { return nil }
    return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
  }

  // crop의 Vision 좌표 → 전체 이미지 Vision(좌하단) 좌표로 변환.
  private static func mapCropBox(
    _ box: CGRect, cropOrigin: CGPoint, cropPixels: CGSize, sourcePixels: CGSize
  ) -> CGRect {
    guard cropPixels.width > 0, cropPixels.height > 0, sourcePixels.width > 0,
      sourcePixels.height > 0
    else { return box }
    // crop 내 Vision(bottom-left) → crop 내 픽셀(좌상단).
    let px = cropOrigin.x + box.minX * cropPixels.width
    let topY = cropOrigin.y + cropPixels.height - (box.minY + box.height) * cropPixels.height
    let w = box.width * cropPixels.width
    let h = box.height * cropPixels.height
    // 전체 이미지 픽셀 → 전체 Vision(bottom-left) 정규화.
    let nX = px / sourcePixels.width
    let nBottom = 1 - (topY + h) / sourcePixels.height
    return CGRect(x: nX, y: nBottom, width: w / sourcePixels.width, height: h / sourcePixels.height)
  }

  private func truncated(_ text: String) -> String {
    text.split(separator: "\n").first.map(String.init) ?? text
  }

  private func copy(_ value: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(value, forType: .string)
  }

  private func resetZoom() {
    withAnimation(.easeInOut(duration: 0.2)) {
      scale = 1
      pan = .zero
    }
  }

  private func save() {
    let panel = NSSavePanel()
    panel.title = "첨부 저장"
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = item.name
    if panel.runModal() == .OK, let destination = panel.url {
      try? FileManager.default.copyItem(at: item.url, to: destination)
    }
  }
}

private struct OCRBox: Identifiable, Equatable {
  let id = UUID()
  let text: String
  let normalizedRect: CGRect  // Vision 좌표(좌하단 원점, 0~1)
}

// 이미지 위에 텍스트를 실제 위치에 겹쳐, 드래그로 선택·복사할 수 있게 하는 오버레이.
// zoom(scale/offset)을 반영해 이미지를 확대/이동해도 텍스트 위치가 함께 따라간다.
private struct OCRTextOverlay: View {
  let boxes: [OCRBox]
  let imageSize: CGSize
  let scale: CGFloat
  let offset: CGSize
  let containerSize: CGSize

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .topLeading) {
        Color.clear
        ForEach(boxes) { box in
          let rect = zoomed(mapped(box.normalizedRect))
          Text(box.text)
            .font(.system(size: rect.height * 0.9))
            .foregroundStyle(Color.black.opacity(0.0))  // 투명하지만 선택/복사 가능
            .textSelection(.enabled)
            .padding(.horizontal, 2)
            .background(Color.white.opacity(0.55))
            .position(x: rect.midX, y: rect.midY)
        }
      }
    }
  }

  // 가로/세로 여백 12씩 제외한 이미지 영역(PreviewZoomView.draw와 동일).
  private var available: CGRect {
    CGRect(
      x: 12, y: 12,
      width: max(0, containerSize.width - 24),
      height: max(0, containerSize.height - 24))
  }

  // 이미지를 available 안에 aspectFit으로 놓았을 때(scale=1)의 rect.
  private func fittedRect(in container: CGRect) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0 else { return container }
    let s = min(container.width / imageSize.width, container.height / imageSize.height)
    let w = imageSize.width * s
    let h = imageSize.height * s
    return CGRect(
      x: container.midX - w / 2, y: container.midY - h / 2, width: w, height: h)
  }

  // Vision(좌하단 원점, 0~1) → scale=1 표시 좌표(y 뒤집음).
  private func mapped(_ r: CGRect) -> CGRect {
    let fitted = fittedRect(in: available)
    let x = fitted.minX + r.minX * fitted.width
    let y = fitted.minY + (1 - r.maxY) * fitted.height
    let w = r.width * fitted.width
    let h = r.height * fitted.height
    return CGRect(x: x, y: y, width: w, height: h)
  }

  // 이미지 중심 기준 zoom(scale) 후 offset으로 패닝 — PreviewZoomView와 동일 변환.
  private func zoomed(_ r: CGRect) -> CGRect {
    let center = CGPoint(x: available.midX, y: available.midY)
    func x(_ v: CGFloat) -> CGFloat { center.x + (v - center.x) * scale + offset.width }
    func y(_ v: CGFloat) -> CGFloat { center.y + (v - center.y) * scale + offset.height }
    return CGRect(
      x: x(r.minX), y: y(r.minY),
      width: r.width * scale, height: r.height * scale)
  }
}

// 이미지에서 인식한 전체 텍스트를 시트로 보여주는 뷰.
private struct OCRResultView: View {
  let item: PreviewItem
  let text: String
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("이미지에서 인식한 텍스트").font(.title3.bold())
        Spacer()
        Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      if text.isEmpty {
        ContentUnavailableView(
          "인식된 텍스트가 없습니다", systemImage: "text.viewfinder",
          description: Text("이미지에 텍스트가 없거나 선명하지 않을 수 있습니다."))
      } else {
        ScrollView {
          Text(text)
            .font(.body.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        HStack {
          Spacer()
          Button("복사") { copy(text) }
            .buttonStyle(.borderedProminent)
        }
      }
    }
    .padding(20)
    .frame(width: 520, height: 420)
  }

  private func copy(_ value: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(value, forType: .string)
  }
}

// 휠로 줌(1~2배), 줌 상태에서 드래그로 패닝하는 AppKit 이미지 뷰.
private struct ZoomableImageView: NSViewRepresentable {
  let image: NSImage
  @Binding var scale: CGFloat
  @Binding var offset: CGSize
  let maxScale: CGFloat

  func makeNSView(context: Context) -> PreviewZoomView {
    let view = PreviewZoomView()
    view.image = image
    view.maxScale = maxScale
    view.onTransformChange = { s, o in
      scale = s
      offset = o
    }
    view.scale = scale
    view.offset = offset
    return view
  }

  func updateNSView(_ nsView: PreviewZoomView, context: Context) {
    nsView.image = image
    nsView.maxScale = maxScale
    nsView.onTransformChange = { s, o in
      scale = s
      offset = o
    }
    nsView.scale = scale
    nsView.offset = offset
    nsView.needsDisplay = true
  }
}

final class PreviewZoomView: NSView {
  var image: NSImage? {
    didSet { needsDisplay = true }
  }
  var maxScale: CGFloat = 2
  var scale: CGFloat = 1
  var offset: CGSize = .zero
  var onTransformChange: ((CGFloat, CGSize) -> Void)?
  private var dragStart: CGPoint?
  private var dragOrigin: CGSize = .zero

  override var isFlipped: Bool { false }

  override func draw(_ dirtyRect: NSRect) {
    guard let image else { return }
    NSColor.black.withAlphaComponent(0.02).setFill()
    dirtyRect.fill()
    // fit 크기로 놓은 뒤, 뷰 중심을 기준으로 zoom(scale)하고 offset으로 패닝한다.
    let available = bounds.insetBy(dx: 12, dy: 12)
    let fit = image.size.aspectFit(in: available.size)
    let base = CGRect(
      x: available.midX - fit.width / 2,
      y: available.midY - fit.height / 2,
      width: fit.width,
      height: fit.height
    )
    let center = CGPoint(x: available.midX, y: available.midY)
    let transform = CGAffineTransform(
      translationX: center.x + offset.width, y: center.y + offset.height
    )
    .scaledBy(x: scale, y: scale)
    .translatedBy(x: -base.midX, y: -base.midY)
    image.draw(in: base.applying(transform))
  }

  override func scrollWheel(with event: NSEvent) {
    // 정밀/비정밀 휠 모두 한 칸당 0.1단계로 줌.
    let step: CGFloat = event.hasPreciseScrollingDeltas ? 0.1 : 0.2
    let delta = event.scrollingDeltaY < 0 ? -step : step
    let newScale = min(max(scale + delta, 1), maxScale)
    if newScale <= 1.0 { offset = .zero }
    scale = newScale
    onTransformChange?(scale, offset)
    needsDisplay = true
  }

  override func mouseDown(with event: NSEvent) {
    dragStart = convert(event.locationInWindow, from: nil)
    dragOrigin = offset
  }

  override func mouseDragged(with event: NSEvent) {
    guard scale > 1.01, let start = dragStart else { return }
    let point = convert(event.locationInWindow, from: nil)
    let dx = point.x - start.x
    let dy = point.y - start.y
    offset = CGSize(width: dragOrigin.width + dx, height: dragOrigin.height + dy)
    onTransformChange?(scale, offset)
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    dragStart = nil
  }
}

private extension CGSize {
  func aspectFit(in container: CGSize) -> CGSize {
    guard width > 0, height > 0 else { return .zero }
    let scale = min(container.width / width, container.height / height)
    return CGSize(width: width * scale, height: height * scale)
  }
}

// MARK: - 우클릭 컨텍스트 메뉴

private struct MessageContextMenu: View {
  let message: KakaoMessage
  let resolveAttachment: (KakaoAttachment) async throws -> ResolvedAttachment?
  let presentPreview: (PreviewItem) -> Void

  var body: some View {
    Group {
      if let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines),
        !text.isEmpty
      {
        Button("내용 복사") { copy(text) }
      }
      if !message.attachments.isEmpty {
        Divider()
        ForEach(message.attachments) { attachment in
          Button("\(attachment.kind == .image ? "이미지" : "파일") 저장") {
            Task { await save(attachment) }
          }
          if attachment.kind == .image {
            Button("미리보기") {
              Task { await previewImage(attachment) }
            }
          }
        }
      }
    }
  }

  private func copy(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  private func save(_ attachment: KakaoAttachment) async {
    guard let resolved = try? await resolveAttachment(attachment) else { return }
    let panel = NSSavePanel()
    panel.title = "첨부 저장"
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = attachment.originalName ?? resolved.fileURL.lastPathComponent
    if panel.runModal() == .OK, let destination = panel.url {
      try? FileManager.default.copyItem(at: resolved.fileURL, to: destination)
    }
  }

  private func previewImage(_ attachment: KakaoAttachment) async {
    guard let resolved = try? await resolveAttachment(attachment) else { return }
    presentPreview(
      PreviewItem(url: resolved.fileURL, name: attachment.originalName ?? "image", kind: .image))
  }
}

extension Notification.Name {
  static let scrollMessagesToBottom = Notification.Name("scrollMessagesToBottom")
}
