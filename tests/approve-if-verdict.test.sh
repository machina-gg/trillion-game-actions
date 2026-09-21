#!/bin/bash
# scripts/approve-if-verdict.sh の回帰テスト。
#
# gh をスタブに差し替え、実 API を叩かずに判定ロジックだけを検証する
# （ネットワーク・トークンが無い CI 上でも動くこと）。
#
# 最重要の回帰対象:
#   1. ⚠ **github-actions[bot] 以外の投稿者の `判定: APPROVE` では Approve しない**
#      （同一アカウントの PM / Reviewer subagent が同じ形式を投稿しても効かないことを固定する。
#      これが崩れると「自分で書いた判定行で自分の PR を Approve できる」経路が開く）
#   2. 判定行の形式は行頭固定・装飾なし・引用 / コードブロックの外・1 コメント 1 本
#      （perspectives/common.md「レビュー結果の定型フォーマット」）。外れた形は判定として読まない
#   2'. 見出しは行頭 `## レビュー` で始まること。⚠ **括弧の中身は問わない**（`## レビュー(claude)` でも読む。
#      machina-gg/trillion-game-actions#1）が、行頭でない形・コードブロックの中は見出しとして読まない
#   3. since より古いコメント / head SHA 不一致では Approve しない
#   4. Approve しない経路は exit 0（job を失敗させない）。API 失敗・解釈不能は exit 1 + UNDETERMINED（fail-close）
#   5. ⚠ **標準出力の判定ラベルが正式な判定**。ラベル文字列（APPROVED / SKIPPED_NO_VERDICT /
#      SKIPPED_REQUEST_CHANGES / SKIPPED_HEAD_MOVED / UNDETERMINED）と終了コードの対応を全ケースで固定し、
#      「そのラベルが出ること」と「他のラベルが出ないこと」を対で検査する
#   6. reviews API は APPROVE のときだけ、event=APPROVE・commit_id=head SHA で **1 回だけ**呼ばれる

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

SCRIPT="${REPO_ROOT}/scripts/approve-if-verdict.sh"

echo "== trillion-game-actions (approve-if-verdict.sh) =="

# ------------------------------------------------------------------
# 一時環境の構築
# ------------------------------------------------------------------

# mktemp -d の戻り値を検証してから trap を張る
if ! TMP="$(mktemp -d "${TMPDIR:-/tmp}/trillion-game-actions-test.XXXXXXXX")"; then
  echo "エラー: mktemp -d に失敗しました。テストを中断します。" >&2
  exit 5
fi
if [[ -z "$TMP" || ! -d "$TMP" || "$TMP" == "$PWD" ]]; then
  echo "エラー: mktemp -d の戻り値が不正です（TMP=[$TMP]）。テストを中断します。" >&2
  exit 5
fi
trap 'rm -rf "$TMP"' EXIT

# フィクスチャ構築中のエラーは即座に落として気付けるようにする
set -e

# gh のスタブ。TG_TEST_FIXTURE のディレクトリにある JSON を返すだけで、ネットワークには出ない。
#   - `api repos/<r>/issues/<N>/comments…` → comments.json（--paginate 時は comments.2.json も続けて出す）
#     comments.fail があれば失敗
#   - `api -X POST repos/<r>/pulls/<N>/reviews --input <file>` → calls.log に「POST <path>」と入力 JSON を
#     追記し、reviews-response.json（無ければ state=APPROVED の既定応答）を返す。reviews.fail があれば失敗
#   - `api repos/<r>/pulls/<N>` → pr.json（--jq を解釈する）。pr.fail があれば失敗
mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/gh" <<'GH_STUB'
#!/bin/bash
# テスト用 gh スタブ（実 API は叩かない）
FIXTURE="${TG_TEST_FIXTURE:?TG_TEST_FIXTURE が未設定}"

if [[ "${1:-}" != "api" ]]; then
  echo "スタブ未対応のサブコマンド: ${1:-}" >&2
  exit 1
fi
shift

METHOD="GET"
INPUT_FILE=""
JQ_FILTER=""
PAGINATE=false
API_PATH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -X) METHOD="$2"; shift 2 ;;
    --input) INPUT_FILE="$2"; shift 2 ;;
    --jq) JQ_FILTER="$2"; shift 2 ;;
    --paginate) PAGINATE=true; shift ;;
    *) API_PATH="$1"; shift ;;
  esac
done

emit() {
  if [[ -n "$JQ_FILTER" ]]; then
    jq -r "$JQ_FILTER"
  else
    cat
  fi
}

