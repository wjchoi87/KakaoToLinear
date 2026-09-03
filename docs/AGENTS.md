현재 구현된 AI 이슈 분석/정리 파이프라인을 먼저 전체적으로 확인한 뒤, 필요하다면 **2-pass 분석 구조**로 개선해줘.

무작정 내가 아래에 적은 구조로 덮어쓰지 말고, 현재 코드가 어떻게 동작하는지 먼저 파악하고 기존 구조/추상화/의도를 최대한 유지하면서 개선해야 한다.

## 1. 먼저 현재 구현 분석

다음 내용을 먼저 확인해.

* 선택된 Kakao 메시지가 AI에 어떤 형태로 전달되는지
* 이미지/첨부파일이 어떤 형태로 전달되는지
* 이미지 분석이 실제 vision input으로 들어가는지
* 문서는 어떻게 전처리되는지
* AIProvider / IssueComposer 등의 abstraction이 어떻게 구성되어 있는지
* 현재 AI 호출 횟수와 prompt 구성
* 현재 structured output schema
* IssueDraft 생성 과정
* revision 시 원본 SourceBundle을 다시 사용하는지
* attachment 분석 결과가 별도로 보존되는지
* reasoning/thinking 옵션 처리
* 실패/retry/fallback 처리
* 현재 테스트

현재 구현이 이미 아래 요구사항 일부를 만족한다면 중복 구현하지 말고 재사용해.

분석 후 최종 결과 보고에는 반드시:

1. 기존 구조
2. 문제점
3. 변경한 구조
4. 변경 이유

를 간단히 설명해.

---

# 2. 목표

현재 AI가 선택된 카톡 메시지와 이미지/파일을 한 번에 받아 바로 Linear IssueDraft를 생성하고 있다면 이를 기본적으로 다음 구조로 개선하고 싶다.

```text
Selected Kakao Messages
+ Images
+ Extracted Documents
        │
        ▼
[PASS 1: Evidence Analysis]
        │
        ▼
EvidenceAnalysis
        │
        ├───────────────┐
        │               │
        ▼               │
Original SourceBundle   │
        │               │
        └───────┬───────┘
                ▼
[PASS 2: Issue Synthesis]
                │
                ▼
IssueDraft
```

핵심은 **1차에서는 이슈를 작성하지 않고 증거/요구사항을 최대한 빠짐없이 추출**하고,

**2차에서 원본 SourceBundle + 1차 EvidenceAnalysis를 함께 보고 최종 IssueDraft를 작성**하는 것이다.

단순 요약 품질이 아니라 다음 문제를 해결하는 것이 목적이다.

* 이미지의 중요한 UI 정보 누락
* 여러 메시지 사이의 관계 누락
* "PC는 그대로", "모바일만" 같은 작은 scope/constraint 누락
* 요청자의 질문/답변 관계 누락
* 첨부 이미지와 카톡 텍스트 사이의 연결 누락
* 모델이 너무 빨리 결론을 내리면서 세부사항을 버리는 문제
* 요구사항과 AI의 추측이 섞이는 문제

---

# 3. PASS 1 — Evidence Analysis

1차 호출에서는 절대로 최종 Linear 이슈 문장을 작성하는 것이 목적이 아니다.

역할은:

> Senior Requirements Analyst + QA Analyst + UI/UX Evidence Analyst

로 둔다.

입력:

```text
SourceBundle
├─ selected messages
├─ resolved full-size images
├─ extracted document contents
└─ attachment metadata
```

이미지가 있으면 반드시 실제 vision input으로 전달해야 한다.

썸네일이 아닌 AttachmentResolver에서 확보한 full image를 사용한다.

AI 분석용으로 resize된 복사본을 사용해도 되지만 Linear에 첨부되는 원본 파일은 변경하지 않는다.

---

## EvidenceAnalysis schema

현재 프로젝트의 Codable/schema 구조에 맞게 구현하되 개념적으로 다음 정보를 포함해.

```ts
interface EvidenceAnalysis {
  facts: EvidenceFact[]

  requests: EvidenceRequest[]

  constraints: EvidenceConstraint[]

  conditions: EvidenceCondition[]

  exclusions: EvidenceExclusion[]

  ambiguities: EvidenceAmbiguity[]

  relationships: EvidenceRelationship[]

  attachmentInsights: AttachmentInsight[]

  overallConfidence?: number
}
```

