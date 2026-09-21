# trillion-game-actions

**複数のリポジトリで共有する CI 資産**を置くリポジトリ。実体はここ 1 箇所にあり、
呼び出し元は `@main` 参照で使う（コピーしない）。

- **エージェントレビュー** — GitHub Actions 上の Claude が Pull Request をレビューし、
  判定行が `判定: APPROVE` のときだけ `github-actions[bot]` が Approve を押す reusable workflow と、
  その**レビュー観点**（本 README の「エージェントレビューの呼び方」以降）
- **Issue 紐づけ検査** — PR 本文に `Closes #N` 等があるかを検査する composite action
  （本 README の「Issue 紐づけ検査」）

## 置き場の規約

| 種類              | 置き場                         | 呼び出し方                                                   |
| ----------------- | ------------------------------ | ------------------------------------------------------------ |
| reusable workflow | `.github/workflows/<name>.yml` | job の `uses:`（⚠ step からは呼べない）                      |
| composite action  | `.github/actions/<name>/`      | step の `uses:`（呼び出し元の job 構成を変えずに差し込める） |
| レビュー観点      | `perspectives/<name>.md`       | reusable workflow の `profile`                               |

- ⚠ **public リポジトリである。** 秘匿情報（トークン・個人のローカルパス・個人のメールアドレス）や、
  非公開にしたいロジック・運用の内情は**置けない**（書き方の詳細は [`CLAUDE.md`](CLAUDE.md)）
- **消費者が 1 リポジトリしかないものは置かない。** 共有する相手が実在してから寄せる
  （1 リポジトリでしか使わないものをここに置くと、変更のたびに 2 リポジトリを往復することになる）
- ⚠ ここへ寄せたものは `@main` 参照で**呼び出し元すべてに即時反映される**。
  1 リポジトリの都合で共通の挙動を曲げない

## エージェントレビューの呼び方

呼び出し元リポジトリに次のワークフローを置く。

```yaml
name: Claude Review

on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]

concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number }}
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  review:
    uses: machina-gg/trillion-game-actions/.github/workflows/review.yml@main
    permissions:
      contents: read
      pull-requests: write
      issues: write
    with:
      profile: chrome-extension
    secrets:
      CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

- **`on` は `pull_request` であること。** ジョブの実行可否（draft を除外する等）は
  `github.event.pull_request` を見て決めるため、他のイベントでは動かない
- `types` に `labeled` / `unlabeled` / `edited` は含めない（ラベル操作や本文編集で Claude を
  再走させない。`synchronize`（push）で再走すれば十分で、レビューの必須 Approve は
  ブランチルールセットの `dismiss_stale_reviews_on_push` で push ごとに再取得される）
- `with.profile` は**省略できる**（省略時は `perspectives/common.md` だけを読む）。
  カンマ区切りで複数指定できる（例: `profile: harness,chrome-extension`）
- `secrets.CLAUDE_CODE_OAUTH_TOKEN` は**必須**（呼び出し元が明示的に渡す）。
  値が空（repo secret 未登録）の場合は警告を出して skip し、**job は成功で終わる**
  （レビューコメントと Approve は付かない）

### 呼び出し元に必要な permissions

呼ばれる側は、**呼び出し元が与えた権限以下しか宣言できない**
（公式ドキュメント: [Reuse workflows](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows)
「permissions can only be maintained or reduced—not elevated—throughout the chain」）。
呼び出し元の job に次の 3 つを与えること。

| 権限                   | 何に要るか                      |
| ---------------------- | ------------------------------- |
| `contents: read`       | 呼び出し元リポジトリの checkout |
| `pull-requests: write` | Approve（reviews API）          |
| `issues: write`        | レビューコメントの投稿          |

さらにリポジトリ設定の **Actions → General → Workflow permissions** で
「Allow GitHub Actions to create and approve pull requests」が有効である必要がある
（無効だと Approve の POST が失敗し、run は approve-if-verdict.sh の UNDETERMINED で赤くなる。
実測した症状は `HTTP 422 Unprocessable Entity`）。

### secret の用意

`CLAUDE_CODE_OAUTH_TOKEN` は `claude setup-token` で発行し、呼び出し元リポジトリの
repository secret に登録する（リポジトリ管理者の作業）。

## プロファイル

`perspectives/<name>.md` が 1 プロファイル。`common.md` は**常に**読まれ、`profile` で指定したものが**足される**。

| profile            | 対象                                                                    |
| ------------------ | ----------------------------------------------------------------------- |
| （指定なし）       | `common.md` だけ。どのリポジトリでも通用する最小の観点                  |
| `harness`          | エージェントの運営ルール文書・CI 定義・自動化スクリプトを持つリポジトリ |
| `chrome-extension` | Chrome 拡張（Manifest V3）                                              |

上の表にない技術スタック（静的サイトジェネレータ・Web アプリのフレームワーク等）の
プロファイルは**まだ作っていない**。指定しない（`common.md` だけで運用する）か、
このリポジトリに追加する。**存在しないプロファイルを指定した場合はそのファイルが無視され、
レビュー本文の `未解決:` にその旨が書かれる**（job は失敗しない）。

## 判定行の契約

レビューは `gh pr comment` のコメント 1 件として投稿され、その本文の形が Approve の契約になる。

- **コードブロックの外に、行頭 `## レビュー` で始まる見出しが 1 本以上**あること
  （⚠ 機械は括弧の中身を照合しないので `## レビュー(claude)` でも通る。
  **書く側は定型どおり `## レビュー(reviewer)` と書く**）
