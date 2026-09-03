#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
output_dir="${1:-$project_dir/dist}"
mkdir -p "$output_dir"
staging_dir=$(mktemp -d "$output_dir/.kakaotolinear-build.XXXXXX")
app_dir="$staging_dir/KakaoToLinear.app"
contents_dir="$app_dir/Contents"
final_app="$output_dir/KakaoToLinear.app"
previous_app="$output_dir/KakaoToLinear.previous.app"

delete_generated_tree() {
  local target="$1"
  if [[ -d "$target" ]]; then
    find "$target" -depth -type f -delete
    find "$target" -depth -type l -delete
    find "$target" -depth -type d -empty -delete
  fi
}

cleanup_staging() {
  delete_generated_tree "$staging_dir"
}
trap cleanup_staging EXIT

cd "$project_dir"
swift build -c release --product KakaoLinearApp

mkdir -p "$contents_dir/MacOS" "$contents_dir/Frameworks"
cp "$project_dir/.build/release/KakaoLinearApp" "$contents_dir/MacOS/KakaoToLinearApp"
cp "$project_dir/Resources/KakaoLinearApp-Info.plist" "$contents_dir/Info.plist"

framework_path=$(find "$project_dir/.build" -path '*/release/SQLCipher.framework' -type d -print -quit)
if [[ -n "$framework_path" ]]; then
  cp -R "$framework_path" "$contents_dir/Frameworks/SQLCipher.framework"
  chmod -R u+w "$contents_dir/Frameworks/SQLCipher.framework"
  codesign --force --sign - "$contents_dir/Frameworks/SQLCipher.framework"
fi

# Sparkle 자동 업데이트 프레임워크를 번들에 포함한다 (SPM 빌드 산출물에서).
sparkle_framework=$(find "$project_dir/.build" -path '*/release/Sparkle.framework' -type d -print -quit 2>/dev/null)
if [[ -n "$sparkle_framework" ]]; then
  cp -R "$sparkle_framework" "$contents_dir/Frameworks/Sparkle.framework"
  chmod -R u+w "$contents_dir/Frameworks/Sparkle.framework"
  codesign --force --sign - "$contents_dir/Frameworks/Sparkle.framework"
fi

chmod 755 "$contents_dir/MacOS/KakaoToLinearApp"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$contents_dir/MacOS/KakaoToLinearApp"
codesign --force --deep --sign - "$app_dir"

if [[ -e "$final_app" ]]; then
  delete_generated_tree "$previous_app"
  mv "$final_app" "$previous_app"
fi
mv "$app_dir" "$final_app"
rmdir "$staging_dir"
echo "$final_app"