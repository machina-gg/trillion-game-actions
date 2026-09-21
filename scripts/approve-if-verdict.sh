#!/bin/bash
# trillion-game-actions — レビューの判定行を読んで Approve を押すスクリプト
#
# reusable workflow（.github/workflows/review.yml）の最終ステップから、呼び出し元リポジトリの
# ワークスペースに checkout された `.trillion-game-actions/scripts/approve-if-verdict.sh` として呼ばれる。
# GitHub Actions 上の Claude が `gh pr comment` で投稿したレビュー
# （perspectives/common.md「レビュー結果の定型フォーマット」）から行頭固定の `判定: APPROVE` を探し、
# 見つかったときだけ GITHUB_TOKEN で `POST /repos/<repo>/pulls/<N>/reviews {event: APPROVE}` を実行する。
#
# なぜ Claude ではなくこのスクリプトが Approve を押すのか:
#   Claude に `gh api` を許すと Claude 自身が Approve を押せる形になり、規律でしか止まらない。
#   判定行の抽出と Approve の実行は「同じ入力なら同じ出力」の決定的処理なので、スクリプトに切り出す。
#
# 使い方:
#   approve-if-verdict.sh <PR番号> <since（ISO 8601 UTC・秒精度）> <head SHA（40 桁）>
#   対象リポジトリは環境変数 GITHUB_REPOSITORY（owner/repo。Actions の既定環境変数）から取る。
#   gh の認証は GH_TOKEN（GITHUB_TOKEN を渡す）。
#
# 判定の順序（上から順に評価し、最初に当たったところで止まる）:
#   1. 引数・環境変数の形を検査する（不正なら UNDETERMINED）
#   2. Issue コメント一覧を取得し、次をすべて満たすものを候補にする
#        - 投稿者が github-actions[bot]（⚠ 同一アカウントの PM / Reviewer subagent が同じ形式を
#          投稿しても効かない。これがこの仕組みの要）
#        - created_at が since 以上（job 開始前の古い投稿を読まない）
#        - コードブロックの外に、行頭が `## レビュー` で始まる見出し行が**1 本以上**ある
#          （⚠ 括弧の中身は問わない。Markdown の見出しに合わせ先頭 3 スペースまでは許容する）
#        - コードブロックの外に、行頭 `判定: ` で始まる行が**ちょうど 1 本**ある
#      候補が複数あれば created_at が最大の 1 件を採る
#   3. 候補が無ければ SKIPPED_NO_VERDICT（何もしない・exit 0）
#   4. 判定が REQUEST_CHANGES なら SKIPPED_REQUEST_CHANGES（何もしない・exit 0）。
#      APPROVE / REQUEST_CHANGES 以外の値も Approve せず SKIPPED_NO_VERDICT に倒す
#   5. PR の head.sha を取得し、引数の head SHA と一致しなければ SKIPPED_HEAD_MOVED（exit 0）
#   6. reviews API に event=APPROVE・commit_id=head SHA で POST し、応答の state が APPROVED なら
#      APPROVED（exit 0）
#
# 終了コード:
#   0 = Approve した（APPROVED）/ Approve しない理由が確定した（SKIPPED_*）。
#       ⚠ Approve しない経路でも job を失敗させない。失敗させると「CI が赤い」状態になり、
#       Approve が付かないこととは別の理由で PR が二重に止まる
#   1 = 判定不能（UNDETERMINED）。引数不正・API 呼び出しの失敗・応答を解釈できない・
#       判定を出さずに終わった。Approve を押せない状態を run の失敗で見せる（fail-close）
#
# 標準出力の最後の行が判定ラベル（APPROVED / SKIPPED_NO_VERDICT / SKIPPED_REQUEST_CHANGES /
# SKIPPED_HEAD_MOVED / UNDETERMINED）。⚠ ラベルが 1 つも出ていない出力は判定ではない。
# -h / --help の単独指定だけがラベルを出さない。
#
# ⚠ コマンド置換は「1 行で完結する純粋な代入形」だけで書く
#   （set -u 違反がコマンド置換の中で起きると exit 0 に化ける経路を作らないため）。

