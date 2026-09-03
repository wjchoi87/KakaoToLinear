import KakaoLinearCore
import SwiftUI

struct RoomPickerView: View {
  @ObservedObject var state: AppState
  @State private var query = ""
  @State private var favoritesExpanded = true
  @State private var otherRoomsExpanded = true

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        Text("이슈를 만들 채팅방").font(.title2.bold())
        Text("업무 요청이 들어온 방을 선택하세요.").foregroundStyle(.secondary)
      }
      HStack {
        TextField("채팅방 검색", text: $query)
          .textFieldStyle(.roundedBorder)
          .onSubmit { Task { await state.loadRooms(query: query) } }
        Button("검색") { Task { await state.loadRooms(query: query) } }
      }
      if state.rooms.isEmpty, !state.isLoading {
        ContentUnavailableView(
          "표시할 채팅방이 없습니다",
          systemImage: "bubble.left.and.exclamationmark.bubble.right",
          description: Text("KakaoTalk 실행 상태와 Full Disk Access를 확인하세요.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List {
          accordion(
            isExpanded: $favoritesExpanded,
            label: Label("즐겨찾기 \(favoriteRooms.count)", systemImage: "star.fill"),
            content: {
              if favoriteRooms.isEmpty {
                Text("즐겨찾기한 채팅방이 없습니다.")
                  .font(.callout).foregroundStyle(.secondary)
                  .padding(.vertical, 8)
                  .padding(.leading, 28)
              } else {
                ForEach(favoriteRooms) { room in roomRow(room, favorite: true) }
              }
            })
          accordion(
            isExpanded: $otherRoomsExpanded,
            label: Label("다른 채팅방 \(otherRooms.count)", systemImage: "bubble.left.and.bubble.right"),
            content: {
              if otherRooms.isEmpty {
                Text("다른 채팅방이 없습니다.")
                  .font(.callout).foregroundStyle(.secondary)
                  .padding(.vertical, 8)
                  .padding(.leading, 28)
              } else {
                ForEach(otherRooms) { room in roomRow(room, favorite: false) }
              }
            })
        }
        .listStyle(.inset)
      }
    }
    .padding(20)
  }

  private var favoriteRooms: [KakaoRoom] {
    state.rooms.filter { state.favoriteRoomIds.contains($0.id) }
  }

  private var otherRooms: [KakaoRoom] {
    state.rooms.filter { !state.favoriteRoomIds.contains($0.id) }
  }

  private func roomRow(_ room: KakaoRoom, favorite: Bool) -> some View {
    HStack(spacing: 8) {
      Button {
        Task { await state.chooseRoom(room) }
      } label: {
        HStack(spacing: 12) {
          Image(systemName: "bubble.left.and.bubble.right.fill")
            .font(.title3).foregroundStyle(Color.accentColor)
          VStack(alignment: .leading, spacing: 4) {
            Text(room.title).font(.body.weight(.medium)).lineLimit(1)
            Text(room.lastMessage ?? "최근 메시지 없음")
              .font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
          Spacer()
          if let date = room.lastActivityAt {
            Text(date, style: .time).font(.caption).foregroundStyle(.secondary)
          }
          Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 5)
      }
      .buttonStyle(.plain)

      Button {
        Task { await state.toggleFavorite(room) }
      } label: {
        Image(systemName: favorite ? "star.fill" : "star")
          .foregroundStyle(favorite ? .yellow : .secondary)
          .frame(width: 28, height: 28)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(favorite ? "즐겨찾기 해제" : "즐겨찾기 추가")
      .help(favorite ? "즐겨찾기 해제" : "즐겨찾기 추가")
    }
    .contextMenu {
      Button(favorite ? "즐겨찾기 해제" : "즐겨찾기 추가") {
        Task { await state.toggleFavorite(room) }
      }
    }
  }

  // 접을 수 있는 그룹: 헤더 전체를 눌러도 토글되고, 토글 아이콘 우측에 여백을 둔다.
  private func accordion<Content: View, L: View>(
    isExpanded: Binding<Bool>,
    label: L,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        isExpanded.wrappedValue.toggle()
      } label: {
        HStack(spacing: 8) {
          Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 14, height: 14)
            .padding(.trailing, 6)
          label
            .font(.headline).foregroundStyle(.primary)
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 6)
      }
      .buttonStyle(.plain)
      .accessibilityHint(isExpanded.wrappedValue ? "접기" : "펼치기")

      if isExpanded.wrappedValue {
        content()
      }
    }
  }
}