- **コードブロックの外に、行頭 `判定: ` で始まる行がちょうど 1 本**あること
- 値は `APPROVE` または `REQUEST_CHANGES`

`scripts/approve-if-verdict.sh` は、`github-actions[bot]` が job 開始時刻以降に投稿したコメントの中から
この形を探し、`判定: APPROVE` で、かつ PR の head SHA がレビュー時点から動いていないときだけ Approve を押す。
形式の詳細は [`perspectives/common.md`](perspectives/common.md)「レビュー結果の定型フォーマット」が SSOT。

⚠ **同じ形式を人間や他の bot が投稿しても Approve は付かない**（投稿者を `github-actions[bot]` に固定しているため）。
これがこの仕組みの要で、回帰テスト（`tests/approve-if-verdict.test.sh`）が固定している。

## `.trillion-game-actions/` の改竄検査

`review.yml` は、このリポジトリの `main` を呼び出し元のワークスペースの `.trillion-game-actions/` に checkout してから
Claude を走らせる。Claude には `Write` を許しているため、Approve を押す前に

```
git -C .trillion-game-actions status --porcelain --untracked-files=all
```

で**追跡ファイルの変更と未追跡ファイルの追加を検査し**、出力があれば Approve を押さずに run を失敗させる（fail-close）。
Claude に `Write` を許しているため、新規ファイルの追加も検査対象にする（`git diff` は未追跡ファイルを見ない）。

⚠ **checkout の ref は `main` 固定**。呼び出し元の PR が観点や Approve スクリプトを差し替えてから
自分をレビューさせる経路を作らないため、PR で `perspectives/` を変更しても、その PR 自身のレビューには反映されない
（`main` にマージされてから効く）。

## 塞いでいないもの

- **`@main` 参照は可変**。このリポジトリの `main` が変わると、呼び出し元すべてに即時反映される。
  SHA 固定は採らず、このリポジトリ側をルールセットとレビューで守る
- **呼び出し元の PR が自分の workflow 定義を変えて自己 Approve できる**（`pull_request` は PR 側の定義を実行するため）。
  `.yml` を変更する PR を人間がマージする運用で守る

## Issue 紐づけ検査

PR 本文に Issue 紐づけ（`Closes #N` / `Fixes #N` / `Resolves #N` / `Refs #N`）があるかを検査する
composite action。どれも無く、override ラベルも付いていなければ `::error::` を出して job を失敗させる。

呼び出し元の job に次のステップを足す（job を増やさずに差し込めるので、必須チェックの context 名は変わらない）。

```yaml
- name: Issue Check
  uses: machina-gg/trillion-game-actions/.github/actions/issue-link-check@main
  with:
    pr-body: ${{ github.event.pull_request.body }}
    labels-json: ${{ toJSON(github.event.pull_request.labels.*.name) }}
    # override-label: override:no-issue  # 既定値。別名にするときだけ書く
```

