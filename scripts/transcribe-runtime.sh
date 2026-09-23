#!/bin/bash
# CTranscribe.framework — runtime transcribe.cpp, общий для локальной и релизной упаковки.
#
# SwiftPM binaryTarget нужен линкеру во время сборки, но Cribe.app собирается вручную.
# Поэтому xcodebuild НЕ копирует CTranscribe.framework в наш dist/Cribe.app автоматически.
# Если забыть этот шаг, Mach-O успешно собирается и подписывается, но dyld завершает
# приложение на старте: @rpath/CTranscribe.framework/... не находится.

transcribe_framework_path() {
  local found

  found=$(find .ddata/Build/Products -type d -name CTranscribe.framework -print -quit 2>/dev/null || true)
  if [ -n "$found" ]; then
    printf '%s' "$found"
    return
  fi

  found=$(find .ddata/SourcePackages/artifacts .build/artifacts     -type d -name CTranscribe.framework -print -quit 2>/dev/null || true)
  printf '%s' "$found"
}

embed_transcribe() {
  local app="$1" framework
  framework=$(transcribe_framework_path)
  if [ -z "$framework" ]; then
    printf 'ОШИБКА: не нашёл CTranscribe.framework после сборки.\n' >&2
    printf '        Binary target transcribe.cpp разрешился для линкера, но runtime framework не найден.\n' >&2
    return 1
  fi

  mkdir -p "$app/Contents/Frameworks"
  rm -rf "$app/Contents/Frameworks/CTranscribe.framework"
  ditto "$framework" "$app/Contents/Frameworks/CTranscribe.framework"

  local binary="$app/Contents/MacOS/Cribe"
  if ! otool -l "$binary" | grep -q '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath @executable_path/../Frameworks "$binary"
  fi

  printf 'CTranscribe: %s → Contents/Frameworks\n' "$framework"
}

sign_transcribe() {
  local app="$1" identity="$2" timestamp_flag="$3"
  local framework="$app/Contents/Frameworks/CTranscribe.framework"
  [ -d "$framework" ] || {
    printf 'ОШИБКА: в бандле нет CTranscribe.framework\n' >&2
    return 1
  }

  codesign --force --options runtime "$timestamp_flag" --sign "$identity" "$framework"
}
