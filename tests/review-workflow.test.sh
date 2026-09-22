#!/bin/bash
# .github/workflows/review.yml の回帰テスト。
#
# このワークフローは「呼び出し元すべての PR に Approve が付くか」を決める実行体なので、
# 定義がずれても run が緑のまま Approve だけが壊れる形を、静的検査と実行検査で固定する。
#
# 固定するもの:
#   1. checkout 先のパス名の定義は job の env の `ACTIONS_DIR` ちょうど 1 本
#      （定義が 2 箇所に散ると、一方だけを直した変更が緑のまま通る）
#   2. パス名のリテラルが定義行以外に現れない（コメント行は除く。実行に影響しないため）。
#      用途ごとに文字列が散ると、一部だけ旧名に戻す変異を当てても CI の 3 検査がすべて緑になる
#   3. 4 用途（checkout の `path` / プロンプト / 改竄検査 / Approve スクリプトの呼び出し）が
#      `ACTIONS_DIR` を参照している（2 では捕まらない「別のリテラルへの差し替え」を捕まえる）
#   4. 観点ファイルの実在検査が Claude の呼び出しより前にあり、fail-close であること
#      （common.md が無ければ exit 1。追加プロファイルの不在は exit 0 + `::warning`）
#   5. 実在検査のステップ自体が無効化されていない（`if:` で skip / `continue-on-error:` で exit 1 を
#      無害化する形も「壊れているのに CI が緑」で、4 の振る舞い検査だけでは通ってしまう）
#
# ⚠ 検査対象のステップは名前ではなく、やっていること（run: の中で common.md を見ている）で特定する
#   （期待値をテスト側へ書き写すと、パス名やステップ名を変えたときに追随できない）。

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

WORKFLOW="${REPO_ROOT}/.github/workflows/review.yml"

echo "== trillion-game-actions (review.yml) =="

if [[ ! -f "$WORKFLOW" ]]; then
  echo "エラー: 検査対象がありません: ${WORKFLOW}" >&2
  exit 5
fi

# ヘルパー

# review.yml に正規表現へ一致する行があることを検証する
assert_workflow_matches() { # $1 = 正規表現, $2 = 説明
  local matched
  matched="$(command grep -nE -- "$1" "$WORKFLOW")"
  if [[ -n "$matched" ]]; then
    pass "$2"
  else
    fail "$2" "一致する行がありません: /$1/" "対象: ${WORKFLOW}"
  fi
}

# 1. パス名の定義はちょうど 1 本

DEFINITION_LINES="$(command grep -nE '^[[:space:]]*ACTIONS_DIR:' "$WORKFLOW")"
DEFINITION_COUNT="$(printf '%s' "$DEFINITION_LINES" | command grep -c '' || true)"
assert_equals "$DEFINITION_COUNT" "1" "ACTIONS_DIR の定義はちょうど 1 本（現在: ${DEFINITION_LINES:-なし}）"

# 期待値をテスト側に書き写さず、定義行から読む（改称してもテストが追随する）
DEFINITION_LINE_NO="${DEFINITION_LINES%%:*}"
ACTIONS_DIR_VALUE="${DEFINITION_LINES#*ACTIONS_DIR:}"
ACTIONS_DIR_VALUE="${ACTIONS_DIR_VALUE#"${ACTIONS_DIR_VALUE%%[![:space:]]*}"}"
ACTIONS_DIR_VALUE="${ACTIONS_DIR_VALUE%"${ACTIONS_DIR_VALUE##*[![:space:]]}"}"

if [[ -n "$ACTIONS_DIR_VALUE" ]]; then
  pass "ACTIONS_DIR の値を定義行から読めた（${ACTIONS_DIR_VALUE}）"
else
  fail "ACTIONS_DIR の値を定義行から読めた" "定義行: ${DEFINITION_LINES:-なし}"
fi

# 2. パス名のリテラルは定義行にしか出ない（コメント行は除く）

STRAY_LITERALS=""
if [[ -n "$ACTIONS_DIR_VALUE" && "$DEFINITION_COUNT" == "1" ]]; then
  # コメント行（行頭が #）と定義行を除いた残りに、リテラルが出てはならない
  STRAY_LITERALS="$(
    command grep -nF -- "$ACTIONS_DIR_VALUE" "$WORKFLOW" |
      command grep -vE '^[0-9]+:[[:space:]]*#' |
      command grep -vE "^${DEFINITION_LINE_NO}:" || true
  )"
