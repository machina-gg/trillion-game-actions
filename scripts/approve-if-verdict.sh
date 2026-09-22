#!/bin/bash
# レビューコメントの判定行を読んで PR を Approve する。
#
# reusable workflow（.github/workflows/review.yml）の最終ステップから、呼び出し元リポジトリへ
# checkout された写しとして呼ばれる。Approve を押す手段は Claude に渡さず、判定行の抽出と
# Approve の実行だけをこのスクリプトが担う。
#
# 使い方:
#   approve-if-verdict.sh <PR番号> <since（ISO 8601 UTC・秒精度）> <head SHA（40 桁）>
#   対象リポジトリは GITHUB_REPOSITORY、gh の認証は GH_TOKEN から取る。
#
# 判定の順序（上から評価し、最初に当たったところで止まる）:
#   1. 引数と環境変数の形を検査する（不正なら UNDETERMINED）
#   2. Issue コメントのうち、投稿者が github-actions[bot]・created_at が since 以上・コードブロックの
#      外に行頭 `## レビュー` の見出しが 1 本以上・行頭 `判定: ` の行がちょうど 1 本、をすべて
#      満たすものを候補にし、created_at が最大の 1 件を採る
#   3. 候補が無ければ SKIPPED_NO_VERDICT
#   4. 判定が REQUEST_CHANGES なら SKIPPED_REQUEST_CHANGES。
#      APPROVE / REQUEST_CHANGES 以外の値も Approve せず SKIPPED_NO_VERDICT に倒す
#   5. PR の head.sha が引数と一致しなければ SKIPPED_HEAD_MOVED
#   6. reviews API に event=APPROVE・commit_id=head SHA で POST し、state が APPROVED なら APPROVED
#
# 終了コード: 0 = Approve した / Approve しない理由が確定した、1 = 判定不能（fail-close）。
# Approve しない経路で job を失敗させない（Approve が付かないことと CI が赤いことで PR が二重に止まる）。
# 標準出力の最後の行が判定ラベル（APPROVED / SKIPPED_NO_VERDICT / SKIPPED_REQUEST_CHANGES /
# SKIPPED_HEAD_MOVED / UNDETERMINED）。⚠ ラベルが 1 つも出ていない出力は判定ではない
# （-h / --help の単独指定だけがラベルを出さない）。
#
# ⚠ コマンド置換は「1 行で完結する純粋な代入形」だけで書く
#   （set -u 違反がコマンド置換の中で起きると exit 0 に化ける経路を作らないため）。

set -euo pipefail

# 判定ラベル（標準出力に出す正式な判定）。引数の検査より先に定義する
# （定義より前で終了する経路を作らないため）。
emit_label() { # $1 = ラベル, $2 = 何が起きたか（1 行）
  printf '%s  %s\n' "$1" "$2"
}

usage() {
  cat <<'USAGE'
使い方: approve-if-verdict.sh <PR番号> <since（ISO 8601 UTC）> <head SHA>

  GitHub Actions 上の Claude が投稿したレビューコメント（github-actions[bot]・since 以降）から
  行頭 `判定: APPROVE` を探し、見つかったときだけ GITHUB_TOKEN で PR を Approve する。
  対象リポジトリは環境変数 GITHUB_REPOSITORY（owner/repo）から取る。

終了コード: 0 = Approve した / Approve しない理由が確定した、1 = 判定不能
判定は標準出力の最後の行のラベルで読む（ラベルの一覧と判定順はスクリプト冒頭のコメント）。
USAGE
}

# -h / --help の単独指定だけヘルプを出して終わる（判定ではないのでラベルを出さない）
if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
  usage
  exit 0
fi

# 判定行を承認とみなす投稿者。⚠ 環境変数で上書きできる形にしない（誰の判定行でも Approve を
# 通せるようになる）。同じ形式を人間や他の bot が投稿しても効かないことが、この仕組みの要。
REVIEWER_LOGIN='github-actions[bot]'

# レビュー本文の見出しの接頭辞（SSOT は perspectives/common.md「レビュー結果の定型フォーマット」）。
# 括弧の中身は照合しない。見出しが担うのは無関係な bot コメントを拾わないことだけで、身元は
# REVIEWER_LOGIN / since / head SHA / 判定行ちょうど 1 本で担保する（そちらは緩めない）。
REVIEW_HEADER_PREFIX='## レビュー'

