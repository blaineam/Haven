#!/usr/bin/env bash
# Re-run every Tamarin model in this directory and compare each lemma's result with
# EXPECTED.txt. Exit 0 only when every lemma gives exactly the recorded result.
#
#   docs/formal/verify.sh            check against EXPECTED.txt (what CI runs)
#   docs/formal/verify.sh --record   rewrite EXPECTED.txt from a fresh run
#
# A lemma is proved on its own (`--prove=NAME`), because a whole-theory run of the larger
# models needs more memory than a CI runner has. Lemmas marked [reuse] are assumed by the
# others, and each of them is proved here too, so nothing is assumed without being checked.
#
# Some lemmas are EXPECTED to be falsified: they record a property the design does not
# give (and says so), or a weakness in a superseded design. A change from "falsified" to
# "verified" fails the check as well, so the documents cannot drift from the models.
#
# Needs tamarin-prover 1.10 or later and maude on PATH.
# Env: LEMMA_TIMEOUT seconds per lemma (default 900), TAMARIN_RTS (default "-N2 -M12G"),
# VERIFY_BIG=1 to also prove the lemmas that need 40 GB (TAMARIN_RTS_BIG, default "-N4 -M40G").
set -u
cd "$(dirname "$0")"

LEMMA_TIMEOUT="${LEMMA_TIMEOUT:-900}"
TAMARIN_RTS="${TAMARIN_RTS:--N2 -M12G}"
EXPECTED=EXPECTED.txt
RECORD=0
[ "${1:-}" = "--record" ] && RECORD=1

# theory | extra flags | mode (lemma = one run per lemma, whole = one run of the theory)
CONFIGS=(
  "haven_circle_keys||lemma"
  "haven_circle_keys|-DCHECKED|lemma"
  "haven_circle_keys|-DFS|lemma"
  "haven_circle_keys|-DCHECKED -DFS|lemma"
  "haven_device_roster||lemma"
  "haven_web_device||lemma"
  "haven_web_device|-DDEVICE_SPEAKS|lemma"
  "haven_item_keys||lemma"
  "haven_item_keys|-DCLEAR_GRANT|lemma"
  "haven_item_keys|-DANY_SIGNER|lemma"
  "haven_pair||lemma"
  "haven_pair|-DUNBOUND|lemma"
  "haven_web_consent||lemma"
  "haven_web_consent|-DSTRIPPABLE|lemma"
  "haven_web_push||lemma"
  "haven_web_push|-DNO_CREDENTIAL|lemma"
  "haven_treekem_as_wired||lemma"
  "haven_treekem_stage1||lemma"
  "haven_treekem_stage1|-DLEGACY|lemma"
  "haven_treekem_fixed||lemma"
  "haven_treekem_forks||lemma"
  "haven_treekem_v2_built||lemma"
  "haven_deterministic_seal|--diff -DUNIQUE|whole"
  "haven_deterministic_seal|--diff -DUNIQUE -DORACLE|whole"
  "haven_deterministic_seal|--diff -DRESEAL|whole"
  "haven_deterministic_seal|--diff -DGUESS|whole"
  "haven_deterministic_seal|--diff -DGUESS -DORACLE|whole"
)

# Lemmas that need more memory than a CI runner has. Without VERIFY_BIG=1 they are not
# re-proved and the recorded line is written as is, so the gap is visible in EXPECTED.txt
# instead of being silently absent. With VERIFY_BIG=1 (a machine with 48 GB) they are proved
# with TAMARIN_RTS_BIG, and anything other than "verified" fails the check.
#   stage 1 / existing circle / T2: verified in 13995 steps, about 5 minutes, 35 GB peak
#   (2026-11-19, -N4 -M40G); it exhausts a 14 GB heap. It belongs to the superseded stage 1
#   design; T2 for the tree that ships is haven_treekem_v2_built ::
#   T2_removed_member_locked_out, which is proved on every run.
BIG=(
  "haven_treekem_stage1 -DLEGACY :: T2_removed_member_locked_out"
)
BIG_RESULT="verified (needs 40 GB: proved with VERIFY_BIG=1, not in CI)"
VERIFY_BIG="${VERIFY_BIG:-0}"
TAMARIN_RTS_BIG="${TAMARIN_RTS_BIG:--N4 -M40G}"
is_big() { local k; for k in "${BIG[@]}"; do [ "$k" = "$1" ] && return 0; done; return 1; }

# VERIFY_ONLY=<substring> limits the run to matching configurations (local use).
VERIFY_ONLY="${VERIFY_ONLY:-}"

command -v tamarin-prover >/dev/null || { echo "tamarin-prover not found on PATH" >&2; exit 2; }

OUT="$(mktemp -d)"
GOT="$OUT/got.txt"
: > "$GOT"