fi
assert_equals "$STRAY_LITERALS" "" "パス名のリテラルは定義行以外に現れない（コメント行を除く）"

# 3. 4 用途が ACTIONS_DIR を参照している

assert_workflow_matches '^[[:space:]]*path: \$\{\{ env\.ACTIONS_DIR \}\}$' \
  "用途 1: checkout の path が ACTIONS_DIR を参照する"
assert_workflow_matches '\$\{\{ env\.ACTIONS_DIR \}\}/perspectives/common\.md' \
  "用途 2: プロンプトの観点ファイルのパスが ACTIONS_DIR を参照する"
assert_workflow_matches 'git -C "\$\{?ACTIONS_DIR\}?" status --porcelain --untracked-files=all' \
  "用途 3: 改竄検査が ACTIONS_DIR を参照する（--untracked-files=all も固定）"
assert_workflow_matches 'bash "\$\{?ACTIONS_DIR\}?/scripts/approve-if-verdict\.sh"' \
  "用途 4: Approve スクリプトの呼び出しが ACTIONS_DIR を参照する"

# 4. 観点ファイルの実在検査（fail-close）

# ステップは名前で探さない（改名に追随できるよう、やっていることで特定する）。
#   「run: ブロックの中で common.md を見ているステップ」で割り出す
#   （claude-code-action も with: の prompt で同じパスに触れるが、run: を持たないので当たらない）。
STEP_START_LINES="$(command grep -nE '^      - ' "$WORKFLOW" | cut -d: -f1)"

# 指定した行を含むステップの開始行を返す
enclosing_step_start() { # $1 = 行番号
  printf '%s\n' "$STEP_START_LINES" | awk -v n="$1" '$1 <= n { s = $1 } END { print s }'
}

VERIFY_STEP_START=""
VERIFY_STEP_HITS=0
while read -r REF_LINE; do
  [[ -z "$REF_LINE" ]] && continue
  STEP_START="$(enclosing_step_start "$REF_LINE")"
  [[ -z "$STEP_START" ]] && continue
  if sed -n "${STEP_START},${REF_LINE}p" "$WORKFLOW" | command grep -qE '^[[:space:]]*run: \|'; then
    VERIFY_STEP_START="$STEP_START"
    VERIFY_STEP_HITS=$((VERIFY_STEP_HITS + 1))
  fi
done <<< "$(command grep -nE 'perspectives/common\.md' "$WORKFLOW" | cut -d: -f1)"

assert_equals "$VERIFY_STEP_HITS" "1" "run: の中で common.md の実在を見ているステップがちょうど 1 つある"

VERIFY_STEP_BLOCK=""
VERIFY_STEP_NAME=""
if [[ -n "$VERIFY_STEP_START" ]]; then
  # ステップの終わりは次のステップの開始直前（無ければファイル末尾）
  VERIFY_STEP_END="$(printf '%s\n' "$STEP_START_LINES" | awk -v s="$VERIFY_STEP_START" '$1 > s { print $1 - 1; exit }')"
  if [[ -z "$VERIFY_STEP_END" ]]; then
    VERIFY_STEP_END="$(command grep -c '' "$WORKFLOW")"
  fi
  VERIFY_STEP_BLOCK="$(sed -n "${VERIFY_STEP_START},${VERIFY_STEP_END}p" "$WORKFLOW")"
  VERIFY_STEP_NAME="$(printf '%s\n' "$VERIFY_STEP_BLOCK" | awk -F'name: ' '/^(      - |        )name: / { print $2; exit }')"
fi

CLAUDE_STEP_LINE="$(command grep -nF -- "uses: anthropics/claude-code-action" "$WORKFLOW" | head -n 1)"
if [[ -n "$VERIFY_STEP_START" && -n "$CLAUDE_STEP_LINE" && "$VERIFY_STEP_START" -lt "${CLAUDE_STEP_LINE%%:*}" ]]; then
  pass "観点ファイルの実在検査は claude-code-action より前にある"
else
  fail "観点ファイルの実在検査は claude-code-action より前にある" \
    "実在検査の開始行: ${VERIFY_STEP_START:-見つからない}" "claude-code-action: ${CLAUDE_STEP_LINE:-見つからない}"
fi