각 evidence에는 가능하면 source reference를 유지해.

예:

```ts
interface EvidenceRequest {
  content: string
  sourceMessageIds: string[]
  attachmentIds?: string[]
  confidence: number
}
```

---

# 4. PASS 1에서 반드시 분석할 것

## 메시지

다음을 구분해서 추출한다.

* 명시된 사실
* 명시된 변경 요청
* 현재 동작
* 원하는 동작
* 적용 범위
* 제외 범위
* 조건
* 예외
* 요청자가 강조한 부분
* 질문과 답변
* 이전 메시지를 수정하거나 덮어쓰는 후속 메시지
* 구현 전에 확인해야 하는 모호한 사항

각 카톡 메시지를 독립적으로 요약하지 말고 대화 관계를 연결해야 한다.

예:

```text
A: 모바일에서만 변경해주세요
B: PC는 지금 그대로 두면 되죠?
A: 네
```

결과는 반드시:

```text
scope: mobile
exclusion: PC UI must remain unchanged
```

형태의 evidence로 남아야 한다.

---

# 5. 이미지 분석

이미지는 단순 caption 생성으로 끝내지 않는다.

각 이미지를 다음 관점으로 분석한다.

* 어떤 화면/기능인지
* 어떤 UI element가 중요한지
* 빨간 박스/화살표/원/밑줄 등의 annotation
* 이미지 내부 텍스트
* 에러 메시지
* 버튼/필드/레이아웃 위치
* 현재 UI 상태
* 메시지에서 언급한 "여기", "이 부분", "이 버튼" 등이 실제 어느 요소인지
* 이미지가 보여주는 현재 문제
* 이미지가 요구사항을 어떻게 보완하는지
* 이미지 하나만으로 확정할 수 없는 내용

예를 들어:

```text
메시지:
"여기 간격 좀 늘려주세요"

이미지:
하단 버튼과 위 영역 사이에 빨간 화살표 표시
```

Evidence는 단순히:

```text
"버튼이 있는 이미지"
```

가 아니라:

```text
첨부 이미지에서 하단 액션 버튼과 바로 위 UI 영역 사이의 세로 간격이
수정 대상으로 표시되어 있다.
```

수준으로 나와야 한다.

이미지와 텍스트가 충돌하면 임의로 결정하지 말고 ambiguity로 남긴다.

---

# 6. AttachmentInsight

첨부별 분석 결과를 반드시 보존해.

예:

```ts
interface AttachmentInsight {
  attachmentId: string
  type: "image" | "document" | "other"

  observations: string[]

  relatedMessageIds: string[]

  relatedRequests: string[]

  ambiguities: string[]

  confidence: number
}
```

이 정보는 최종 사용자 Review UI에서도 표시할 수 있게 한다.

사용자가:

> "이미지를 AI가 제대로 이해했는가?"

를 확인할 수 있어야 한다.

---

# 7. PASS 1 정책

PASS 1은 가능한 한 **정보 손실을 막는 것**이 목적이다.

다음 행동을 금지한다.

* 내용을 지나치게 압축
* 비슷해 보인다는 이유로 다른 요구사항 합치기
* 애매한 내용을 사실로 확정
* 구현 방식을 임의로 추가
* API/DB/CSS/컴포넌트 구조 등의 기술 구현 제안
* 이미지 내용을 대충 caption으로 처리

정보가 명확하지 않으면 ambiguity로 보존한다.

---

# 8. PASS 2 — Issue Synthesis

2차 호출 입력은 반드시:

```text
Original SourceBundle
+
EvidenceAnalysis
```

로 한다.

EvidenceAnalysis만 넣지 않는다.

1차 모델이 잘못 분석했을 가능성 때문에 최종 모델이 원문과 이미지를 다시 참조할 수 있어야 한다.

다만 token/image cost가 과도하게 증가하는 경우 현재 provider 특성과 비용을 검토해서 가장 합리적인 구조로 구현해.

이미지를 PASS 2에도 다시 넣는 것이 비용상 너무 비효율적이라면:

```text
원본 메시지
+ EvidenceAnalysis
+ AttachmentInsight
```