| input            | 必須 | 何を渡すか                                                                                 |
| ---------------- | ---- | ------------------------------------------------------------------------------------------ |
| `pr-body`        | ✓    | `github.event.pull_request.body`                                                           |
| `labels-json`    | ✓    | `toJSON(github.event.pull_request.labels.*.name)`（⚠ JSON 配列。カンマ連結の文字列は不可） |
| `override-label` |      | 検査をスキップするラベル名（既定 `override:no-issue`）                                     |

- **`Refs #N` も受理する**（Issue を閉じないシリーズ途中の PR のため）
- **キーワードの直前は行頭か、英字以外の文字であること。** `prefixes #3` / `encloses #5` のように
  英単語の末尾へ部分一致した形は受理しない（受理すると、脚注番号などの `#数字` だけで検査を通過できてしまう）。
  ⚠ **この境界の代償**として、`対応はFixes #3` のように**日本語が直接続く形は受理しない**
  （UTF-8 ロケールでは日本語が `[[:alpha:]]` に入る）。キーワードの前に空白を置くこと
- **番号の直後には境界を置かない。** `Refs #123の続き` のように日本語が続く形を受理するためで、
  代償として `Closes #12abc` のような形も受理する
- **スキップはラベル名の完全一致でだけ効く。** 前後に語を足しただけの似た名前のラベルではスキップしない
  （⚠ ラベル名をカンマ連結した文字列への部分一致にしないこと。`jq` の比較なので**大文字小文字も区別する**）
- **入力を解釈できないときはスキップしない**（fail-close）。`labels-json` が JSON 配列として読めなければ
  警告を出したうえで検査を実行する
- 判定の実体は [`.github/actions/issue-link-check/check.sh`](.github/actions/issue-link-check/check.sh) にある。
  `action.yml` にロジックを書かない（インラインの `run:` は単体テストできない）
- **`jq` を使う。** ランナーに入っているかは
  [actions/runner-images の Ubuntu readme](https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2404-Readme.md)
  の Installed Software で測る。`check.sh` は冒頭で `jq --version` をログに出すので、実際のランナーでの有無は run のログで分かる。
  ⚠ **`jq` が無くても本文の検査は動く**（`jq` を使うのはラベル検査だけ）。無い場合は**ラベルによるスキップだけを諦める**（fail-close）
- 呼び出し元の `on.pull_request.types` に `edited`（本文の修正）と `labeled` / `unlabeled`（ラベルの付け外し）が
  無いと、本文やラベルを直しても再走しない

## このリポジトリを変更するとき

- **public リポジトリである**ことの制約は上記「置き場の規約」を参照
- 呼び出し元の CI の中で走るもの（`.github/workflows/` / `.github/actions/` / `scripts/`）の変更は、
  **レビューを人間が確認したうえで人間がマージする**
- 詳細は [`CLAUDE.md`](CLAUDE.md)

## ディレクトリ構成

| パス                                  | 役割                                                           |
| ------------------------------------- | -------------------------------------------------------------- |
| `.github/workflows/review.yml`        | reusable workflow（本体）                                      |
| `.github/workflows/claude-review.yml` | このリポジトリ自身の PR をレビューする呼び出し元               |
| `.github/workflows/ci.yml`            | このリポジトリ自身の CI（shellcheck / テスト / 整形）          |
| `.github/actions/issue-link-check/`   | Issue 紐づけ検査の composite action（判定は同梱の `check.sh`） |
| `scripts/approve-if-verdict.sh`       | 判定行を読んで Approve を押す                                  |
| `tests/*.test.sh`                     | 上記スクリプトの回帰テスト（外部依存なしで走る）               |
| `perspectives/`                       | レビュー観点（`common.md` + プロファイル）                     |

## ローカルでの検査

SSOT は本節。`CLAUDE.md` の「検査」節からはここを参照する（同じコマンドを 2 箇所に書かない）。

```bash
git ls-files '*.sh' | xargs shellcheck
for t in tests/*.test.sh; do bash "$t" || break; done
npx prettier@3 --check .
```

⚠ **CI（`ci.yml`）の回帰テストのステップは `tests/approve-if-verdict.test.sh` だけを名指しで実行する。**
上の `for` は `tests/` のテストをすべて走らせるので、**手元の方が広く検査する**。