# gh の呼び出しが失敗したときの再試行回数と間隔（秒）。瞬断で UNDETERMINED に落ちないための緩衝。
GH_RETRIES="${TG_AGENT_REVIEW_GH_RETRIES:-2}"
GH_RETRY_INTERVAL="${TG_AGENT_REVIEW_GH_RETRY_INTERVAL:-3}"

# 判定を出さずに終わった経路を UNDETERMINED に倒す（fail-close）。set -e / set -u による中断が
# exit 0（何もしなかったが正常）に見えないよう、判定を出したかを記録して exit 1 に倒す。
TG_VERDICT_GIVEN=false
verdict() { # $1 = 終了コード, $2 = ラベル, $3 = 何が起きたか
  emit_label "$2" "$3"
  TG_VERDICT_GIVEN=true
  exit "$1"
}
GH_ERR_FILE=""
REVIEW_INPUT_FILE=""
trap 'TG_EXIT_CODE=$?; if [[ -n "$GH_ERR_FILE" ]]; then rm -f "$GH_ERR_FILE"; fi; if [[ -n "$REVIEW_INPUT_FILE" ]]; then rm -f "$REVIEW_INPUT_FILE"; fi; if [[ "$TG_VERDICT_GIVEN" != true ]]; then emit_label UNDETERMINED "判定を出さないまま終了した（想定外の中断）"; exit 1; fi; exit $TG_EXIT_CODE' EXIT