# Run tamarin with a wall-clock limit (no dependency on coreutils `timeout`).
run_limited() { # <logfile> <args...>
  local log="$1"; shift
  tamarin-prover "$@" +RTS $TAMARIN_RTS -RTS > "$log" 2>&1 &
  local pid=$!
  # The watchdog must not outlive the proof or hold our stdout: kill its sleep with it.
  ( sleep "$LEMMA_TIMEOUT" & s=$!; trap 'kill $s 2>/dev/null; exit 0' TERM; wait $s; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  local watch=$!
  wait "$pid"; local rc=$?
  kill "$watch" 2>/dev/null; wait "$watch" 2>/dev/null
  return $rc
}

# Summary lines look like:  "  NAME (all-traces): verified (12 steps)"
# and, in --diff mode:      "  DiffLemma:  Observational_equivalence : falsified - found trace (9 steps)"
summary() { # <logfile> -> "name<TAB>result" per line
  sed -n '/^summary of summaries/,$p' "$1" \
    | grep -E ':[[:space:]]*(verified|falsified|analysis incomplete)' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]*\((all-traces|exists-trace)\)//; s/^DiffLemma:[[:space:]]*//' \
    | sed -E 's/[[:space:]]*:[[:space:]]*(verified|falsified|analysis incomplete).*$/\t\1/'
}

for cfg in "${CONFIGS[@]}"; do
  IFS='|' read -r theory flags mode <<< "$cfg"
  file="$theory.spthy"
  label="$theory${flags:+ $flags}"
  if [ -n "$VERIFY_ONLY" ] && [[ "$label" != *"$VERIFY_ONLY"* ]]; then continue; fi
  # shellcheck disable=SC2086
  if [ "$mode" = whole ]; then
    log="$OUT/$(echo "$label" | tr ' /' '__').log"
    run_limited "$log" --auto-sources $flags --prove "$file"
    rows="$(summary "$log")"
    if [ -z "$rows" ]; then
      printf '%s :: %s :: %s\n' "$label" "(whole theory)" "no result (timeout or error, see log)" | tee -a "$GOT"
      tail -20 "$log" >&2
    else
      while IFS=$'\t' read -r name res; do
        printf '%s :: %s :: %s\n' "$label" "$name" "$res" | tee -a "$GOT"
      done <<< "$rows"
    fi
    continue
  fi
  for lemma in $(grep -E '^lemma [A-Za-z0-9_]+' "$file" | sed -E 's/^lemma ([A-Za-z0-9_]+).*/\1/' | sort -u); do
    if is_big "$label :: $lemma"; then
      if [ "$VERIFY_BIG" = 1 ]; then
        log="$OUT/$(echo "$label" | tr ' /' '__')-$lemma.log"
        TAMARIN_RTS="$TAMARIN_RTS_BIG" run_limited "$log" --auto-sources $flags "--prove=$lemma" "$file"
        res="$(summary "$log" | awk -F'\t' -v l="$lemma" '$1==l {print $2}' | head -1)"
        [ "$res" = verified ] && res="$BIG_RESULT"
        [ -z "$res" ] && { res="no result (timeout or error, see log)"; tail -20 "$log" >&2; }
      else
        res="$BIG_RESULT"
      fi
      printf '%s :: %s :: %s\n' "$label" "$lemma" "$res" | tee -a "$GOT"
      continue
    fi
    log="$OUT/$(echo "$label" | tr ' /' '__')-$lemma.log"
    run_limited "$log" --auto-sources $flags "--prove=$lemma" "$file"
    res="$(summary "$log" | awk -F'\t' -v l="$lemma" '$1==l {print $2}' | head -1)"
    # A lemma inside an #ifdef that this configuration does not define is simply absent.
    if [ -z "$res" ]; then
      if grep -q '^summary of summaries' "$log"; then continue; fi
      res="no result (timeout or error, see log)"; tail -20 "$log" >&2
    fi
    printf '%s :: %s :: %s\n' "$label" "$lemma" "$res" | tee -a "$GOT"
  done
done

if [ -n "$VERIFY_ONLY" ]; then
  if [ "$RECORD" = 1 ]; then echo "--record needs a full run (unset VERIFY_ONLY)" >&2; exit 2; fi
  grep -F -- "$VERIFY_ONLY" "$EXPECTED" > "$OUT/expected.txt"
  EXPECTED="$OUT/expected.txt"
fi

if [ "$RECORD" = 1 ]; then
  cp "$GOT" "$EXPECTED"
  echo "recorded $(wc -l < "$EXPECTED" | tr -d ' ') results in $EXPECTED"
  exit 0
fi

if diff -u "$EXPECTED" "$GOT"; then
  echo "all $(wc -l < "$GOT" | tr -d ' ') lemma results match $EXPECTED"
  exit 0
fi
echo "lemma results differ from $EXPECTED (logs in $OUT)" >&2
exit 1
