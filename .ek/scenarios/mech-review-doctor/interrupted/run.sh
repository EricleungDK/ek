#!/bin/bash
source "$EK_REPO/.ek/scenarios/lib.sh"
source "$EK_PARENT_DIR/fixtures/helpers.sh"
export TMPDIR="$PWD/tmp"; mkdir -p "$TMPDIR"
HANG="$PWD/hang.sh"
cat > "$HANG" <<'S'
#!/bin/bash
[[ "$*" == *--version* ]] && exit 0
echo $$ > "$HANG_PID"
exec sleep 30
S
chmod +x "$HANG"
bad=0
stop() { local name=$1 sig=$2 r="$PWD/$1"; rust_repo "$r"
  export HANG_PID="$PWD/$name.pid"
  MECH_TEST_STUB="$HANG" python3 -I "$MR" doctor --repo "$r" >/dev/null 2>&1 &
  local pid=$! n
  for n in $(seq 100); do [[ -s "$HANG_PID" ]] && break; sleep 0.1; done
  [[ -s "$HANG_PID" ]] || fail "$name: tests never started"
  kill -"$sig" "$pid"; wait "$pid" 2>/dev/null
  kill "$(cat "$HANG_PID")" 2>/dev/null
  ( eq "$name worktrees" "$(git -C "$r" worktree list | wc -l)" 1
    eq "$name temp dir" "$(ls "$TMPDIR" | wc -l)" 0 ) || bad=1; }
stop int INT
stop term TERM
[[ $bad == 0 ]] || exit 1
echo "interrupted ok"