# 引数不正でも usage は出さない（usage のラベル一覧が判定ラベルと混ざる）
if [[ $# -ne 3 ]]; then
  verdict 1 UNDETERMINED "引数は 3 つ（PR番号 since headSHA）だが ${#} 個渡された（使い方は -h）"
fi

PR_NUMBER="$1"
SINCE="$2"
HEAD_SHA_EXPECTED="$3"
REPO="${GITHUB_REPOSITORY:-}"

if [[ ! "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
  verdict 1 UNDETERMINED "PR 番号が数値ではない（${PR_NUMBER}）"
fi
# since は created_at と同じ形に限る（時刻の前後を文字列比較で判定するため、形が違うと壊れる）。
if [[ ! "$SINCE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
  verdict 1 UNDETERMINED "since が ISO 8601 UTC（YYYY-MM-DDTHH:MM:SSZ）ではない（${SINCE}）"
fi
if [[ ! "$HEAD_SHA_EXPECTED" =~ ^[0-9a-f]{40}$ ]]; then
  verdict 1 UNDETERMINED "head SHA が 40 桁の 16 進ではない（${HEAD_SHA_EXPECTED}）"
fi
if [[ ! "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  verdict 1 UNDETERMINED "GITHUB_REPOSITORY が owner/repo の形ではない（${REPO:-未設定}）"
fi
if [[ ! "$GH_RETRIES" =~ ^[0-9]+$ ]]; then
  verdict 1 UNDETERMINED "TG_AGENT_REVIEW_GH_RETRIES が 0 以上の整数ではない（${GH_RETRIES}）"
fi
if [[ ! "$GH_RETRY_INTERVAL" =~ ^[0-9]+$ ]]; then
  verdict 1 UNDETERMINED "TG_AGENT_REVIEW_GH_RETRY_INTERVAL が 0 以上の整数ではない（${GH_RETRY_INTERVAL}）"
fi

for cmd in gh jq; do
  if ! command -v "$cmd" > /dev/null 2>&1; then
    verdict 1 UNDETERMINED "前提コマンド ${cmd} が見つからない"
  fi
done

# --- gh 呼び出し（一過性の失敗を再試行で吸収する） ---

if ! GH_ERR_FILE=$(mktemp "${TMPDIR:-/tmp}/trillion-game-actions-gh-err.XXXXXX"); then
  GH_ERR_FILE=""
  verdict 1 UNDETERMINED "一時ファイルを作成できなかった"
fi
if ! REVIEW_INPUT_FILE=$(mktemp "${TMPDIR:-/tmp}/trillion-game-actions-input.XXXXXX"); then
  REVIEW_INPUT_FILE=""
  verdict 1 UNDETERMINED "一時ファイルを作成できなかった"
fi

# gh を実行し、失敗したら GH_RETRIES 回まで再試行する（GH_OUTPUT に成功時は標準出力、失敗時は標準エラー）。
GH_OUTPUT=""
gh_retry() {
  local attempt=0
  while true; do
    if GH_OUTPUT=$(gh "$@" 2> "$GH_ERR_FILE"); then
      return 0
    fi
    GH_OUTPUT=$(cat "$GH_ERR_FILE" 2> /dev/null || true)
    attempt=$((attempt + 1))
    if [[ "$attempt" -gt "$GH_RETRIES" ]]; then
      return 1
    fi
    echo "  gh の呼び出しに失敗しました。再試行します（${attempt}/${GH_RETRIES}）。" >&2
    sleep "$GH_RETRY_INTERVAL"
  done
}

echo "Agent Review: ${REPO} PR #${PR_NUMBER}"
echo "  since       : ${SINCE}"
echo "  head commit : ${HEAD_SHA_EXPECTED}"

# --- コメント一覧から判定行を持つレビューを探す ---

if ! gh_retry api "repos/${REPO}/issues/${PR_NUMBER}/comments?per_page=100" --paginate; then
  echo "$GH_OUTPUT" >&2
  verdict 1 UNDETERMINED "コメント一覧を取得できなかった（API 呼び出しの失敗）"
fi

# --paginate はページごとの JSON 配列を連結して返すので 1 つの配列に束ねる。
# 配列でない応答（エラーオブジェクト等）は「0 件」へ倒さず判定不能にする。
COMMENTS_JSON=$(jq -s 'add' <<< "$GH_OUTPUT" 2> /dev/null || true)
if ! jq -e 'type == "array"' > /dev/null 2>&1 <<< "$COMMENTS_JSON"; then
  verdict 1 UNDETERMINED "コメント一覧を配列として解釈できなかった（エラー応答の可能性）"
fi

# 見出しと判定行の抽出。どちらも同じ「コードブロックの外の行」（content_lines）の上で判定する
#   （見出しだけ本文全体を対象にすると、フォーマットの説明を引用しただけの投稿が候補になる）。
#   - CRLF を LF に揃え、``` / ~~~ のフェンスの中は読まない
#   - 見出しは行頭が `## レビュー` の行（先頭 3 スペースまでは Markdown の見出しとして許容。
#     4 つ以上はコードブロックなので落ちる）
#   - 判定行は行頭が `判定: ` の行だけ（`**判定:` / `> 判定:` は行頭が違うので落ちる）。
#     末尾の空白は落として値を比べる。body が null のコメントは空文字として扱う
# jq の失敗は「候補なし」へ倒さず UNDETERMINED にする（解釈不能が SKIPPED_NO_VERDICT という
# 正常な「何もしない」と同じ顔になるため）。
# ⚠ 同じ抽出条件の写しが、このスクリプトを呼ぶ運営側にもある。片方だけ変えない。
if ! CANDIDATE_JSON=$(jq -c --arg login "$REVIEWER_LOGIN" --arg since "$SINCE" --arg header "$REVIEW_HEADER_PREFIX" '
  def content_lines:
    gsub("\r"; "") | split("\n")
    | reduce .[] as $l ({fence: false, out: []};
        if ($l | test("^ {0,3}(```|~~~)")) then .fence = (.fence | not)
        elif (.fence | not) then .out += [$l]
        else . end)
    | .out;
  map(select(
        (.user.login? // "") == $login
        and ((.created_at? // "") >= $since)))
  | map(. + {lines: ((.body // "") | content_lines)})
  | map(select(any(.lines[]; sub("^ {0,3}"; "") | startswith($header))))
  | map({id: .id, html_url: .html_url, created_at: .created_at,
         verdicts: [.lines[] | select(startswith("判定: ")) | sub("\\s+$"; "")]})
  | map(select((.verdicts | length) == 1))
  | sort_by(.created_at)
  | last // empty' <<< "$COMMENTS_JSON" 2> "$GH_ERR_FILE"); then
  cat "$GH_ERR_FILE" >&2
  verdict 1 UNDETERMINED "コメント一覧を解釈できなかった（判定行の抽出に失敗。応答の形が変わっていないかを確認する）"
fi

if [[ -z "$CANDIDATE_JSON" ]]; then
  echo "  判定行を持つ ${REVIEWER_LOGIN} のレビューコメント（since 以降・行頭 ${REVIEW_HEADER_PREFIX} の見出し・判定行 1 本）が無い"
  verdict 0 SKIPPED_NO_VERDICT "判定行が無いので何もしない（Approve は付かない）"
fi

COMMENT_URL=$(jq -r '.html_url // empty' <<< "$CANDIDATE_JSON" 2> /dev/null || true)
VERDICT_LINE=$(jq -r '.verdicts[0] // empty' <<< "$CANDIDATE_JSON" 2> /dev/null || true)
if [[ -z "$VERDICT_LINE" ]]; then
  verdict 1 UNDETERMINED "候補のコメントから判定行を取り出せなかった"
fi
echo "  レビュー     : ${COMMENT_URL:-（URL 不明）}"
echo "  判定行       : ${VERDICT_LINE}"

case "$VERDICT_LINE" in
  "判定: APPROVE") ;;
  "判定: REQUEST_CHANGES")
    verdict 0 SKIPPED_REQUEST_CHANGES "判定が REQUEST_CHANGES なので何もしない（Approve は付かない）"
    ;;
  *)
    # 定型（APPROVE / REQUEST_CHANGES）以外の値は判定として読まない（Approve 側へ倒さない）
    verdict 0 SKIPPED_NO_VERDICT "判定行の値を解釈できないので何もしない（${VERDICT_LINE}）"
    ;;
esac

# --- head SHA の一致を確かめてから Approve する ---
# レビュー中に push があれば判定は古いコミットのものなので Approve しない
# （新しい head では synchronize でワークフローが再走する）。

if ! gh_retry api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.head.sha'; then
  echo "$GH_OUTPUT" >&2
  verdict 1 UNDETERMINED "PR #${PR_NUMBER} の head.sha を取得できなかった（API 呼び出しの失敗）"
fi
HEAD_SHA_ACTUAL="$GH_OUTPUT"
if [[ ! "$HEAD_SHA_ACTUAL" =~ ^[0-9a-f]{40}$ ]]; then
  verdict 1 UNDETERMINED "PR #${PR_NUMBER} の head.sha を解釈できなかった（${HEAD_SHA_ACTUAL}）"
fi
if [[ "$HEAD_SHA_ACTUAL" != "$HEAD_SHA_EXPECTED" ]]; then
  echo "  head が動いている: 期待 ${HEAD_SHA_EXPECTED} / 実際 ${HEAD_SHA_ACTUAL}"
  verdict 0 SKIPPED_HEAD_MOVED "レビュー対象と最新コミットが一致しないので何もしない（新しい head の run に任せる）"
fi

# Approve の本文（対象コミットと元コメントを残す。commit_id で対象コミットを API 側にも固定する）
REVIEW_BODY="Agent Review: 判定行 APPROVE を検出したため承認します。
対象コミット: ${HEAD_SHA_EXPECTED}
元コメント: ${COMMENT_URL}"
# ⚠ 本文は標準入力ではなくファイルで渡す（標準入力だと再試行の 2 回目以降で中身が空になる）
if ! jq -nc --arg sha "$HEAD_SHA_EXPECTED" --arg body "$REVIEW_BODY" '{event: "APPROVE", commit_id: $sha, body: $body}' > "$REVIEW_INPUT_FILE"; then
  verdict 1 UNDETERMINED "Approve の本文（JSON）を組み立てられなかった"
fi

if ! gh_retry api -X POST "repos/${REPO}/pulls/${PR_NUMBER}/reviews" --input "$REVIEW_INPUT_FILE"; then
  echo "$GH_OUTPUT" >&2
  verdict 1 UNDETERMINED "Approve の投稿に失敗した（reviews API の失敗。リポ設定「Allow GitHub Actions to create and approve pull requests」を確認する）"
fi
REVIEW_STATE=$(jq -r '.state // empty' <<< "$GH_OUTPUT" 2> /dev/null || true)
if [[ "$REVIEW_STATE" != "APPROVED" ]]; then
  verdict 1 UNDETERMINED "Approve の応答を解釈できなかった（state=${REVIEW_STATE:-不明}）"
fi

verdict 0 APPROVED "PR #${PR_NUMBER} を ${HEAD_SHA_EXPECTED} で Approve した（元コメント: ${COMMENT_URL}）"
