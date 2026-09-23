#!/bin/bash
# Проверка именно ГОТОВОГО app bundle, а не build directory.
set -euo pipefail

APP="${1:-dist/Cribe.app}"
MODE="${2:-}"
BIN="$APP/Contents/MacOS/Cribe"

fail() {
  printf 'ОШИБКА runtime-проверки: %s\n' "$*" >&2
  exit 1
}

[ -d "$APP" ] || fail "нет app bundle: $APP"
[ -x "$BIN" ] || fail "нет исполняемого файла: $BIN"

missing=0
while IFS= read -r dep; do
  case "$dep" in
    @rpath/*.framework/*)
      rel="${dep#@rpath/}"
      framework="${rel%%/*}"
      if [ ! -d "$APP/Contents/Frameworks/$framework" ]; then
        printf 'НЕ ХВАТАЕТ: %s (нужен %s/Contents/Frameworks/%s)\n'           "$dep" "$APP" "$framework" >&2
        missing=1
      fi
      ;;
    @executable_path/../Frameworks/*.framework/*)
      rel="${dep#@executable_path/../Frameworks/}"
      framework="${rel%%/*}"
      if [ ! -d "$APP/Contents/Frameworks/$framework" ]; then
        printf 'НЕ ХВАТАЕТ: %s (нужен %s/Contents/Frameworks/%s)\n'           "$dep" "$APP" "$framework" >&2
        missing=1
      fi
      ;;
  esac
done < <(otool -L "$BIN" | tail -n +2 | awk '{print $1}')

[ "$missing" -eq 0 ] || fail "готовый Cribe.app содержит не все runtime framework dependencies"

otool -L "$BIN" | grep -q 'CTranscribe.framework'   || fail "Cribe executable больше не ссылается на CTranscribe.framework — проверьте интеграцию transcribe.cpp"
[ -d "$APP/Contents/Frameworks/CTranscribe.framework" ]   || fail "CTranscribe.framework отсутствует в готовом app bundle"

otool -L "$BIN" | grep -q 'Sparkle.framework'   || fail "Cribe executable больше не ссылается на Sparkle.framework"
[ -d "$APP/Contents/Frameworks/Sparkle.framework" ]   || fail "Sparkle.framework отсутствует в готовом app bundle"

printf 'Runtime frameworks: OK\n'

if [ "$MODE" != "--launch" ]; then
  exit 0
fi

LOG="${TMPDIR:-/tmp}/cribe-launch-smoke-$$.log"
rm -f "$LOG"
"$BIN" >"$LOG" 2>&1 &
PID=$!

alive=1
i=0
while [ "$i" -lt 20 ]; do
  sleep 0.25
  if ! kill -0 "$PID" 2>/dev/null; then
    alive=0
    break
  fi
  i=$((i + 1))
done

if [ "$alive" -ne 1 ]; then
  set +e
  wait "$PID"
  status=$?
  set -e
  printf 'Cribe завершился во время launch-smoke (exit=%s). Лог:\n' "$status" >&2
  cat "$LOG" >&2 || true
  rm -f "$LOG"
  exit 1
fi

kill "$PID" 2>/dev/null || true
wait "$PID" 2>/dev/null || true
rm -f "$LOG"
printf 'Launch smoke: OK (процесс пережил 5 секунд)\n'
