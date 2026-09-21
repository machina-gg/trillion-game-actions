#!/bin/bash
# .github/workflows/review.yml の回帰テスト。
#
# このワークフローは「呼び出し元すべての PR に Approve が付くか」を決める実行体なので、
# 定義がずれても run が緑のまま Approve だけが壊れる形を、静的検査と実行検査で固定する。
#
# 最重要の回帰対象:
#   1. ⚠ **checkout 先のパス名の定義は job の env の `ACTIONS_DIR` ちょうど 1 本**
#      （定義が 2 箇所に散ると、一方だけを直した変更が緑のまま通る）
#   2. ⚠ **パス名のリテラルが定義行以外に現れない**（コメント行は除く。コメントは実行に影響せず、
#      パス名そのものを説明する注記を書けるようにするため）。用途ごとに文字列が散ると、
#      一部だけ旧名に戻す変異を当てても CI の 3 検査がすべて緑になる（本リポジトリ #10 の観測）
#   3. 4 用途（checkout の `path` / プロンプト / 改竄検査 / Approve スクリプトの呼び出し）が
#      `ACTIONS_DIR` を参照している（2 では捕まらない「別のリテラルへの差し替え」を捕まえる）
#   4. 観点ファイルの実在検査が Claude の呼び出しより前にあり、fail-close であること
#      （`common.md` が無ければ exit 1。⚠ 追加プロファイルの不在は exit 0 + `::warning` で、
#      未知の profile 名を無視してレビューを続ける仕様を変えない）

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

# ------------------------------------------------------------------
# ヘルパー
# ------------------------------------------------------------------

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

# ------------------------------------------------------------------
# 1. パス名の定義はちょうど 1 本
# ------------------------------------------------------------------

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

# ------------------------------------------------------------------
# 2. パス名のリテラルは定義行にしか出ない（コメント行は除く）
# ------------------------------------------------------------------

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

# ------------------------------------------------------------------
# 3. 4 用途が ACTIONS_DIR を参照している
# ------------------------------------------------------------------

assert_workflow_matches '^[[:space:]]*path: \$\{\{ env\.ACTIONS_DIR \}\}$' \
  "用途 1: checkout の path が ACTIONS_DIR を参照する"
assert_workflow_matches '\$\{\{ env\.ACTIONS_DIR \}\}/perspectives/common\.md' \
  "用途 2: プロンプトの観点ファイルのパスが ACTIONS_DIR を参照する"
assert_workflow_matches 'git -C "\$\{?ACTIONS_DIR\}?" status --porcelain --untracked-files=all' \
  "用途 3: 改竄検査が ACTIONS_DIR を参照する（--untracked-files=all も固定）"
assert_workflow_matches 'bash "\$\{?ACTIONS_DIR\}?/scripts/approve-if-verdict\.sh"' \
  "用途 4: Approve スクリプトの呼び出しが ACTIONS_DIR を参照する"

# ------------------------------------------------------------------
# 4. 観点ファイルの実在検査（fail-close）
# ------------------------------------------------------------------

VERIFY_STEP_NAME="Verify perspective files exist"

VERIFY_STEP_LINE="$(command grep -nF -- "- name: ${VERIFY_STEP_NAME}" "$WORKFLOW" | head -n 1)"
CLAUDE_STEP_LINE="$(command grep -nF -- "uses: anthropics/claude-code-action" "$WORKFLOW" | head -n 1)"
if [[ -n "$VERIFY_STEP_LINE" && -n "$CLAUDE_STEP_LINE" && "${VERIFY_STEP_LINE%%:*}" -lt "${CLAUDE_STEP_LINE%%:*}" ]]; then
  pass "観点ファイルの実在検査は claude-code-action より前にある"
else
  fail "観点ファイルの実在検査は claude-code-action より前にある" \
    "実在検査: ${VERIFY_STEP_LINE:-見つからない}" "claude-code-action: ${CLAUDE_STEP_LINE:-見つからない}"
fi

# 実在検査ステップの run: ブロックを切り出してそのまま実行する（振る舞いで検査する）。
# ⚠ シェルは行頭の空白を無視するので、YAML のインデントは落とさずに渡せる。
VERIFY_SCRIPT="$(
  awk -v name="- name: ${VERIFY_STEP_NAME}" '
    index($0, name) { instep = 1; next }
    instep && !inrun && /^[[:space:]]*- (name|uses):/ { exit }
    instep && !inrun && /run: \|/ { inrun = 1; next }
    inrun && /^[[:space:]]*- (name|uses):/ { exit }
    inrun { print }
  ' "$WORKFLOW"
)"

if [[ -n "$VERIFY_SCRIPT" ]]; then
  pass "実在検査ステップの run: ブロックを切り出せた"
else
  fail "実在検査ステップの run: ブロックを切り出せた" "ステップ名「${VERIFY_STEP_NAME}」が見つからないか run: | が無い"
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