set -euo pipefail

# ------------------------------------------------------------------
# 判定ラベル（標準出力に出す「正式な判定」）
# ------------------------------------------------------------------
# ⚠ ラベルの文字列は tests/approve-if-verdict.test.sh が固定している。
# ⚠ 定義より前で終了する経路を作らないため、引数の検査より先に定義する。
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

# -h / --help は単独指定のときだけヘルプを出して終わる（判定ではないのでラベルを出さない）
if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
  usage
  exit 0
fi

# ------------------------------------------------------------------
# 設定
# ------------------------------------------------------------------

# レビューを投稿する身元。⚠ 環境変数では上書きできない（リテラル固定）。
# 上書きを許すと「誰の判定行を承認とみなすか」を差し替えられるため。
REVIEWER_LOGIN='github-actions[bot]'

# レビュー本文の見出しの接頭辞（perspectives/common.md「レビュー結果の定型フォーマット」の
# `## レビュー(reviewer)`）。⚠ 括弧の中身は照合しない——Reviewer が括弧内を書き換えた
# （`## レビュー(claude)`）だけで Approve が落ちるため（machina-gg/trillion-game-actions#1）。
# ⚠ 見出しが担うのは「無関係な bot コメントを拾わない」ことだけで、身元の担保は
# REVIEWER_LOGIN / since / head SHA / 判定行ちょうど 1 本が行う（そちらは一切緩めない）。
REVIEW_HEADER_PREFIX='## レビュー'

# gh の呼び出しが失敗したときの再試行回数と間隔（秒）。瞬断で UNDETERMINED に落ちないための緩衝。
GH_RETRIES="${TG_AGENT_REVIEW_GH_RETRIES:-2}"
GH_RETRY_INTERVAL="${TG_AGENT_REVIEW_GH_RETRY_INTERVAL:-3}"

# ------------------------------------------------------------------
# 判定を出さずに終わった経路を UNDETERMINED に倒す（fail-close）
# ------------------------------------------------------------------
# ⚠ set -e / set -u による fatal な中断が exit 0（= 何もしなかったが正常）に見えないよう、
#   「判定を出したか」を明示的に記録し、出していなければ exit 1 に倒す。
TG_VERDICT_GIVEN=false
verdict() { # $1 = 終了コード, $2 = ラベル, $3 = 何が起きたか
  emit_label "$2" "$3"
  TG_VERDICT_GIVEN=true
  exit "$1"
}
GH_ERR_FILE=""
REVIEW_INPUT_FILE=""
trap 'TG_EXIT_CODE=$?; if [[ -n "$GH_ERR_FILE" ]]; then rm -f "$GH_ERR_FILE"; fi; if [[ -n "$REVIEW_INPUT_FILE" ]]; then rm -f "$REVIEW_INPUT_FILE"; fi; if [[ "$TG_VERDICT_GIVEN" != true ]]; then emit_label UNDETERMINED "判定を出さないまま終了した（想定外の中断）"; exit 1; fi; exit $TG_EXIT_CODE' EXIT

# ------------------------------------------------------------------
# 引数と環境変数の検査
# ------------------------------------------------------------------

