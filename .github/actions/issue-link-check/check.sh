#!/bin/bash
# trillion-game-actions — PR 本文の Issue 紐づけ検査（composite action `issue-link-check` の判定の実体）
#
# 同ディレクトリの action.yml の唯一のステップから呼ばれる。入力はすべて環境変数で受け取り、
# GitHub の式（contains 等）には依存しない（同じ入力なら同じ出力になる決定的処理に閉じ、
# 単体テストできる形にするため）。
#
# 入力（環境変数。action.yml の inputs と 1 対 1）:
#   PR_BODY        PR 本文。⚠ 未設定は入力ミスとして失敗させる（空文字は「本文が空の PR」として検査する）
#   LABELS_JSON    ラベル名の JSON 配列（例: ["bug","override:no-issue"]）
#   OVERRIDE_LABEL 検査をスキップするラベル名。⚠ 既定値は action.yml が持ち、ここでは補わない
#                  （既定値を 2 箇所に置くと片方だけずれる）
#
# 判定の順序（上から評価し、最初に当たったところで止まる）:
#   0. jq の有無をログに残す。⚠ **ここでは判定しない**（jq が要るのは 2. のラベル検査だけなので、
#      jq が無いことを理由に 1. で決まる大半のケースを落とさない）
#   1. PR 本文に「受理する語 + 空白 + #番号」があれば OK（大文字小文字を区別しない）
#   2. LABELS_JSON に OVERRIDE_LABEL と**完全一致する要素**があればスキップ
#      （⚠ 部分一致にしない。前後に語を足しただけの似た名前のラベルでスキップできてしまう）
#   3. どちらでもなければ ::error:: を出して exit 1
#
# 終了コード: 0 = 紐づけあり / スキップ、1 = 紐づけなし（＝検査に落ちた）・入力不正
#
# fail-close: 入力を解釈できないとき（LABELS_JSON が JSON 配列として読めない等）は
# **スキップしない**側へ倒す。スキップは検査そのものを無効化する経路なので、判定不能なら効かせない。

set -euo pipefail

# 受理する Issue 紐づけの形。
# ⚠ `refs` を必ず含める（シリーズ作業の途中 PR は Issue を閉じないため Refs #N で紐づける）。
# ⚠ 空白は POSIX 文字クラスで書く（`\s` は POSIX ERE には無い GNU 拡張で、環境によって解釈が変わる）。
# ⚠ 左側の境界 `(^|[^[:alpha:]])` を落とさない。無いと prefixes / suffixes / encloses のような
#   英単語の末尾にキーワードが部分一致し、その直後に脚注番号などの #数字 が来るだけで検査を通過する。
# ⚠ 右側（#数字 の後ろ）には境界を置かない。置くと `Refs #123の続き` のように
#   数字の直後に日本語が続く本文が通らなくなる（UTF-8 ロケールでは日本語が [[:alnum:]] に入るため）。
#   代償として `Closes #12abc` のような形も受理する。
ISSUE_LINK_PATTERN='(^|[^[:alpha:]])(closes|fixes|resolves|refs)[[:space:]]+#[0-9]+'

# jq の有無をログに残す（ランナーに同梱されているかをここで可視化する）。
# ⚠ 無くてもここでは落とさない。jq が要るのはラベルの完全一致検査だけで、
#   本文に紐づけがあるケースの判定には関係しないため（無い場合はスキップ側を諦める = fail-close）。
JQ_AVAILABLE=true
if ! jq --version; then
  JQ_AVAILABLE=false
fi

# ------------------------------------------------------------------
# 1. PR 本文の検査
# ------------------------------------------------------------------

# ⚠ 「未設定」と「空文字」を区別する（本文が空の PR は正常な入力で、検査に落とす側で扱う）
if [[ -z "${PR_BODY+x}" ]]; then
  echo "::error title=Issue Check::環境変数 PR_BODY が未設定です（action の inputs.pr-body を渡してください）。"
  exit 1
fi

if printf '%s\n' "$PR_BODY" | grep -qiE "$ISSUE_LINK_PATTERN"; then
  echo "=== Issue 紐づけチェック OK ==="
  exit 0
fi

# ------------------------------------------------------------------
# 2. override ラベルの検査（要素の完全一致）
# ------------------------------------------------------------------

if [[ "$JQ_AVAILABLE" != "true" ]]; then
  echo "::warning title=Issue Check::jq が見つからないため、ラベルによるスキップは行いません（要素の完全一致を検査できないため）。"
elif [[ -z "${OVERRIDE_LABEL:-}" ]]; then
  echo "::warning title=Issue Check::override-label が空のため、ラベルによるスキップは行いません。"
elif [[ -z "${LABELS_JSON+x}" ]]; then
  echo "::warning title=Issue Check::環境変数 LABELS_JSON が未設定のため、ラベルによるスキップは行いません（action の inputs.labels-json を渡してください）。"
elif ! printf '%s\n' "$LABELS_JSON" | jq -e 'type == "array"' > /dev/null 2>&1; then
  echo "::warning title=Issue Check::labels-json を JSON 配列として読めなかったため、ラベルによるスキップは行いません（toJSON(github.event.pull_request.labels.*.name) を渡してください）。"
elif printf '%s\n' "$LABELS_JSON" | jq -e --arg label "$OVERRIDE_LABEL" 'any(.[]; . == $label)' > /dev/null 2>&1; then
  # ⚠ jq の比較は大文字小文字を区別する（綴り違いのラベルではスキップしない）
  echo "::notice::${OVERRIDE_LABEL} ラベルにより Issue 紐づけチェックをスキップ"
  echo "=== Issue 紐づけチェック SKIP ==="
  exit 0
fi

# ------------------------------------------------------------------
# 3. どちらも通らなかった
# ------------------------------------------------------------------

echo ""
echo "::error title=Issue Check::PR 本文に Issue 紐づけ（Closes #N / Fixes #N / Resolves #N / Refs #N のいずれか）がありません。"
echo "PR 本文に 'Closes #N' / 'Fixes #N' / 'Resolves #N'（Issue を閉じる）か 'Refs #N'（シリーズ途中・閉じない）を追加してください。"
echo "Issue がない場合は先に Issue を作成してください。"
if [[ -n "${OVERRIDE_LABEL:-}" ]]; then
  echo "やむを得ない場合は PR に '${OVERRIDE_LABEL}' ラベルを付けてください。"
fi
exit 1