# ⚠ 検査ステップを無効化されると、定義がずれても run は緑のまま通る。
#   `if:` は検査ごと skip させ、`continue-on-error:` は exit 1 を無害化する。どちらも持たせない。
DISABLED_KEYS="$(printf '%s\n' "$VERIFY_STEP_BLOCK" | command grep -E '^(      - |        )(if|continue-on-error):' || true)"
assert_equals "$DISABLED_KEYS" "" \
  "実在検査のステップが無効化されていない（if: / continue-on-error: を持たない。ステップ名: ${VERIFY_STEP_NAME:-不明}）"

# 実在検査ステップの run: ブロックを切り出してそのまま実行する（振る舞いで検査する）。
# シェルは行頭の空白を無視するので、YAML のインデントは落とさずに渡せる。
VERIFY_SCRIPT="$(printf '%s\n' "$VERIFY_STEP_BLOCK" | awk '/^[[:space:]]*run: \|/ { inrun = 1; next } inrun { print }')"

if [[ -n "$VERIFY_SCRIPT" ]]; then
  pass "実在検査ステップの run: ブロックを切り出せた"
else
  fail "実在検査ステップの run: ブロックを切り出せた" "common.md を見る run: ブロックを持つステップが見つからない"
fi

# mktemp -d の戻り値を検証してから trap を張る
if ! TMP="$(mktemp -d "${TMPDIR:-/tmp}/review-workflow-test.XXXXXXXX")"; then
  echo "エラー: mktemp -d に失敗しました。テストを中断します。" >&2
  exit 5
fi
if [[ -z "$TMP" || ! -d "$TMP" || "$TMP" == "$PWD" ]]; then
  echo "エラー: mktemp -d の戻り値が不正です（TMP=[$TMP]）。テストを中断します。" >&2
  exit 5
fi
trap 'rm -rf "$TMP"' EXIT

# 切り出した run: ブロックを、GitHub Actions と同じ `bash -e` で実行する
run_verify() { # $1 = ACTIONS_DIR, $2 = PROFILE_PATHS
  OUT="$(cd "$TMP" && ACTIONS_DIR="$1" PROFILE_PATHS="$2" bash -e -c "$VERIFY_SCRIPT" 2>&1)"
  STATUS=$?
}

mkdir -p "${TMP}/checkout/perspectives"
echo "# common" > "${TMP}/checkout/perspectives/common.md"
echo "# harness" > "${TMP}/checkout/perspectives/harness.md"
mkdir -p "${TMP}/empty"

# 4-1. common.md があり追加プロファイルなし = 通る
run_verify "checkout" ""
assert_equals "$STATUS" "0" "common.md があれば exit 0"
assert_contains "$OUT" "観点ファイルを確認" "確認できたパスをログに出す"
assert_not_contains "$OUT" "::error" "正常時に ::error を出さない"

# 4-2. common.md が無い = run を失敗させる（fail-close）
run_verify "empty" ""
assert_equals "$STATUS" "1" "common.md が無ければ exit 1（fail-close）"
assert_contains "$OUT" "::error title=Agent Review::" "common.md の不在は ::error で見せる"

# 4-3. 追加プロファイルが実在する = 通る
run_verify "checkout" "checkout/perspectives/harness.md"
assert_equals "$STATUS" "0" "実在する追加プロファイルでは exit 0"
assert_contains "$OUT" "追加プロファイルを確認" "確認できた追加プロファイルをログに出す"
assert_not_contains "$OUT" "::warning" "実在する追加プロファイルで ::warning を出さない"

# 4-4. 追加プロファイルが無い = 止めない（::warning だけ）
run_verify "checkout" "checkout/perspectives/unknown.md"
assert_equals "$STATUS" "0" "追加プロファイルの不在では止めない（未知の profile 名を無視する仕様）"
assert_contains "$OUT" "::warning title=Agent Review::" "追加プロファイルの不在は ::warning で見せる"
assert_not_contains "$OUT" "::error" "追加プロファイルの不在で ::error を出さない"

# 4-5. 複数の追加プロファイル（実在 + 不在）= 不在の分だけ警告して続ける
run_verify "checkout" "checkout/perspectives/harness.md checkout/perspectives/unknown.md"
assert_equals "$STATUS" "0" "実在と不在が混ざっても止めない"
assert_contains "$OUT" "追加プロファイルを確認" "実在する分は確認としてログに出す"
assert_contains "$OUT" "::warning title=Agent Review::" "不在の分は ::warning で見せる"

finish
