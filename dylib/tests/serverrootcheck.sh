#!/bin/sh
set -eu
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "serverrootcheck: $SRC not present, skipped"; exit 0; }

work=$(mktemp -d "${TMPDIR:-/tmp}/np-serverrootcheck.XXXXXX")
trap 'chmod -R u+rwX "$work"; rm -rf "$work"' EXIT
log="$work/log"

functions=$(awk '
  /^secure_wine_server_root\(\) \{/ { on = 1 }
  on { print }
  on && /^}/ { found = 1; exit }
  END { exit !found }
' "$SRC") || { echo "FAIL: secure_wine_server_root not found" >&2; exit 1; }
eval "$functions"

fails=0
check() {
  if "$@"; then printf '  ok    %s\n' "$*"; else
    printf '  FAIL  %s\n' "$*"
    fails=$((fails + 1))
  fi
}
mode() { stat -f %Lp "$1"; }
uid=$(id -u)

echo "== Wine server root security =="
missing="$work/missing"
check secure_wine_server_root "$missing" "$uid"
check test -d "$missing"
check test "$(mode "$missing")" = 700

open="$work/open"
mkdir "$open"
chmod 755 "$open"
check secure_wine_server_root "$open" "$uid"
check test "$(mode "$open")" = 700
check grep -q 'repaired Wine server root permissions from 755 to 700' "$log"

foreign="$work/foreign"
mkdir "$foreign"
chmod 755 "$foreign"
check test "$(secure_wine_server_root "$foreign" "$((uid + 1))" >/dev/null 2>&1 && echo accepted || echo refused)" = refused
check test "$(mode "$foreign")" = 755

target="$work/target"
mkdir "$target"
chmod 755 "$target"
ln -s "$target" "$work/link"
check test "$(secure_wine_server_root "$work/link" "$uid" >/dev/null 2>&1 && echo accepted || echo refused)" = refused
check test "$(mode "$target")" = 755

printf file > "$work/file"
check test "$(secure_wine_server_root "$work/file" "$uid" >/dev/null 2>&1 && echo accepted || echo refused)" = refused

if [ "$fails" -eq 0 ]; then
  echo "==> serverrootcheck: all assertions hold"
else
  echo "==> serverrootcheck: $fails failed"
  exit 1
fi