를 사용하되, 이 판단은 구현 후 이유를 보고해.

---

# 9. PASS 2 역할

PASS 2의 역할은:

> Senior Product / Requirements Analyst

최종 목적은 개발자가 실제 작업할 수 있는 Linear 이슈를 생성하는 것이다.

기존 IssueDraft schema를 최대한 유지하되 필요하면 확장해.

권장:

```ts
interface IssueDraft {
  title: string

  summary: string

  currentBehavior: string

  desiredBehavior: string

  requirements: string[]

  scope: string[]

  constraints: string[]

  acceptanceCriteria: string[]

  attachmentInsights: AttachmentInsight[]

  notes: string[]

  questions: string[]

  sourceMessageIds: string[]
}
```

현재 schema와 호환성을 깨뜨리지 않고 확장 가능한지 먼저 검토해.

---

# 10. PASS 2 작성 원칙

단순 요약하지 않는다.

최종 이슈가 최소한 다음 질문에 답할 수 있어야 한다.

* 어디를 수정하는가?
* 현재 무엇이 문제인가?
* 어떻게 변경되어야 하는가?
* 어느 플랫폼/화면/사용자/조건에 적용되는가?
* 변경하면 안 되는 부분은 무엇인가?
* 첨부 이미지는 무엇을 보여주는가?
* 완료 여부를 어떤 기준으로 판단하는가?
* 아직 사람에게 확인해야 하는 부분은 무엇인가?

---

# 11. Fact / Inference / Question 구분

모델의 추측을 requirement에 넣지 않는다.

정책:

```text
명시된 내용
→ requirement / scope / constraint

높은 확률의 해석
→ notes

확정 불가능
→ questions
```

Acceptance Criteria 역시 원문에 없는 새로운 요구사항을 만들어내지 않는다.

---

# 12. Revision 처리

현재 revision 구조도 확인해.

사용자가 Draft 이후:

```text
"PC 관련 내용은 빼고 태블릿도 포함해."
```

같은 instruction을 입력하면 다음을 사용한다.

```text
Original SourceBundle
+ EvidenceAnalysis
+ Current IssueDraft
+ User Revision Instruction
```

원본 SourceBundle을 제거하지 않는다.

사용자의 최신 instruction은 높은 우선순위를 갖지만, 원본과 충돌하는 경우 무조건 덮어쓰지 말고 필요하면 conflict/confirmation을 표시한다.

revision 시 PASS 1을 매번 다시 호출할 필요는 없다.

기본:

```text
PASS 1 EvidenceAnalysis reuse
        ↓
PASS 2 revise
```

단 사용자가:

```text
"사진 다시 분석해"
"첨부파일 기준으로 다시 봐"
```

처럼 evidence 자체를 수정하도록 요구한 경우에는 PASS 1부터 다시 실행할 수 있는 구조로 만들어.

---

# 13. Thinking / Reasoning 정책

현재 provider에서 thinking/reasoning 설정이 어떻게 되어 있는지 확인해.

무조건 thinking을 켜지 않는다.

권장 기본:

```text
PASS 1
→ non-thinking

PASS 2
→ non-thinking
```

다만 다음 상황에서는 escalation 가능하게 설계해.

* ambiguity가 많음
* attachment 수가 많음
* 이미지가 복잡함
* 문서 + 이미지 + 대화가 동시에 있음
* confidence가 낮음
* PASS 1 결과 validation 실패
* 사용자가 상세 분석 요청

이 경우:

```text
thinking enabled
```

또는 향후 stronger model fallback을 넣기 쉽게 AIProvider abstraction을 유지해.

현재 단계에서 과도한 자동 모델 routing까지 만들 필요는 없다.

---

# 14. Structured Output Validation

두 PASS 모두 반드시 schema validation을 거친다.

```text
AI response
→ parse
→ schema validate
→ semantic sanity check
```

예:

* sourceMessageId가 실제 SourceBundle에 존재하는가
* attachmentId가 실제 attachment인가
* confidence 범위가 정상인가
* title이 빈 문자열인가
* requirement가 전부 비어있는가

validation 실패 시 현재 retry 구조와 통합해 1회 정도 repair/retry할 수 있도록 해.

무한 retry 금지.

---

# 15. Traceability