case "$API_PATH" in
  */issues/*/comments*)
    if [[ -f "${FIXTURE}/comments.fail" ]]; then
      echo "スタブ: コメント一覧の取得に失敗" >&2
      exit 1
    fi
    emit < "${FIXTURE}/comments.json"
    if [[ "$PAGINATE" == true && -f "${FIXTURE}/comments.2.json" ]]; then
      emit < "${FIXTURE}/comments.2.json"
    fi
    ;;
  */pulls/*/reviews)
    {
      echo "${METHOD} ${API_PATH}"
      if [[ -n "$INPUT_FILE" ]]; then cat "$INPUT_FILE"; echo; fi
    } >> "${FIXTURE}/calls.log"
    if [[ -f "${FIXTURE}/reviews.fail" ]]; then
      echo "スタブ: reviews API の失敗（Resource not accessible by integration）" >&2
      exit 1
    fi
    if [[ -f "${FIXTURE}/reviews-response.json" ]]; then
      emit < "${FIXTURE}/reviews-response.json"
    else
      printf '%s\n' '{"id": 1, "state": "APPROVED"}' | emit
    fi
    ;;
  */pulls/*)
    if [[ -f "${FIXTURE}/pr.fail" ]]; then
      echo "スタブ: PR 情報の取得に失敗" >&2
      exit 1
    fi
    emit < "${FIXTURE}/pr.json"
    ;;
  *)
    echo "スタブ未対応の API パス: ${API_PATH}" >&2
    exit 1
    ;;
esac
GH_STUB
chmod +x "${TMP}/bin/gh"
export PATH="${TMP}/bin:${PATH}"

HEAD_SHA="a55a60e5663e330eba258c7d20daadcf9fee816b"
OLD_SHA="17304c1c501e72d64a6f3a6a802fb0b6e26348f0"
BOT="github-actions[bot]"
SINCE="2026-09-13T10:00:00Z"
# since 以降の投稿時刻（同時刻ちょうどは含める）
T_AFTER="2026-09-13T10:05:00Z"
T_AFTER_LATE="2026-09-13T10:06:00Z"
T_BEFORE="2026-09-13T09:59:59Z"

# review-pr の定型どおりの本文
BODY_APPROVE="$(
  cat <<'EOF'
## レビュー(reviewer)
判定: APPROVE
観点: [事実検証 / SSOT 整合]
指摘:
なし
未解決:
なし
EOF
)"
BODY_REQUEST_CHANGES="${BODY_APPROVE//判定: APPROVE/判定: REQUEST_CHANGES}"
# 装飾つき（行頭が `**` なので判定行ではない）
BODY_DECORATED="${BODY_APPROVE//判定: APPROVE/**判定: APPROVE**}"
# 引用（行頭が `>`）
BODY_QUOTED="${BODY_APPROVE//判定: APPROVE/> 判定: APPROVE}"
# 先頭に空白
BODY_INDENTED="${BODY_APPROVE//判定: APPROVE/  判定: APPROVE}"
# 全角コロン
BODY_FULLWIDTH_COLON="${BODY_APPROVE//判定: APPROVE/判定： APPROVE}"
# 見出しが無い（定型ではない投稿）
BODY_NO_HEADER="${BODY_APPROVE//## レビュー(reviewer)/## 講評}"
# 見出しの括弧の中身が揺れた（Reviewer が役割名ではなく自分の名前を書いた形。Issue #1）
BODY_HEADER_CLAUDE="${BODY_APPROVE//## レビュー(reviewer)/## レビュー(claude)}"
# 見出しが引用の中にある（行頭ではないので見出しとして読まない）
BODY_HEADER_QUOTED="${BODY_APPROVE//## レビュー(reviewer)/> ## レビュー(reviewer)}"
# 見出しがコードブロックの中にしかない（定型の説明を引用しただけの投稿）
BODY_HEADER_IN_CODE_BLOCK="$(
  cat <<'EOF'
定型は次のとおり:
```
## レビュー(reviewer)
```
判定: APPROVE
EOF
)"
# 見出しの字下げ（Markdown の見出しとして許容される 3 スペースまで / 4 スペースはコードブロック）。
# ⚠ 上下 2 本で境界を挟む。許容側だけだと `^ {0,3}` を広げる変異（{0,6} 等）が素通りする
BODY_HEADER_INDENT3="${BODY_APPROVE//## レビュー(reviewer)/   ## レビュー(reviewer)}"
BODY_HEADER_INDENT4="${BODY_APPROVE//## レビュー(reviewer)/    ## レビュー(reviewer)}"
# 定型のテンプレートをそのまま写した値（APPROVE でも REQUEST_CHANGES でもない）
BODY_TEMPLATE_VALUE="${BODY_APPROVE//判定: APPROVE/判定: APPROVE / REQUEST_CHANGES}"
# 判定行が 2 本（過去の判定の再掲）
BODY_TWO_VERDICTS="$(
  cat <<'EOF'
## レビュー(reviewer)
判定: APPROVE
観点: [事実検証]
指摘:
なし
未解決:
なし
判定: REQUEST_CHANGES
EOF
)"
# コードブロックの中にだけ判定行がある（フォーマットの説明を引用しただけの投稿）
BODY_CODE_BLOCK_ONLY="$(
  cat <<'EOF'
## レビュー(reviewer)
定型は次のとおり:
```
判定: APPROVE
```
観点: [事実検証]
EOF
)"
# コードブロックの中に判定行があり、外にも本物の判定行が 1 本ある（外の 1 本だけを数える）
BODY_CODE_BLOCK_AND_REAL="$(
  cat <<'EOF'
## レビュー(reviewer)
判定: REQUEST_CHANGES
観点: [事実検証]
指摘:
1. tests/x.sh:1 定型は次のとおりに書く — SKILL.md
```
判定: APPROVE
```
未解決:
なし
EOF
)"
# ~~~ フェンス
BODY_TILDE_FENCE="${BODY_CODE_BLOCK_ONLY//\`\`\`/~~~}"
# CRLF 改行（GitHub の UI 経由の投稿で起こる形）
BODY_CRLF="${BODY_APPROVE//$'\n'/$'\r\n'}"
# 判定行の末尾に空白
BODY_TRAILING_SPACE="${BODY_APPROVE//判定: APPROVE/判定: APPROVE  }"
# 公式 Action の進捗コメント（見出し無し。判定行を含まない）
BODY_TRACKING="**Claude finished @machina-gg's task** —— [View job](https://example.invalid/run)"

# コメント 1 件分の JSON を作る
make_comment() { # $1=id $2=login $3=created_at $4=body
  jq -n --argjson i "$1" --arg l "$2" --arg t "$3" --arg b "$4" \
    '{id: $i, html_url: ("https://github.com/machina-gg/example-repo/pull/1110#issuecomment-" + ($i | tostring)), created_at: $t, user: {login: $l}, body: $b}'
}

# フィクスチャを 1 ケース分作る。
#   $1 = ケース名, $2 = head.sha, $3 = コメント JSON（0 個以上を連結したもの）
make_fixture() {
  local name="$1" sha="$2" comments="$3"
  local dir="${TMP}/${name}"
  mkdir -p "$dir"
  jq -n --arg sha "$sha" '{state: "open", head: {sha: $sha}}' > "${dir}/pr.json"
  # jq -s は連結された JSON 値の並びを配列に束ねる（空入力なら []）
  jq -s '.' > "${dir}/comments.json" <<< "$comments"
}

C_BOT_APPROVE="$(make_comment 1 "$BOT" "$T_AFTER" "$BODY_APPROVE")"
C_BOT_REQUEST="$(make_comment 2 "$BOT" "$T_AFTER" "$BODY_REQUEST_CHANGES")"
C_BOT_OLD_APPROVE="$(make_comment 3 "$BOT" "$T_BEFORE" "$BODY_APPROVE")"
C_HUMAN_APPROVE="$(make_comment 4 "machina-gg" "$T_AFTER" "$BODY_APPROVE")"
C_CLAUDE_BOT_APPROVE="$(make_comment 5 "claude[bot]" "$T_AFTER" "$BODY_APPROVE")"
C_BOT_DECORATED="$(make_comment 6 "$BOT" "$T_AFTER" "$BODY_DECORATED")"
C_BOT_QUOTED="$(make_comment 7 "$BOT" "$T_AFTER" "$BODY_QUOTED")"
C_BOT_INDENTED="$(make_comment 8 "$BOT" "$T_AFTER" "$BODY_INDENTED")"
C_BOT_FULLWIDTH="$(make_comment 9 "$BOT" "$T_AFTER" "$BODY_FULLWIDTH_COLON")"
C_BOT_NO_HEADER="$(make_comment 10 "$BOT" "$T_AFTER" "$BODY_NO_HEADER")"
C_BOT_TEMPLATE_VALUE="$(make_comment 11 "$BOT" "$T_AFTER" "$BODY_TEMPLATE_VALUE")"
C_BOT_TWO_VERDICTS="$(make_comment 12 "$BOT" "$T_AFTER" "$BODY_TWO_VERDICTS")"
C_BOT_CODE_ONLY="$(make_comment 13 "$BOT" "$T_AFTER" "$BODY_CODE_BLOCK_ONLY")"
C_BOT_CODE_AND_REAL="$(make_comment 14 "$BOT" "$T_AFTER" "$BODY_CODE_BLOCK_AND_REAL")"
C_BOT_TILDE="$(make_comment 15 "$BOT" "$T_AFTER" "$BODY_TILDE_FENCE")"
C_BOT_CRLF="$(make_comment 16 "$BOT" "$T_AFTER" "$BODY_CRLF")"
C_BOT_TRAILING="$(make_comment 17 "$BOT" "$T_AFTER" "$BODY_TRAILING_SPACE")"
C_BOT_TRACKING="$(make_comment 18 "$BOT" "$T_AFTER" "$BODY_TRACKING")"
C_BOT_APPROVE_AT_SINCE="$(make_comment 19 "$BOT" "$SINCE" "$BODY_APPROVE")"
C_BOT_REQUEST_LATE="$(make_comment 20 "$BOT" "$T_AFTER_LATE" "$BODY_REQUEST_CHANGES")"
C_BOT_APPROVE_LATE="$(make_comment 21 "$BOT" "$T_AFTER_LATE" "$BODY_APPROVE")"
C_BOT_HEADER_CLAUDE="$(make_comment 22 "$BOT" "$T_AFTER" "$BODY_HEADER_CLAUDE")"
C_BOT_HEADER_QUOTED="$(make_comment 23 "$BOT" "$T_AFTER" "$BODY_HEADER_QUOTED")"
C_BOT_HEADER_IN_CODE="$(make_comment 24 "$BOT" "$T_AFTER" "$BODY_HEADER_IN_CODE_BLOCK")"
C_BOT_HEADER_INDENT3="$(make_comment 25 "$BOT" "$T_AFTER" "$BODY_HEADER_INDENT3")"
C_BOT_HEADER_INDENT4="$(make_comment 26 "$BOT" "$T_AFTER" "$BODY_HEADER_INDENT4")"

# --- 正常系 ---
make_fixture approve "$HEAD_SHA" "$C_BOT_APPROVE"
make_fixture request_changes "$HEAD_SHA" "$C_BOT_REQUEST"
make_fixture no_comments "$HEAD_SHA" ""
make_fixture tracking_then_approve "$HEAD_SHA" "${C_BOT_TRACKING}
${C_BOT_APPROVE}"
make_fixture approve_at_since "$HEAD_SHA" "$C_BOT_APPROVE_AT_SINCE"
make_fixture crlf "$HEAD_SHA" "$C_BOT_CRLF"
make_fixture trailing_space "$HEAD_SHA" "$C_BOT_TRAILING"
make_fixture code_block_and_real "$HEAD_SHA" "$C_BOT_CODE_AND_REAL"
# 見出しの括弧の中身が揺れても候補になる（Issue #1 の再発防止）
make_fixture header_claude "$HEAD_SHA" "$C_BOT_HEADER_CLAUDE"
make_fixture header_indent3 "$HEAD_SHA" "$C_BOT_HEADER_INDENT3"
# 複数候補は created_at が最大の 1 件（古い APPROVE + 新しい REQUEST_CHANGES → 何もしない / 逆 → Approve）
make_fixture approve_then_request "$HEAD_SHA" "${C_BOT_APPROVE}
${C_BOT_REQUEST_LATE}"
make_fixture request_then_approve "$HEAD_SHA" "${C_BOT_REQUEST}
${C_BOT_APPROVE_LATE}"
# --paginate の 2 ページ目にだけ判定行がある
make_fixture paginated "$HEAD_SHA" "$C_BOT_TRACKING"
jq -s '.' > "${TMP}/paginated/comments.2.json" <<< "$C_BOT_APPROVE"

# --- 判定として読まない形（Approve しない・exit 0）---
make_fixture old_comment "$HEAD_SHA" "$C_BOT_OLD_APPROVE"
make_fixture human_author "$HEAD_SHA" "$C_HUMAN_APPROVE"
make_fixture claude_bot_author "$HEAD_SHA" "$C_CLAUDE_BOT_APPROVE"
make_fixture decorated "$HEAD_SHA" "$C_BOT_DECORATED"
make_fixture quoted "$HEAD_SHA" "$C_BOT_QUOTED"
make_fixture indented "$HEAD_SHA" "$C_BOT_INDENTED"
make_fixture fullwidth_colon "$HEAD_SHA" "$C_BOT_FULLWIDTH"
make_fixture no_header "$HEAD_SHA" "$C_BOT_NO_HEADER"
make_fixture header_quoted "$HEAD_SHA" "$C_BOT_HEADER_QUOTED"
make_fixture header_in_code_block "$HEAD_SHA" "$C_BOT_HEADER_IN_CODE"
make_fixture header_indent4 "$HEAD_SHA" "$C_BOT_HEADER_INDENT4"
make_fixture template_value "$HEAD_SHA" "$C_BOT_TEMPLATE_VALUE"
make_fixture two_verdicts "$HEAD_SHA" "$C_BOT_TWO_VERDICTS"
make_fixture code_block_only "$HEAD_SHA" "$C_BOT_CODE_ONLY"
make_fixture tilde_fence "$HEAD_SHA" "$C_BOT_TILDE"
# head が動いた（PR の head.sha が引数と違う）
make_fixture head_moved "$OLD_SHA" "$C_BOT_APPROVE"

# --- 判定不能（exit 1）---
make_fixture comments_fail "$HEAD_SHA" "$C_BOT_APPROVE"
touch "${TMP}/comments_fail/comments.fail"
make_fixture comments_not_array "$HEAD_SHA" "$C_BOT_APPROVE"
printf '%s\n' '{"message":"Not Found"}' > "${TMP}/comments_not_array/comments.json"
make_fixture pr_fail "$HEAD_SHA" "$C_BOT_APPROVE"
touch "${TMP}/pr_fail/pr.fail"
make_fixture no_head_sha "$HEAD_SHA" "$C_BOT_APPROVE"
printf '%s\n' '{"state":"open","head":{}}' > "${TMP}/no_head_sha/pr.json"
make_fixture reviews_fail "$HEAD_SHA" "$C_BOT_APPROVE"
touch "${TMP}/reviews_fail/reviews.fail"
make_fixture reviews_not_approved "$HEAD_SHA" "$C_BOT_APPROVE"
printf '%s\n' '{"id": 2, "state": "PENDING"}' > "${TMP}/reviews_not_approved/reviews-response.json"
# body が文字列でない要素（jq の式が評価できず失敗する形。⚠ 「候補なし」へ倒さない。PR #1111 の Copilot 指摘）
make_fixture body_not_string "$HEAD_SHA" "$C_BOT_APPROVE"
jq --arg l "$BOT" --arg t "$T_AFTER" '. + [{id: 99, html_url: "https://example.invalid/99", created_at: $t, user: {login: $l}, body: 5}]' \
  "${TMP}/body_not_string/comments.json" > "${TMP}/body_not_string/comments.tmp"
mv "${TMP}/body_not_string/comments.tmp" "${TMP}/body_not_string/comments.json"
# body が null の要素（API 上あり得る形。空文字として扱い、失敗にはしない）
make_fixture body_null "$HEAD_SHA" ""
jq -n --arg l "$BOT" --arg t "$T_AFTER" '[{id: 98, html_url: "https://example.invalid/98", created_at: $t, user: {login: $l}, body: null}]' \
  > "${TMP}/body_null/comments.json"

# 判定を出さずに終わる経路の再現（BASH_ENV で本体を触らずに変異を注入する）
printf '%s\n' 'readonly COMMENTS_JSON=""' > "${TMP}/readonly-comments.sh"

# フィクスチャ構築はここまで。以降はアサーションのため set -e を解除する
set +e

# ------------------------------------------------------------------
# 実行ヘルパー
# ------------------------------------------------------------------

ALL_LABELS=(APPROVED SKIPPED_NO_VERDICT SKIPPED_REQUEST_CHANGES SKIPPED_HEAD_MOVED UNDETERMINED)

# 直前の実行が「期待したラベルだけを出し、それが最後の行であること」を検証する
assert_label() { # $1 = 期待するラベル, $2 = 説明
  local expected="$1" desc="$2" other last_line
  assert_contains "$OUT" "$expected" "[label] ${desc}: ${expected} を出力する"
  for other in "${ALL_LABELS[@]}"; do
    [[ "$other" == "$expected" ]] && continue
    assert_not_contains "$OUT" "$other" "[label] ${desc}: ${other} は出力しない"
  done
  last_line="${OUT##*$'\n'}"
  assert_contains "$last_line" "$expected" "[label] ${desc}: ラベルは標準出力の最後の行にある"
}

# reviews API（POST）の呼び出し回数を検証する
assert_post_count() { # $1 = フィクスチャ名, $2 = 期待回数, $3 = 説明
  local log="${TMP}/${1}/calls.log" n=0
  if [[ -f "$log" ]]; then
    n=$(command grep -c '^POST ' "$log")
  fi
  assert_equals "$n" "$2" "$3"
}

# AR_ENV=("VAR=値" ...) を直前に設定すると、その環境変数を上書きできる（1 回限り）
AR_ENV=()
run_approve() { # $1 = フィクスチャ名, $2... = スクリプトへの引数
  local fixture="$1"
  shift
  OUT="$(env TG_TEST_FIXTURE="${TMP}/${fixture}" GITHUB_REPOSITORY="machina-gg/example-repo" \
    TG_AGENT_REVIEW_GH_RETRY_INTERVAL=0 \
    ${AR_ENV[@]+"${AR_ENV[@]}"} \
    bash "$SCRIPT" "$@" 2>&1)"
  STATUS=$?
  AR_ENV=()
}

# ------------------------------------------------------------------
# APPROVE → reviews API が event=APPROVE・commit_id=head で 1 回だけ呼ばれる
# ------------------------------------------------------------------

run_approve approve 1110 "$SINCE" "$HEAD_SHA"
assert_equals "$STATUS" "0" "github-actions[bot] の 判定: APPROVE（since 以降・head 一致）は exit 0"
assert_label APPROVED "APPROVE"
assert_post_count approve 1 "reviews API は 1 回だけ呼ばれる"
assert_contains "$(cat "${TMP}/approve/calls.log")" "POST repos/machina-gg/example-repo/pulls/1110/reviews" "POST 先は対象 PR の reviews"
assert_contains "$(cat "${TMP}/approve/calls.log")" '"event":"APPROVE"' "event=APPROVE で呼ばれる"
assert_contains "$(cat "${TMP}/approve/calls.log")" "\"commit_id\":\"${HEAD_SHA}\"" "commit_id に head SHA を渡す"
assert_contains "$(cat "${TMP}/approve/calls.log")" "issuecomment-1" "Approve 本文に元コメントの URL を書く"
assert_contains "$OUT" "issuecomment-1" "採用したコメントの URL が出力される"

run_approve approve_at_since 1110 "$SINCE" "$HEAD_SHA"
assert_equals "$STATUS" "0" "created_at が since と同時刻のコメントは対象に含める"
assert_label APPROVED "since と同時刻"
assert_post_count approve_at_since 1 "同時刻でも reviews API が呼ばれる"

run_approve tracking_then_approve 1110 "$SINCE" "$HEAD_SHA"
assert_equals "$STATUS" "0" "公式 Action の進捗コメント（見出し無し）が混ざっていても本物の判定で Approve する"
assert_label APPROVED "進捗コメントとの混在"
assert_post_count tracking_then_approve 1 "進捗コメントは無視され、reviews API は 1 回"

run_approve crlf 1110 "$SINCE" "$HEAD_SHA"
assert_equals "$STATUS" "0" "CRLF 改行の本文でも判定行を読める"
assert_label APPROVED "CRLF"

run_approve trailing_space 1110 "$SINCE" "$HEAD_SHA"
assert_equals "$STATUS" "0" "判定行の末尾の空白は無視する"
assert_label APPROVED "末尾の空白"

run_approve request_then_approve 1110 "$SINCE" "$HEAD_SHA"
assert_equals "$STATUS" "0" "候補が複数あれば created_at が最大の 1 件（後の APPROVE）を採る"
assert_label APPROVED "REQUEST_CHANGES → APPROVE の順"
assert_post_count request_then_approve 1 "最新の判定が APPROVE なら reviews API は 1 回"

run_approve paginated 1110 "$SINCE" "$HEAD_SHA"
assert_equals "$STATUS" "0" "--paginate の 2 ページ目にある判定行も読む"
assert_label APPROVED "2 ページ目"
assert_post_count paginated 1 "2 ページ目の判定で reviews API が呼ばれる"

run_approve header_claude 1110 "$SINCE" "$HEAD_SHA"
assert_equals "$STATUS" "0" "見出しの括弧の中身が違っても（## レビュー(claude)）判定を読む（Issue #1）"
assert_label APPROVED "見出しの括弧の揺れ"
assert_post_count header_claude 1 "括弧の中身が違っても reviews API は 1 回呼ばれる"

run_approve header_indent3 1110 "$SINCE" "$HEAD_SHA"
assert_equals "$STATUS" "0" "見出しの字下げ 3 スペースまでは Markdown の見出しとして読む"
assert_label APPROVED "見出しの字下げ 3 スペース"
assert_post_count header_indent3 1 "字下げ 3 スペースでは reviews API が 1 回呼ばれる"

run_approve code_block_and_real 1110 "$SINCE" "$HEAD_SHA"
assert_equals "$STATUS" "0" "コードブロック内の判定行は数えず、外の 1 本（REQUEST_CHANGES）で判定する"
assert_label SKIPPED_REQUEST_CHANGES "コードブロック内 APPROVE + 外 REQUEST_CHANGES"
assert_post_count code_block_and_real 0 "コードブロック内の APPROVE では reviews API を呼ばない"

# ------------------------------------------------------------------
# Approve しない（exit 0・job を失敗させない）
# ------------------------------------------------------------------

run_approve request_changes 1110 "$SINCE" "$HEAD_SHA"
assert_equals "$STATUS" "0" "REQUEST_CHANGES は何もせず exit 0（job を失敗させない）"
assert_label SKIPPED_REQUEST_CHANGES "REQUEST_CHANGES"
assert_post_count request_changes 0 "REQUEST_CHANGES では reviews API を呼ばない"

run_approve approve_then_request 1110 "$SINCE" "$HEAD_SHA"
assert_equals "$STATUS" "0" "古い APPROVE + 新しい REQUEST_CHANGES は最新の判定に従う"
assert_label SKIPPED_REQUEST_CHANGES "APPROVE → REQUEST_CHANGES の順"
assert_post_count approve_then_request 0 "古い APPROVE では reviews API を呼ばない"

run_approve no_comments 1110 "$SINCE" "$HEAD_SHA"
assert_equals "$STATUS" "0" "コメント 0 件は何もせず exit 0"
assert_label SKIPPED_NO_VERDICT "コメント 0 件"
assert_post_count no_comments 0 "コメント 0 件では reviews API を呼ばない"

run_approve old_comment 1110 "$SINCE" "$HEAD_SHA"
assert_equals "$STATUS" "0" "since より古いコメントの APPROVE は読まない（exit 0）"
assert_label SKIPPED_NO_VERDICT "since より古い"
assert_post_count old_comment 0 "since より古い APPROVE では reviews API を呼ばない"

# ⚠ 本テストの中心: 同一アカウント（PM / Reviewer subagent）が同じ形式を投稿しても効かない
run_approve human_author 1110 "$SINCE" "$HEAD_SHA"
assert_equals "$STATUS" "0" "github-actions[bot] 以外（machina-gg）の APPROVE は読まない（exit 0）"
assert_label SKIPPED_NO_VERDICT "投稿者が machina-gg"
assert_post_count human_author 0 "⚠ 同一アカウントの投稿では reviews API を呼ばない（本仕組みの要）"

run_approve claude_bot_author 1110 "$SINCE" "$HEAD_SHA"
assert_equals "$STATUS" "0" "claude[bot] の APPROVE も読まない（身元は github-actions[bot] に固定）"
assert_label SKIPPED_NO_VERDICT "投稿者が claude[bot]"
assert_post_count claude_bot_author 0 "claude[bot] の投稿では reviews API を呼ばない"

# 判定行の形式（SKILL.md「判定: 行は行頭固定・表記ゆれ禁止」）
run_approve decorated 1110 "$SINCE" "$HEAD_SHA"
assert_equals "$STATUS" "0" "装飾つき（**判定: APPROVE**）は判定として読まない"
assert_label SKIPPED_NO_VERDICT "装飾つき"
assert_post_count decorated 0 "装飾つきでは reviews API を呼ばない"

run_approve quoted 1110 "$SINCE" "$HEAD_SHA"
assert_equals "$STATUS" "0" "引用（> 判定: APPROVE）は判定として読まない"
assert_label SKIPPED_NO_VERDICT "引用"
assert_post_count quoted 0 "引用では reviews API を呼ばない"

run_approve indented 1110 "$SINCE" "$HEAD_SHA"
assert_equals "$STATUS" "0" "先頭に空白がある判定行は読まない（行頭固定）"
assert_label SKIPPED_NO_VERDICT "先頭に空白"
assert_post_count indented 0 "先頭に空白では reviews API を呼ばない"

run_approve fullwidth_colon 1110 "$SINCE" "$HEAD_SHA"
assert_equals "$STATUS" "0" "全角コロン（判定：）は読まない"
assert_label SKIPPED_NO_VERDICT "全角コロン"
assert_post_count fullwidth_colon 0 "全角コロンでは reviews API を呼ばない"

run_approve no_header 1110 "$SINCE" "$HEAD_SHA"
assert_equals "$STATUS" "0" "見出し（行頭 ## レビュー）が無い投稿は読まない"
assert_label SKIPPED_NO_VERDICT "見出し無し"
assert_post_count no_header 0 "見出し無しでは reviews API を呼ばない"

run_approve header_quoted 1110 "$SINCE" "$HEAD_SHA"
assert_equals "$STATUS" "0" "見出しが行頭でない（> ## レビュー(reviewer)）投稿は読まない"
assert_label SKIPPED_NO_VERDICT "見出しが引用の中"
assert_post_count header_quoted 0 "行頭でない見出しでは reviews API を呼ばない"

run_approve header_in_code_block 1110 "$SINCE" "$HEAD_SHA"
assert_equals "$STATUS" "0" "見出しがコードブロックの中にしかない投稿は読まない"
assert_label SKIPPED_NO_VERDICT "見出しがコードブロック内"
assert_post_count header_in_code_block 0 "コードブロック内の見出しでは reviews API を呼ばない"

# ⚠ 上の header_indent3（許容側）と対で字下げの境界を挟む。片側だけだと `^ {0,3}` を
#   広げる変異（{0,6} 等）が素通りする
run_approve header_indent4 1110 "$SINCE" "$HEAD_SHA"
assert_equals "$STATUS" "0" "見出しの字下げ 4 スペースは読まない（Markdown ではコードブロック）"
assert_label SKIPPED_NO_VERDICT "見出しの字下げ 4 スペース"
assert_post_count header_indent4 0 "字下げ 4 スペースでは reviews API を呼ばない"

run_approve template_value 1110 "$SINCE" "$HEAD_SHA"
assert_equals "$STATUS" "0" "テンプレートをそのまま写した値（APPROVE / REQUEST_CHANGES）は判定として読まない"
assert_label SKIPPED_NO_VERDICT "テンプレートの値"
assert_post_count template_value 0 "解釈できない値では reviews API を呼ばない（APPROVE 側へ倒さない）"

run_approve two_verdicts 1110 "$SINCE" "$HEAD_SHA"
assert_equals "$STATUS" "0" "1 コメントに判定行が 2 本あれば読まない"
assert_label SKIPPED_NO_VERDICT "判定行 2 本"
assert_post_count two_verdicts 0 "判定行 2 本では reviews API を呼ばない"

run_approve code_block_only 1110 "$SINCE" "$HEAD_SHA"
assert_equals "$STATUS" "0" "コードブロック（バッククォート 3 つのフェンス）の中の判定行は読まない"
assert_label SKIPPED_NO_VERDICT "コードブロック内"
assert_post_count code_block_only 0 "コードブロック内では reviews API を呼ばない"

run_approve tilde_fence 1110 "$SINCE" "$HEAD_SHA"
assert_equals "$STATUS" "0" "~~~ フェンスの中の判定行も読まない"
assert_label SKIPPED_NO_VERDICT "~~~ フェンス内"
assert_post_count tilde_fence 0 "~~~ フェンス内では reviews API を呼ばない"

run_approve head_moved 1110 "$SINCE" "$HEAD_SHA"
assert_equals "$STATUS" "0" "head SHA が引数と一致しなければ何もせず exit 0"
assert_label SKIPPED_HEAD_MOVED "head 不一致"
assert_post_count head_moved 0 "head 不一致では reviews API を呼ばない"
assert_contains "$OUT" "$OLD_SHA" "実際の head.sha が出力される"

# ------------------------------------------------------------------
# 判定不能（exit 1・fail-close）
# ------------------------------------------------------------------

run_approve reviews_fail 1110 "$SINCE" "$HEAD_SHA"
assert_equals "$STATUS" "1" "reviews API が失敗したら exit 1"
assert_label UNDETERMINED "reviews API の失敗"
assert_contains "$OUT" "Allow GitHub Actions to create and approve pull requests" "リポ設定の確認を案内する"

run_approve reviews_not_approved 1110 "$SINCE" "$HEAD_SHA"
assert_equals "$STATUS" "1" "reviews API の応答 state が APPROVED でなければ exit 1"
assert_label UNDETERMINED "応答が APPROVED ではない"

run_approve comments_fail 1110 "$SINCE" "$HEAD_SHA"
assert_equals "$STATUS" "1" "コメント一覧の取得に失敗したら exit 1"
assert_label UNDETERMINED "コメント一覧の取得失敗"
assert_post_count comments_fail 0 "取得失敗では reviews API を呼ばない"

run_approve comments_not_array 1110 "$SINCE" "$HEAD_SHA"
assert_equals "$STATUS" "1" "コメント一覧が配列でない応答は exit 1（0 件へ倒さない）"
assert_label UNDETERMINED "非配列の応答"

run_approve pr_fail 1110 "$SINCE" "$HEAD_SHA"
assert_equals "$STATUS" "1" "PR 情報の取得に失敗したら exit 1"
assert_label UNDETERMINED "PR 情報の取得失敗"
assert_post_count pr_fail 0 "head を確かめられなければ reviews API を呼ばない"

run_approve no_head_sha 1110 "$SINCE" "$HEAD_SHA"
assert_equals "$STATUS" "1" "head.sha を解釈できなければ exit 1"
assert_label UNDETERMINED "head.sha の欠落"
assert_post_count no_head_sha 0 "head.sha 欠落では reviews API を呼ばない"

run_approve body_not_string 1110 "$SINCE" "$HEAD_SHA"
assert_equals "$STATUS" "1" "判定行の抽出（jq）が失敗したら exit 1（「候補なし」へ倒さない。PR #1111 の Copilot 指摘）"
assert_label UNDETERMINED "判定行の抽出に失敗"
assert_post_count body_not_string 0 "抽出に失敗したら reviews API を呼ばない"

run_approve body_null 1110 "$SINCE" "$HEAD_SHA"
assert_equals "$STATUS" "0" "body が null のコメントは空文字として扱い、失敗にしない（exit 0）"
assert_label SKIPPED_NO_VERDICT "body が null"

# 判定を出さずに終わったら UNDETERMINED（exit 1）に倒す
AR_ENV=("BASH_ENV=${TMP}/readonly-comments.sh")
run_approve approve 1110 "$SINCE" "$HEAD_SHA"
assert_equals "$STATUS" "1" "fatal なシェルエラーは判定不能（exit 1）に倒す"
assert_label UNDETERMINED "判定を出さずに終わった経路（EXIT trap）"

# ------------------------------------------------------------------
# 引数・環境変数の検査（exit 1）とヘルプ
# ------------------------------------------------------------------

run_approve approve 1110 "$SINCE"
assert_equals "$STATUS" "1" "引数が 2 つなら exit 1"
assert_label UNDETERMINED "引数不足"

run_approve approve abc "$SINCE" "$HEAD_SHA"
assert_equals "$STATUS" "1" "PR 番号が数値でなければ exit 1"
assert_label UNDETERMINED "PR 番号が非数値"

run_approve approve 1110 "2026-09-13 10:00:00" "$HEAD_SHA"
assert_equals "$STATUS" "1" "since が ISO 8601 UTC でなければ exit 1"
assert_label UNDETERMINED "since の形式不正"

run_approve approve 1110 "$SINCE" "a55a60e5"
assert_equals "$STATUS" "1" "head SHA が 40 桁でなければ exit 1"
assert_label UNDETERMINED "head SHA の形式不正"

AR_ENV=("GITHUB_REPOSITORY=")
run_approve approve 1110 "$SINCE" "$HEAD_SHA"
assert_equals "$STATUS" "1" "GITHUB_REPOSITORY が空なら exit 1"
assert_label UNDETERMINED "GITHUB_REPOSITORY 未設定"

AR_ENV=("TG_AGENT_REVIEW_GH_RETRIES=nope")
run_approve approve 1110 "$SINCE" "$HEAD_SHA"
assert_equals "$STATUS" "1" "TG_AGENT_REVIEW_GH_RETRIES が非数値なら exit 1"
assert_label UNDETERMINED "設定値が非数値"

run_approve approve -h
assert_equals "$STATUS" "0" "-h は exit 0"
assert_contains "$OUT" "使い方: approve-if-verdict.sh" "-h で使い方が表示される"
for _label in "${ALL_LABELS[@]}"; do
  assert_not_contains "$OUT" "$_label" "-h はラベルを出さない（判定ではないため）: ${_label}"
done

run_approve approve --help
assert_equals "$STATUS" "0" "--help も単独指定なら exit 0"

run_approve approve -h 1110
assert_equals "$STATUS" "1" "-h を他の引数と併用した形は exit 1（ラベル無しの exit 0 にしない）"
assert_label UNDETERMINED "-h の併用"

finish
