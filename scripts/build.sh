#!/usr/bin/env bash
# Сборка байткода vkplay.luac под нужную версию Lua (Linux / macOS).
#
#   scripts/build.sh <lua-version> <suffix>
#   scripts/build.sh 5.1.5 macos   -> dist/vkplay-macos.luac  (VLC 3.x macOS)
#   scripts/build.sh 5.2.4 linux   -> dist/vkplay-linux.luac  (VLC 3.x Linux)
#   scripts/build.sh 5.4.7 vlc4    -> dist/vkplay-vlc4.luac   (VLC 4.x)
#
# luac собирается из официальных исходников lua.org, чтобы версия
# байткода точно совпадала с той, что встроена в VLC.
set -euo pipefail

LUA_VERSION="${1:?usage: build.sh <lua-version> <suffix>}"
SUFFIX="${2:?usage: build.sh <lua-version> <suffix>}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build"
DIST="$ROOT/dist"
mkdir -p "$WORK" "$DIST"

if [ -n "${LUAC:-}" ]; then
  # Готовый luac нужной версии (например, для локальной проверки)
  command -v "$LUAC" >/dev/null || { echo "LUAC not found: $LUAC" >&2; exit 1; }
else
  SRC="$WORK/lua-$LUA_VERSION/src"
  if [ ! -d "$SRC" ]; then
    curl -fsSL "https://www.lua.org/ftp/lua-$LUA_VERSION.tar.gz" | tar -xz -C "$WORK"
  fi

  LUAC="$WORK/luac-$LUA_VERSION"
  if [ ! -x "$LUAC" ]; then
    # Всё ядро + luac.c, без интерпретатора lua.c
    # (без mapfile: в macOS по умолчанию bash 3.2)
    (cd "$SRC" && ${CC:-cc} -O2 -w -DLUA_USE_POSIX -o "$LUAC" $(ls *.c | grep -v '^lua\.c$') -lm)
  fi
fi

OUT="$DIST/vkplay-$SUFFIX.luac"
"$LUAC" -s -o "$OUT" "$ROOT/src/vkplay.lua"

# Проверка заголовка: 1B 'Lua' + байт версии (0x51 / 0x52 / 0x54)
EXPECT="$(echo "$LUA_VERSION" | awk -F. '{printf "%x%x", $1, $2}')"
GOT="$(od -A n -t x1 -j 4 -N 1 "$OUT" | tr -d ' ')"
if [ "$GOT" != "$EXPECT" ]; then
  echo "bytecode version mismatch: expected $EXPECT, got $GOT" >&2
  exit 1
fi

echo "built $OUT (Lua $LUA_VERSION, header: $(od -A n -t x1 -N 12 "$OUT"))"
