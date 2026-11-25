#!/bin/zsh
# Homebrew tap의 Casks/kakaotolinear.rb를 <버전>의 릴리스 zip으로 갱신하고 push한다.
#
# 사용법:
#   ./scripts/update-homebrew-cask.sh <버전>      # dist/KakaoToLinear-<버전>.zip의 sha256 사용
#   DRY_RUN=1 ./scripts/update-homebrew-cask.sh <버전>   # cask만 출력하고 commit/push 생략
#
# 환경변수: HOMEBREW_TAP_REPO (기본 wjchoi87/homebrew-tap)
# 설치: brew install --cask wjchoi87/tap/kakaotolinear

set -euo pipefail

VERSION="${1:?사용법: ./scripts/update-homebrew-cask.sh <버전> (예: 0.5.0)}"
project_dir="${0:A:h:h}"
ZIP="$project_dir/dist/KakaoToLinear-$VERSION.zip"
TAP_REPO="${HOMEBREW_TAP_REPO:-wjchoi87/homebrew-tap}"

[[ -f "$ZIP" ]] || { echo "$ZIP 이 없습니다. release.sh로 먼저 릴리스 zip을 만드세요." >&2; exit 1; }
SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')

work=$(mktemp -d "${TMPDIR:-/tmp}/kakaotolinear-tap.XXXXXX")
cleanup_work() {
  find "$work" -depth -type f -delete
  find "$work" -depth -type l -delete
  find "$work" -depth -type d -empty -delete
}
trap cleanup_work EXIT

gh repo clone "$TAP_REPO" "$work/tap" -- --quiet --depth 1
cask="$work/tap/Casks/kakaotolinear.rb"
mkdir -p "${cask:h}"

cat > "$cask" <<RUBY
cask "kakaotolinear" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/wjchoi87/KakaoToLinear/releases/download/v#{version}/KakaoToLinear-#{version}.zip"
  name "KakaoToLinear"
  desc "Turn selected KakaoTalk messages into Linear issues with AI"
  homepage "https://github.com/wjchoi87/KakaoToLinear"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "KakaoToLinear.app"
  binary "#{appdir}/KakaoToLinear.app/Contents/MacOS/kakao-linear"

  zap trash: [
    "~/Library/Application Support/KakaoToLinear",
    "~/Library/Caches/com.kakaotolinear.app",
    "~/Library/HTTPStorages/com.kakaotolinear.app",
    "~/Library/Preferences/com.kakaotolinear.app.plist",
  ]
end
RUBY

if command -v brew >/dev/null 2>&1; then
  brew style "$cask"
fi

cd "$work/tap"
if git ls-files --error-unmatch Casks/kakaotolinear.rb >/dev/null 2>&1 \
  && git diff --quiet -- Casks/kakaotolinear.rb; then
  echo "kakaotolinear cask가 이미 $VERSION 입니다. 변경 없음."
  exit 0
fi

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  cat "$cask"
  echo ">>> DRY_RUN: $TAP_REPO commit/push 생략"
  exit 0
fi

git add Casks/kakaotolinear.rb
git commit -q -m "kakaotolinear $VERSION"
git push -q origin HEAD
echo ">>> $TAP_REPO: kakaotolinear $VERSION (sha256 $SHA)"
