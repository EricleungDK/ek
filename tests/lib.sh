# Minimal test helpers. Source from tests/*.test.sh.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILS=0

# fakebin <dir> <tool...>: dir with symlinks to real tools only, for PATH isolation
fakebin() {
  local d="$1"; shift
  mkdir -p "$d"
  for t in bash sh env cat grep sed head tail tr cut dirname basename ls mkdir rm mktemp date sort timeout test printf wc stat sha1sum find "$@"; do
    local p; p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$d/$t"
  done
}

# stub <dir> <name> <script body>: fake executable
stub() { printf '#!/bin/bash\n%s\n' "$3" > "$1/$2"; chmod +x "$1/$2"; }

ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAILS=$((FAILS+1)); }

has()  { grep -qF -- "$2" <<<"$1" && ok "$3" || { fail "$3"; printf '       want: %s\n       got:\n%s\n' "$2" "$1"; }; }
lacks(){ grep -qF -- "$2" <<<"$1" && { fail "$3"; printf '       unwanted: %s\n' "$2"; } || ok "$3"; }
eq()   { [[ "$1" == "$2" ]] && ok "$3" || { fail "$3"; printf '       want: %s\n       got:  %s\n' "$2" "$1"; }; }

done_tests() { exit $(( FAILS > 0 )); }