# ⚠ 引数不正でも usage は出さない（usage にはラベル一覧が載っており、判定ラベルと混ざる）
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
# since は GitHub API の created_at と同じ形（YYYY-MM-DDTHH:MM:SSZ）に限る。
# 文字列比較で時刻の前後を判定するため、形が違うと比較が壊れる。
if [[ ! "$SINCE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
  verdict 1 UNDETERMINED "since が ISO 8601 UTC（YYYY-MM-DDTHH:MM:SSZ）ではない（${SINCE}）"
fi
if [[ ! "$HEAD_SHA_EXPECTED" =~ ^[0-9a-f]{40}$ ]]; then
  verdict 1 UNDETERMINED "head SHA が 40 桁の 16 進ではない（${HEAD_SHA_EXPECTED}）"
fi
if [[ ! "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  verdict 1 UNDETERMINED "GITHUB_REPOSITORY が owner/repo の形ではない（${REPO:-未設定}）"
fi
# 数値で受け取る設定は変数名ごとに検査する（どちらが不正かをメッセージで判別できるように）
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

# ------------------------------------------------------------------
# gh 呼び出し（一過性の失敗を再試行で吸収する）
# ------------------------------------------------------------------

if ! GH_ERR_FILE=$(mktemp "${TMPDIR:-/tmp}/trillion-game-actions-gh-err.XXXXXX"); then
  GH_ERR_FILE=""
  verdict 1 UNDETERMINED "一時ファイルを作成できなかった"
fi
if ! REVIEW_INPUT_FILE=$(mktemp "${TMPDIR:-/tmp}/trillion-game-actions-input.XXXXXX"); then
  REVIEW_INPUT_FILE=""
  verdict 1 UNDETERMINED "一時ファイルを作成できなかった"
fi

# gh を実行し、失敗したら GH_RETRIES 回まで再試行する。
# GH_OUTPUT には成功時は標準出力、失敗時は標準エラーの内容が入る。
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

# ------------------------------------------------------------------
# コメント一覧から判定行を持つレビューを探す
# ------------------------------------------------------------------

if ! gh_retry api "repos/${REPO}/issues/${PR_NUMBER}/comments?per_page=100" --paginate; then
  echo "$GH_OUTPUT" >&2
  verdict 1 UNDETERMINED "コメント一覧を取得できなかった（API 呼び出しの失敗）"
fi

# --paginate はページごとの JSON 配列を連結して返すので、1 つの配列に束ねる。
# 応答が配列でない（エラーオブジェクト等）ときは判定不能に倒す（「0 件」へ倒さない）。
COMMENTS_JSON=$(jq -s 'add' <<< "$GH_OUTPUT" 2> /dev/null || true)
if ! jq -e 'type == "array"' > /dev/null 2>&1 <<< "$COMMENTS_JSON"; then
  verdict 1 UNDETERMINED "コメント一覧を配列として解釈できなかった（エラー応答の可能性）"
fi

# 見出しと判定行の抽出。⚠ どちらも同じ「コードブロックの外の行」（content_lines）の上で判定する
#   （見出しだけ本文全体を対象にすると、フォーマットの説明を引用しただけの投稿が候補になる）。
#   - CRLF を LF に揃えてから行に分ける
#   - ``` / ~~~ のフェンスの中は読まない（コードブロック内の見出し・判定行は判定ではない）
#   - 見出しは行頭が `## レビュー` で始まる行（先頭 3 スペースまでは Markdown の見出しとして許容。
#     4 つ以上はコードブロックなので落ちる）。⚠ 括弧の中身は照合しない（REVIEW_HEADER_PREFIX の注記）
#   - 判定行は行頭が `判定: ` で始まる行だけを採る（`**判定:` / `> 判定:` / `- 判定:` は行頭が違うので落ちる）
#   - 末尾の空白だけは落として値を比べる
#   - body が null のコメントは空文字として扱う（見出しを含まないので候補にならない）
# ⚠ jq の失敗（応答の形が想定外で式が評価できない）は「候補なし」へ倒さず UNDETERMINED にする。
#   握りつぶすと解釈不能が SKIPPED_NO_VERDICT（正常な「何もしない」）と同じ顔になる（PR #1111 の Copilot 指摘）。
# ⚠ 本スクリプトを呼ぶ運営リポジトリ側に、同じ抽出条件の写しがある。
#   片方だけ変えない（変えるときは両方を同じ条件に揃える）。
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
    # 定型（APPROVE / REQUEST_CHANGES）以外の値は判定として読まない。⚠ Approve 側へは倒さない
    verdict 0 SKIPPED_NO_VERDICT "判定行の値を解釈できないので何もしない（${VERDICT_LINE}）"
    ;;
esac

# ------------------------------------------------------------------
# head SHA の一致を確かめてから Approve する
# ------------------------------------------------------------------
# ⚠ レビュー中に push があると、判定は古いコミットのもの。Approve は付けない（SKIPPED_HEAD_MOVED）。
#   新しい head では synchronize で本ワークフローが再走する。

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
