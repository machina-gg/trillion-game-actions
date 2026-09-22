#!/bin/bash
# .github/actions/issue-link-check/check.sh の回帰テスト。
#
# 環境変数だけを入力に取る決定的処理なので、GitHub Actions を介さずそのまま実行して検証する。
#
# 最重要の回帰対象:
#   1. 受理する語は closes / fixes / resolves / **refs** の 4 つ
#      （refs が落ちると、シリーズ作業の途中 PR が規約どおりに書いても検査に落ちる）
#   2. override ラベルは**要素の完全一致**でだけスキップする
#      （前後に語を足した似た名前のラベルや、カンマ連結への部分一致でスキップさせない）
#   3. 入力を解釈できないときはスキップせず検査を実行する（fail-close）
#   4. 判定ロジックが check.sh にあり、action.yml へインライン化されていない

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

ACTION_DIR="${REPO_ROOT}/.github/actions/issue-link-check"
SCRIPT="${ACTION_DIR}/check.sh"

echo "== trillion-game-actions (issue-link-check/check.sh) =="

# 実行ヘルパー

# 渡す環境変数を CHECK_ENV に積んでから run_check を呼ぶ（1 回ごとに空に戻る）。
# ⚠ 積まなかった変数は「未設定」として渡る（空文字との違いを検査するため）。
CHECK_ENV=()
# ⚠ bash は絶対パスで起動する（PATH を差し替えるケースがあり、env が bash 自体を
#   見つけられなくなるため）
BASH_BIN="$(command -v bash)"
run_check() {
  OUT="$(env ${CHECK_ENV[@]+"${CHECK_ENV[@]}"} "$BASH_BIN" "$SCRIPT" 2>&1)"
  STATUS=$?
  CHECK_ENV=()
}

# jq を取り除いた PATH を作る（grep は check.sh が使うので残す）
if ! TMP="$(mktemp -d "${TMPDIR:-/tmp}/issue-link-check-test.XXXXXXXX")"; then
  echo "エラー: mktemp -d に失敗しました。テストを中断します。" >&2
  exit 5
fi
if [[ -z "$TMP" || ! -d "$TMP" || "$TMP" == "$PWD" ]]; then
  echo "エラー: mktemp -d の戻り値が不正です（TMP=[$TMP]）。テストを中断します。" >&2
  exit 5
fi
trap 'rm -rf "$TMP"' EXIT
mkdir -p "${TMP}/nojq-bin"
ln -s "$(command -v grep)" "${TMP}/nojq-bin/grep"
NOJQ_PATH="${TMP}/nojq-bin"

LABELS_NONE='[]'
LABELS_OVERRIDE='["bug","override:no-issue"]'

# 1. 本文の受理パターン

for keyword in Closes Fixes Resolves Refs; do
  CHECK_ENV=("PR_BODY=${keyword} #5" "LABELS_JSON=${LABELS_NONE}" "OVERRIDE_LABEL=override:no-issue")
  run_check
  assert_equals "$STATUS" "0" "${keyword} #5 は紐づけとして受理する"
  assert_contains "$OUT" "Issue 紐づけチェック OK" "${keyword} #5 で OK と出力する"
done

CHECK_ENV=("PR_BODY=closes #5" "LABELS_JSON=${LABELS_NONE}" "OVERRIDE_LABEL=override:no-issue")
run_check
assert_equals "$STATUS" "0" "小文字の closes も受理する（大文字小文字を区別しない）"

CHECK_ENV=("PR_BODY=CLOSES #5" "LABELS_JSON=${LABELS_NONE}" "OVERRIDE_LABEL=override:no-issue")
run_check
assert_equals "$STATUS" "0" "大文字の CLOSES も受理する"

