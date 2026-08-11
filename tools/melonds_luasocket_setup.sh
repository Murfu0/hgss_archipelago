#!/usr/bin/env bash
set -euo pipefail

STAGE="${MELONDS_LUASOCKET_DIR:-$HOME/.melonds-ap-lua}"
LUAROCKS_BIN="${LUAROCKS_BIN:-luarocks}"
LUA_DIR="${LUA_DIR:-$(brew --prefix lua 2>/dev/null || true)}"

if [ -z "$LUA_DIR" ]; then
    echo "ERROR: could not resolve the Homebrew lua prefix."
    echo "Set LUA_DIR to the Lua keg melonDS-lua was built against, for example:"
    echo "  export LUA_DIR=/opt/homebrew/opt/lua"
    exit 1
fi

LUA_BIN="${LUA_BIN:-$LUA_DIR/bin/lua}"
LUA_VERSION="${LUA_VERSION:-$("$LUA_BIN" -e 'print(_VERSION:match("%d+%.%d+"))')}"

echo ">> Staging LuaSocket for Lua ${LUA_VERSION} into ${STAGE}..."
echo ">> Using Lua from ${LUA_DIR}"
mkdir -p "$STAGE"
export PATH="$LUA_DIR/bin:$PATH"
export LUA_INCDIR="$LUA_DIR/include/lua"
export LUA_LIBDIR="$LUA_DIR/lib"
"$LUAROCKS_BIN" --lua-version="$LUA_VERSION" --lua-dir="$LUA_DIR" --tree "$STAGE" install luasocket

echo ""
echo "Done. Staged files:"
echo "  $STAGE/share/lua/${LUA_VERSION}/socket.lua"
echo "  $STAGE/lib/lua/${LUA_VERSION}/socket/core.so"
