import Foundation

public enum MessageSelectionModifier: Equatable, Sendable {
  case none
  case command
  case shift
  case commandShift
}

public struct MessageSelectionResult: Equatable, Sendable {
  public let selectedIds: Set<String>
  public let anchorIndex: Int?

  public init(selectedIds: Set<String>, anchorIndex: Int?) {
    self.selectedIds = selectedIds
    self.anchorIndex = anchorIndex
  }
}

public enum MessageSelectionPolicy {
  /*
   변경 전 정책 - click은 modifier와 무관하게 toggle했고 Shift만 기존 선택에 range를 더했다.
   변경 후 정책 - plain click은 단일 선택, Command-click은 개별 추가/해제, Shift-click은 anchor range 선택, Command-Shift는 range 추가다.
   변경 이유 - macOS list의 익숙한 다중 선택 규칙으로 많은 Kakao message를 빠르고 예측 가능하게 선택하기 위해서다.
   영향 범위 - Message Picker row click selection에만 적용되며 CLI source selection에는 영향이 없다.
   */
  public static func apply(
    orderedIds: [String],
    current: Set<String>,
    anchorIndex: Int?,
    clickedIndex: Int,
    modifier: MessageSelectionModifier
  ) -> MessageSelectionResult {
    guard orderedIds.indices.contains(clickedIndex) else {
      return MessageSelectionResult(selectedIds: current, anchorIndex: anchorIndex)
    }
    let clickedId = orderedIds[clickedIndex]
    switch modifier {
    case .none:
      return MessageSelectionResult(selectedIds: [clickedId], anchorIndex: clickedIndex)
    case .command:
      var selected = current
      if selected.contains(clickedId) {
        selected.remove(clickedId)
      } else {
        selected.insert(clickedId)
      }
      return MessageSelectionResult(selectedIds: selected, anchorIndex: clickedIndex)
    case .shift, .commandShift:
      let start =
        anchorIndex.flatMap { orderedIds.indices.contains($0) ? $0 : nil }
        ?? clickedIndex
      let rangeIds = Set(orderedIds[min(start, clickedIndex)...max(start, clickedIndex)])
      let selected = modifier == .commandShift ? current.union(rangeIds) : rangeIds
      return MessageSelectionResult(selectedIds: selected, anchorIndex: start)
    }
  }
}
