#!/bin/bash
# PR 本文の Issue 紐づけ検査（composite action `issue-link-check` の判定の実体）。入力は環境変数
# だけで受け取る（GitHub の式に依存させず、単体テストできる形にするため）:
#   PR_BODY        PR 本文。未設定は入力ミスとして失敗させ、空文字は本文が空の PR として検査する
#   LABELS_JSON    ラベル名の JSON 配列
#   OVERRIDE_LABEL 検査をスキップするラベル名。既定値は action.yml が持ち、ここでは補わない
# 本文に紐づけがあれば OK、無ければ override ラベルでだけスキップ、どちらでもなければ ::error:: を
# 出して exit 1（0 = 紐づけあり / スキップ、1 = それ以外）。入力を解釈できないときはスキップしない。

set -euo pipefail

# 受理する Issue 紐づけの形。refs を落とすとシリーズ途中の PR が紐づけられない。左側の境界
# `(^|[^[:alpha:]])` を落とすと prefixes / encloses のような英単語の末尾に部分一致し、直後の #数字
# だけで検査を通過する。右側に境界は置かない（`Refs #123の続き` を受理するため。代償として
# `Closes #12abc` も通る）。空白は POSIX 文字クラスで書く（`\s` は ERE には無い）。
ISSUE_LINK_PATTERN='(^|[^[:alpha:]])(closes|fixes|resolves|refs)[[:space:]]+#[0-9]+'

# jq の有無をログに残す。ここでは落とさない（jq が要るのはラベル検査だけで、無いときに諦めるのはスキップ側）。
JQ_AVAILABLE=true
if ! jq --version; then
  JQ_AVAILABLE=false
fi

if [[ -z "${PR_BODY+x}" ]]; then
  echo "::error title=Issue Check::環境変数 PR_BODY が未設定です（action の inputs.pr-body を渡してください）。"
  exit 1
fi

# 本文は here-string で渡す。パイプに戻すと、`grep -q` が一致した時点で終了した後に書き手が残りを
# 書こうとして EPIPE になり、`pipefail` で「一致したのに非 0」になる（長い本文でだけ落ちる）。
if grep -qiE "$ISSUE_LINK_PATTERN" <<<"$PR_BODY"; then
  echo "=== Issue 紐づけチェック OK ==="
  exit 0
fi

# override ラベルの検査。要素の完全一致でだけスキップする（部分一致にすると、前後に語を足しただけの似た名前のラベルで検査を無効化できる）。
if [[ "$JQ_AVAILABLE" != "true" ]]; then
  echo "::warning title=Issue Check::jq が見つからないため、ラベルによるスキップは行いません（要素の完全一致を検査できないため）。"
elif [[ -z "${OVERRIDE_LABEL:-}" ]]; then
  echo "::warning title=Issue Check::override-label が空のため、ラベルによるスキップは行いません。"
elif [[ -z "${LABELS_JSON+x}" ]]; then
  echo "::warning title=Issue Check::環境変数 LABELS_JSON が未設定のため、ラベルによるスキップは行いません（action の inputs.labels-json を渡してください）。"
elif ! printf '%s\n' "$LABELS_JSON" | jq -e 'type == "array"' > /dev/null 2>&1; then
  echo "::warning title=Issue Check::labels-json を JSON 配列として読めなかったため、ラベルによるスキップは行いません（toJSON(github.event.pull_request.labels.*.name) を渡してください）。"
elif printf '%s\n' "$LABELS_JSON" | jq -e --arg label "$OVERRIDE_LABEL" 'any(.[]; . == $label)' > /dev/null 2>&1; then
  echo "::notice::${OVERRIDE_LABEL} ラベルにより Issue 紐づけチェックをスキップ"
  echo "=== Issue 紐づけチェック SKIP ==="
  exit 0
fi

echo ""
echo "::error title=Issue Check::PR 本文に Issue 紐づけ（Closes #N / Fixes #N / Resolves #N / Refs #N のいずれか）がありません。"
echo "PR 本文に 'Closes #N' / 'Fixes #N' / 'Resolves #N'（Issue を閉じる）か 'Refs #N'（シリーズ途中・閉じない）を追加してください。"
echo "Issue がない場合は先に Issue を作成してください。"
if [[ -n "${OVERRIDE_LABEL:-}" ]]; then
  echo "やむを得ない場合は PR に '${OVERRIDE_LABEL}' ラベルを付けてください。"
fi
exit 1