최종 requirement가 어디서 나왔는지 추적 가능하게 만드는 것이 중요하다.

가능하다면 내부 모델에서:

```ts
Requirement {
  content: string
  sourceMessageIds: string[]
  attachmentIds: string[]
}
```

처럼 provenance를 유지하고,

최종 Linear Markdown 변환 시에는 기존 UI/형식을 해치지 않는 범위에서 활용해.

사용자에게 반드시 모든 ID를 보여줄 필요는 없지만 내부적으로 추적 가능해야 한다.

---

# 16. 비용/성능

2-pass로 바꾸면서 무식하게 token/image cost를 두 배로 만들지 않는다.

확인할 것:

* 동일 이미지 중복 전송 여부
* document extraction 결과 caching
* EvidenceAnalysis caching
* SourceBundle hash
* revision 시 PASS 1 재사용
* 같은 source 재정리 시 evidence 재사용

예:

```text
sourceHash
→ EvidenceAnalysis cache
```

SourceBundle이 바뀌지 않았다면 PASS 1 결과 재사용 가능.

---

# 17. 테스트

최소 다음 케이스를 추가해.

## Case 1 — 단순 텍스트

```text
모바일 버튼 아래로 내려주세요.
PC는 그대로입니다.
```

기대:

```text
scope = mobile
constraint = PC unchanged
```

---

## Case 2 — 질문/답변

```text
A: 모바일만인가요?
B: 네 PC는 수정 안합니다.
```

후속 답변을 요구사항에 반영.

---

## Case 3 — 이미지 + "여기"

```text
"여기 간격 늘려주세요"
+ annotated image
```

이미지의 표시 영역 분석이 AttachmentInsight에 있어야 한다.

---

## Case 4 — 충돌

```text
초기:
PC/모바일 모두 변경

후속:
아 PC는 기존대로 놔주세요
```

후속 instruction이 최종 constraint에 반영.

---

## Case 5 — 모호한 요청

```text
"이거 좀 이상한데 수정해주세요"
```

임의 requirement 생성 금지.

question 또는 ambiguity 발생.

---

## Case 6 — revision

초기 Draft 후:

```text
"버튼 색 얘기는 빼."
```

SourceBundle / EvidenceAnalysis는 유지하면서 Draft만 정상 수정.

---

# 18. 구현 시 주의

이번 작업의 핵심은 "AI 호출을 무조건 두 번 만드는 것"이 아니다.

핵심은:

```text
Evidence extraction
→ Requirement synthesis
```

책임을 분리하여 분석 품질과 정보 보존율을 높이는 것이다.

현재 구조상 이미 비슷한 단계가 있다면 그것을 확장/정리해도 된다.

불필요한 abstraction, 과도한 framework, premature optimization은 만들지 마.

기존 CLI/Core-first 철학도 유지해야 한다.

GUI에 AI 분석 로직을 넣지 않는다.

```text
KakaoLinearCore
        ↓
EvidenceAnalyzer
        ↓
IssueComposer
```

형태로 Core에서 완결되게 한다.

CLI에서도 가능해야 한다.

권장 command는 현재 CLI 설계와 자연스럽게 맞춰서 추가/변경해.

예:

```bash
kakao-linear analyze --source src_x
kakao-linear compose --source src_x
```

또는 compose가 내부적으로 analyze를 수행해도 된다.

단 디버깅/자동화를 위해 EvidenceAnalysis를 JSON으로 확인할 방법은 있어야 한다.

예:

```bash
kakao-linear analyze --source src_x --json
```

---

# 19. 완료 후 보고

작업 완료 후 다음만 명확하게 보고해.

1. 기존 AI 파이프라인이 어떻게 되어 있었는지
2. 어떤 문제를 발견했는지
3. 실제로 2-pass가 필요한 구조였는지
4. 최종 변경된 데이터 흐름
5. 새로 추가/변경한 주요 타입과 파일
6. 이미지 분석이 PASS 1에서 어떻게 처리되는지
7. revision 시 EvidenceAnalysis 재사용 방식
8. cache / token 절감 방식
9. 테스트 결과
10. 남아 있는 한계

실제 코드를 확인하지 않고 추측해서 수정하지 말고, 반드시 현재 구현부터 분석한 뒤 작업해.

