#!/bin/sh
# shellcheck disable=SC2034,SC2154
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "envcheck: $SRC not present, skipped"; exit 0; }

strip() { sed 's/^[[:space:]]*//'; }
dllpath_line=$(grep 'export WINEDLLPATH=' "$SRC" | grep 'x86_64-windows' | strip)
overrides_line=$(grep 'export WINEDLLOVERRIDES=' "$SRC" | grep 'lsteamclient=b' | strip)
[ -n "$dllpath_line" ] || { echo "FAIL: WINEDLLPATH merge not found"; exit 1; }
[ -n "$overrides_line" ] || { echo "FAIL: WINEDLLOVERRIDES merge not found"; exit 1; }

fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

echo "== WINEDLLPATH (first match wins, runner first) =="
CX_ROOT=/R
wine_unix=/R/lib/wine/x86_64-unix
WINEDLLPATH=""
eval "$dllpath_line"
is "no user value" "/R/lib/wine/x86_64-windows:/R/lib/wine/x86_64-unix" "$WINEDLLPATH"
WINEDLLPATH="/user/dir"
eval "$dllpath_line"
is "user value last" "/R/lib/wine/x86_64-windows:/R/lib/wine/x86_64-unix:/user/dir" "$WINEDLLPATH"

echo "== WINEDLLOVERRIDES (last wins, trio last) =="
WINEDLLOVERRIDES=""
eval "$overrides_line"
is "no user value" "steamclient=n;steamclient64=n;lsteamclient=b" "$WINEDLLOVERRIDES"
WINEDLLOVERRIDES="winhttp=n,b"
eval "$overrides_line"
is "user value first" "winhttp=n,b;steamclient=n;steamclient64=n;lsteamclient=b" "$WINEDLLOVERRIDES"
WINEDLLOVERRIDES="lsteamclient=n"
eval "$overrides_line"
is "trio outranks user" "lsteamclient=n;steamclient=n;steamclient64=n;lsteamclient=b" "$WINEDLLOVERRIDES"

echo "== Apple GPTK initialization and launcher environment =="
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
np_support="$work/Application Support/notproton"
np_build="test"
library="$np_support/runners/crossover-$np_build/CrossOver/lib64/apple_gptk/external/libd3dshared.dylib"
init=$(sed -n '/^CX_ROOT=/,/^wine_unix=/p' "$SRC")
# shellcheck disable=SC2016 # Match the literal launcher loop.
forward=$(sed -n '/^for name in $(env /,/^done$/p' "$SRC")
[ -n "$init" ] && [ -n "$forward" ] || { echo "FAIL: runner environment blocks not found"; exit 1; }
unset CX_APPLEGPTK_LIBD3DSHARED_PATH
eval "$init"
is "runner without the library leaves the path unset" "" "${CX_APPLEGPTK_LIBD3DSHARED_PATH:-}"
mkdir -p "$(dirname "$library")"
: > "$library"
eval "$init"
is "bundled library is selected" "$library" "${CX_APPLEGPTK_LIBD3DSHARED_PATH:-}"
is "helpers inherit the library path" "$library" "$(sh -c 'printf %s "$CX_APPLEGPTK_LIBD3DSHARED_PATH"')"
set --
eval "$forward"
forwarded=""
for arg in "$@"; do
  case "$arg" in CX_APPLEGPTK_LIBD3DSHARED_PATH=*) forwarded=${arg#*=} ;; esac
done
is "game launcher receives the path as one argument" "$library" "$forwarded"

if [ "$fails" -eq 0 ]; then
	echo "==> envcheck: all assertions hold"
else
	echo "==> envcheck: $fails failed"
	exit 1
fi