CHECK_ENV=("PR_BODY=## 概要
本文の 2 行目以降に書かれた Refs #123 も読む。" "LABELS_JSON=${LABELS_NONE}" "OVERRIDE_LABEL=override:no-issue")
run_check
assert_equals "$STATUS" "0" "複数行の本文でも行を問わず受理する"

CHECK_ENV=("PR_BODY=Refs #5, Closes #6" "LABELS_JSON=${LABELS_NONE}" "OVERRIDE_LABEL=override:no-issue")
run_check
assert_equals "$STATUS" "0" "1 行に複数の紐づけがあっても受理する"

CHECK_ENV=("PR_BODY=(closes #7)" "LABELS_JSON=${LABELS_NONE}" "OVERRIDE_LABEL=override:no-issue")
run_check
assert_equals "$STATUS" "0" "括弧の直後でも受理する（左の境界は英字以外なら通す）"

CHECK_ENV=("PR_BODY=**Closes #12**" "LABELS_JSON=${LABELS_NONE}" "OVERRIDE_LABEL=override:no-issue")
run_check
assert_equals "$STATUS" "0" "Markdown の装飾が付いていても受理する"

CHECK_ENV=("PR_BODY=Refs #123の続き" "LABELS_JSON=${LABELS_NONE}" "OVERRIDE_LABEL=override:no-issue")
run_check
assert_equals "$STATUS" "0" "番号の直後に日本語が続く形も受理する（右側に境界を置かない）"

# 右側に境界を置かない選択の裏返し。置けば弾けるが、上の「番号の直後に日本語」が通らなくなる
#   （UTF-8 ロケールでは日本語が [[:alnum:]] に入る）ため、受理する側を選んでいる。
CHECK_ENV=("PR_BODY=Closes #12abc" "LABELS_JSON=${LABELS_NONE}" "OVERRIDE_LABEL=override:no-issue")
run_check
assert_equals "$STATUS" "0" "番号の直後に英字が続く形も受理する（右側に境界を置かない選択）"

# 2. 本文が受理されない形

CHECK_ENV=("PR_BODY=概要だけを書いた本文" "LABELS_JSON=${LABELS_NONE}" "OVERRIDE_LABEL=override:no-issue")
run_check
assert_equals "$STATUS" "1" "紐づけが無い本文は exit 1"
assert_contains "$OUT" "::error title=Issue Check::" "落ちたときは ::error:: を出す"
assert_contains "$OUT" "override:no-issue" "override ラベル名を案内に出す"

CHECK_ENV=("PR_BODY=" "LABELS_JSON=${LABELS_NONE}" "OVERRIDE_LABEL=override:no-issue")
run_check
assert_equals "$STATUS" "1" "本文が空文字なら exit 1（未設定とは区別して検査する）"

CHECK_ENV=("PR_BODY=Closes#5" "LABELS_JSON=${LABELS_NONE}" "OVERRIDE_LABEL=override:no-issue")
run_check
assert_equals "$STATUS" "1" "語と番号の間に空白が無い形は受理しない"

CHECK_ENV=("PR_BODY=Closes #abc" "LABELS_JSON=${LABELS_NONE}" "OVERRIDE_LABEL=override:no-issue")
run_check
assert_equals "$STATUS" "1" "番号が数値でない形は受理しない"

CHECK_ENV=("PR_BODY=Refsx #5" "LABELS_JSON=${LABELS_NONE}" "OVERRIDE_LABEL=override:no-issue")
run_check
assert_equals "$STATUS" "1" "語の直後に文字が続く形は受理しない"

# 2-2. 英単語の末尾への部分一致（左の境界が落ちると素通りする）

# ⚠ ここが通ると、Issue と無関係な本文が脚注番号などの #数字 だけで検査を通過する
#   （override ラベル無しで、誰の意図もなく必須チェックが無効化される）。
for word in prefixes suffixes postfixes; do
  CHECK_ENV=("PR_BODY=${word} #3 are supported" "LABELS_JSON=${LABELS_NONE}" "OVERRIDE_LABEL=override:no-issue")
  run_check
  assert_equals "$STATUS" "1" "${word} #3 は紐づけとして受理しない（fixes への部分一致）"
done

for word in encloses discloses; do
  CHECK_ENV=("PR_BODY=PR ${word} #5 for context" "LABELS_JSON=${LABELS_NONE}" "OVERRIDE_LABEL=override:no-issue")
  run_check
  assert_equals "$STATUS" "1" "${word} #5 は紐づけとして受理しない（closes への部分一致）"
done

# 左の境界が「行頭」でも効くこと（^ 側の分岐）
CHECK_ENV=("PR_BODY=Closes #1
以降は本文。" "LABELS_JSON=${LABELS_NONE}" "OVERRIDE_LABEL=override:no-issue")
run_check
assert_equals "$STATUS" "0" "本文の 1 行目の行頭から始まる Closes #1 を受理する"

CHECK_ENV=("PR_BODY=## 概要
prefixes #3 を説明する行" "LABELS_JSON=${LABELS_NONE}" "OVERRIDE_LABEL=override:no-issue")
run_check
assert_equals "$STATUS" "1" "行頭の部分一致（prefixes #3）も受理しない"

# 3. override ラベル（要素の完全一致でだけスキップする）

NO_LINK="紐づけの無い本文"

CHECK_ENV=("PR_BODY=${NO_LINK}" "LABELS_JSON=${LABELS_OVERRIDE}" "OVERRIDE_LABEL=override:no-issue")
run_check
assert_equals "$STATUS" "0" "完全一致するラベルがあればスキップする"
assert_contains "$OUT" "Issue 紐づけチェック SKIP" "スキップしたことを出力する"
assert_not_contains "$OUT" "::error title=Issue Check::" "スキップ時は ::error:: を出さない"

CHECK_ENV=("PR_BODY=${NO_LINK}" "LABELS_JSON=[\"override:no-issue-foo\"]" "OVERRIDE_LABEL=override:no-issue")
run_check
assert_equals "$STATUS" "1" "後ろに語を足したラベルではスキップしない"

CHECK_ENV=("PR_BODY=${NO_LINK}" "LABELS_JSON=[\"not-override:no-issue\"]" "OVERRIDE_LABEL=override:no-issue")
run_check
assert_equals "$STATUS" "1" "前に語を足したラベルではスキップしない"

CHECK_ENV=("PR_BODY=${NO_LINK}" "LABELS_JSON=[\"override:no-issue,bug\"]" "OVERRIDE_LABEL=override:no-issue")
run_check
assert_equals "$STATUS" "1" "カンマ連結を 1 要素にした形ではスキップしない（部分一致にしない）"

CHECK_ENV=("PR_BODY=${NO_LINK}" "LABELS_JSON=[\"OVERRIDE:NO-ISSUE\"]" "OVERRIDE_LABEL=override:no-issue")
run_check
assert_equals "$STATUS" "1" "綴りの大文字小文字が違うラベルではスキップしない（jq の比較は区別する）"

CHECK_ENV=("PR_BODY=${NO_LINK}" "LABELS_JSON=${LABELS_OVERRIDE}" "OVERRIDE_LABEL=skip:issue-link")
run_check
assert_equals "$STATUS" "1" "override-label を別名にすると既定名のラベルではスキップしない"

CHECK_ENV=("PR_BODY=${NO_LINK}" "LABELS_JSON=[\"skip:issue-link\"]" "OVERRIDE_LABEL=skip:issue-link")
run_check
assert_equals "$STATUS" "0" "override-label に指定した名前と完全一致すればスキップする"

# 4. 入力が解釈できないとき（スキップしない = fail-close）

CHECK_ENV=("PR_BODY=${NO_LINK}" "LABELS_JSON=override:no-issue" "OVERRIDE_LABEL=override:no-issue")
run_check
assert_equals "$STATUS" "1" "labels-json が JSON でなければスキップせず検査する"
assert_contains "$OUT" "::warning title=Issue Check::" "解釈できない labels-json は警告に出す"

CHECK_ENV=("PR_BODY=${NO_LINK}" "LABELS_JSON=[\"override:no-issue\"" "OVERRIDE_LABEL=override:no-issue")
run_check
assert_equals "$STATUS" "1" "labels-json が壊れた JSON ならスキップせず検査する"

CHECK_ENV=("PR_BODY=${NO_LINK}" "LABELS_JSON={\"name\":\"override:no-issue\"}" "OVERRIDE_LABEL=override:no-issue")
run_check
assert_equals "$STATUS" "1" "labels-json が配列以外の JSON ならスキップせず検査する"

CHECK_ENV=("PR_BODY=${NO_LINK}" "LABELS_JSON=null" "OVERRIDE_LABEL=override:no-issue")
run_check
assert_equals "$STATUS" "1" "labels-json が null ならスキップせず検査する"

CHECK_ENV=("PR_BODY=${NO_LINK}" "OVERRIDE_LABEL=override:no-issue")
run_check
assert_equals "$STATUS" "1" "LABELS_JSON が未設定ならスキップせず検査する"
assert_contains "$OUT" "::warning title=Issue Check::" "LABELS_JSON の未設定は警告に出す"

CHECK_ENV=("PR_BODY=Closes #5" "OVERRIDE_LABEL=override:no-issue")
run_check
assert_equals "$STATUS" "0" "LABELS_JSON が未設定でも本文に紐づけがあれば OK（本文を先に見る）"

CHECK_ENV=("PR_BODY=${NO_LINK}" "LABELS_JSON=${LABELS_OVERRIDE}" "OVERRIDE_LABEL=")
run_check
assert_equals "$STATUS" "1" "override-label が空ならスキップしない"
assert_contains "$OUT" "::warning title=Issue Check::" "override-label が空のときは警告に出す"

CHECK_ENV=("PR_BODY=${NO_LINK}" "LABELS_JSON=${LABELS_OVERRIDE}")
run_check
assert_equals "$STATUS" "1" "OVERRIDE_LABEL が未設定ならスキップしない"

CHECK_ENV=("LABELS_JSON=${LABELS_NONE}" "OVERRIDE_LABEL=override:no-issue")
run_check
assert_equals "$STATUS" "1" "PR_BODY が未設定なら入力不正として exit 1"
assert_contains "$OUT" "PR_BODY が未設定" "PR_BODY 未設定の理由を出力する"

# 5. jq の可視化と、ロジックの置き場

CHECK_ENV=("PR_BODY=Closes #5" "LABELS_JSON=${LABELS_NONE}" "OVERRIDE_LABEL=override:no-issue")
run_check
assert_contains "$OUT" "jq-" "jq のバージョンをログに残す（ランナーでの有無を可視化する）"

# jq が要るのはラベル検査だけ。jq の有無で本文検査の結論を変えない
#   （冒頭で落としていると、正しい Closes #N があっても常に exit 1 になる）。
CHECK_ENV=("PATH=${NOJQ_PATH}" "PR_BODY=Closes #5" "LABELS_JSON=${LABELS_NONE}" "OVERRIDE_LABEL=override:no-issue")
run_check
assert_equals "$STATUS" "0" "jq が無くても本文に紐づけがあれば OK（jq はラベル検査でしか使わない）"

CHECK_ENV=("PATH=${NOJQ_PATH}" "PR_BODY=${NO_LINK}" "LABELS_JSON=${LABELS_OVERRIDE}" "OVERRIDE_LABEL=override:no-issue")
run_check
assert_equals "$STATUS" "1" "jq が無いときはラベルによるスキップを行わない（fail-close）"
assert_contains "$OUT" "jq が見つからないため" "jq が無くてラベル検査を諦めたことを警告に出す"

ACTION_YML="$(cat "${ACTION_DIR}/action.yml")"
assert_contains "$ACTION_YML" "check.sh" "action.yml は check.sh を呼ぶ"
assert_not_contains "$ACTION_YML" "grep" "判定ロジックを action.yml にインライン化しない"

finish
