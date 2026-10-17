#!/usr/bin/env bash
# NOM-238: test the prompt-override loop in install.sh without running the
# installer against a live stack.
#
# The loop is lifted out of install.sh by marker, so this test fails loudly if
# somebody moves or renames it rather than silently testing a stale copy.
#
#   ./test_prompt_install.sh /path/to/install.sh
set -uo pipefail

INSTALL=${1:-$(dirname "$0")/install.sh}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

START='for shipped in "$SCRIPT_DIR"/prompts-ar/\*.tmpl; do'
BLOCK="$WORK/block.sh"

awk -v start='for shipped in "$SCRIPT_DIR"/prompts-ar/*.tmpl; do' '
    index($0, start) { inblock = 1 }
    inblock { print }
    inblock && /^    done$/ { exit }
' "$INSTALL" > "$BLOCK"

if ! grep -q 'prompts-ar' "$BLOCK" || ! grep -q '^    done$' "$BLOCK"; then
    echo "FAIL: could not extract the prompt-override loop from $INSTALL"
    exit 1
fi
echo "extracted $(wc -l < "$BLOCK") lines of the prompt-override loop"

run_install() {
    # Stub the installer's reporting helpers and run just the loop.
    (
        SCRIPT_DIR="$WORK/repo"
        PROMPTS_DIR="$WORK/run/prompts"
        print_success() { echo "SUCCESS: $*"; }
        print_info() { echo "INFO: $*"; }
        local shipped name target stamp new_sum cur_sum last_sum
        # shellcheck disable=SC1090
        source "$BLOCK"
    )
}

reset_dirs() {
    rm -rf "$WORK/repo" "$WORK/run"
    mkdir -p "$WORK/repo/prompts-ar" "$WORK/run/prompts"
    printf 'SHIPPED v1\n' > "$WORK/repo/prompts-ar/tag_prompt.tmpl"
    printf 'SHIPPED OCR v1\n' > "$WORK/repo/prompts-ar/ocr_prompt.tmpl"
}

fails=0
check() {
    local name=$1 want=$2 got=$3
    if [[ $want == "$got" ]]; then
        echo "PASS  $name"
    else
        echo "FAIL  $name"
        echo "        want: $(printf '%q' "$want")"
        echo "        got : $(printf '%q' "$got")"
        fails=$((fails + 1))
    fi
}

echo
echo "--- 1. fresh install: both shipped prompts land ---"
reset_dirs
out=$(run_install)
echo "$out" | sed 's/^/    /'
check "tag prompt installed" "SHIPPED v1" "$(cat "$WORK/run/prompts/tag_prompt.tmpl")"
check "ocr prompt installed" "SHIPPED OCR v1" "$(cat "$WORK/run/prompts/ocr_prompt.tmpl")"
check "tag stamp written" "yes" "$([[ -f $WORK/run/prompts/.tag_prompt.installed.sha256 ]] && echo yes || echo no)"

echo
echo "--- 2. re-run with nothing changed: idempotent ---"
out=$(run_install)
echo "$out" | sed 's/^/    /'
check "still ours" "SHIPPED v1" "$(cat "$WORK/run/prompts/tag_prompt.tmpl")"
check "reported as already in place" "yes" \
    "$(echo "$out" | grep -q 'already in place: tag_prompt.tmpl' && echo yes || echo no)"

echo
echo "--- 3. upgrade: we shipped a new version, operator never touched it ---"
printf 'SHIPPED v2\n' > "$WORK/repo/prompts-ar/tag_prompt.tmpl"
out=$(run_install)
echo "$out" | sed 's/^/    /'
check "upgraded to v2" "SHIPPED v2" "$(cat "$WORK/run/prompts/tag_prompt.tmpl")"

echo
echo "--- 4. operator edited the prompt: their version is kept ---"
printf 'OPERATOR EDIT\n' > "$WORK/run/prompts/tag_prompt.tmpl"
printf 'SHIPPED v3\n' > "$WORK/repo/prompts-ar/tag_prompt.tmpl"
out=$(run_install)
echo "$out" | sed 's/^/    /'
check "operator edit preserved" "OPERATOR EDIT" "$(cat "$WORK/run/prompts/tag_prompt.tmpl")"
check "told the operator" "yes" \
    "$(echo "$out" | grep -q 'You have edited prompts/tag_prompt.tmpl' && echo yes || echo no)"
check "ocr prompt still upgraded independently" "SHIPPED OCR v1" \
    "$(cat "$WORK/run/prompts/ocr_prompt.tmpl")"

echo
echo "--- 5. the upstream seeding loop skips anything we ship ---"
# The seeding loop's guard must be keyed on prompts-ar/, not on a hardcoded
# ocr_prompt.tmpl, or tag_prompt.tmpl gets the upstream copy first and then
# looks like an operator edit forever.
if grep -q '\[\[ -f "\$SCRIPT_DIR/prompts-ar/\$f" \]\] && continue' "$INSTALL"; then
    echo "PASS  seeding loop skips every shipped override"
else
    echo "FAIL  seeding loop does not skip shipped overrides by prompts-ar/ lookup"
    fails=$((fails + 1))
fi

echo
echo "RESULT: $([[ $fails -eq 0 ]] && echo 'ALL CHECKS PASSED' || echo "$fails CHECK(S) FAILED")"
exit $(( fails > 0 ))
