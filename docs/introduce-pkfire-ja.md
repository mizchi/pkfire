# pkfire — Pkl で書く、型付きタスクランナー

## tl;dr

- `Taskfile.pkl` (Pkl の typed schema) でタスクを書いて、`pkf` CLI で走らせる。`just` / `make` / `Taskfile.yml` の代替
- Bazel スタイルの content-addressed cache が標準装備。`inputs` / `outputs` を宣言した時点で、未変更タスクは再実行ゼロ
- リモート HTTP cache を 1 環境変数で有効化、CI と開発者で hit を共有
- `pkf affected --since=origin/main` で「PR の diff が触ったタスクだけ」を抽出
- 各タスクは Pkl の値なので、ジェネリクス的な `local function buildTask(p)` でマトリクス展開できる。 4 OS × 2 arch の cross-compile が 1 関数になる
- typed params (`pkf run release --version=X.Y.Z`)、`pkf hooks install` で git hook 配線、service オーケストレーション (`pkf up`)、`pkspec` との spec ↔ task 双方向リンクも入っている
- 0.10.0 リリース済み (`go install github.com/mizchi/pkfire/cmd/pkf@latest` / `nix profile install github:mizchi/pkfire` / GitHub Action は `uses: mizchi/pkfire@v0`)

## なぜ書いてるか

`just` も `make` も `npm scripts` も、結局は **文字列の塊**。タスク名は string、deps の参照も string、inputs の glob はコピペ。「6 globs の `.go` を 3 つのタスクで使い回す」みたいな共通化に型が効かない。リネーム漏れは CI で初めて気づく。

それと、これらは **キャッシュを持たない**。`go test` を毎回フル実行するのは正直しんどいので、各プロジェクトが `Makefile` の中で sentinel file を作ったり、CI で artifact を s3 に逃したり、独自で incremental の真似事をすることになる。

pkfire は両方を解決する。Pkl で型を入れて文字列じゃなくし、Bazel 由来の content-addressed cache を runner 層に組み込む。タスクのリネームは Pkl の name-resolution エラーで弾かれ、未変更タスクは action key が一致した瞬間に hit して output が CAS から戻る。

## 動かしてみる

```sh
go install github.com/mizchi/pkfire/cmd/pkf@latest
# pkl CLI も必要 (https://pkl-lang.org/main/current/pkl-cli/)

pkf init
pkf list
pkf run hello
```

`pkf init` で出てくる雛形 (`hello` 1 つだけのスケルトン):

```pkl
amends "https://raw.githubusercontent.com/mizchi/pkfire/main/pkl/Taskfile.pkl"

local hello = new Task {
  name = "hello"
  description = "Smoke task — replace with your own"
  cmd = "echo hello from pkfire"
}

tasks { hello }
```

ここから自分のタスクを足していく。 cache を効かせる代表例 (build → test の DAG):

```pkl
local build = new Task {
  name = "build"
  cmd = "go build -o bin/app ./cmd/app"
  inputs { "**/*.go"; "go.mod"; "go.sum" }
  outputs { "bin/app" }
}

local test = new Task {
  name = "test"
  cmd = "go test ./..."
  inputs { "**/*.go" }
  deps { build }   // ← Task 値の参照、文字列ではない
}

tasks { hello; build; test }
```

`pkf run test` で `build` → `test` の DAG が回り、 `bin/app` は cache key (`inputs` + `cmd` + `env` の SHA-256) ごとに `~/.cache/pkfire/cas/<aa>/<rest>/` に保存される。 2 回目以降は変更が無ければ hit、 output が CAS から restore される。

## 何で嬉しいのか

### 1. リネームが安全になる

```pkl
local build = new Task { name = "build"; ... }
local test  = new Task { name = "test"; deps { build }; ... }
```

`build` という Pkl の局所変数を `compile` に変えれば、`deps { build }` が即座に name resolution エラーになる。文字列ベースの runner では「リネームしたつもりが deps に古い名前が残ってる」が CI まで気づかれない。

### 2. マトリクスが関数になる

```pkl
local function buildTask(os: String, arch: String): Task = new {
  name = "build-\(os)-\(arch)"
  cmd = "GOOS=\(os) GOARCH=\(arch) go build -o bin/app-\(os)-\(arch) ./cmd/app"
  inputs { "**/*.go" }
  outputs { "bin/app-\(os)-\(arch)" }
}

local platforms = List(
  Pair("linux", "amd64"),
  Pair("linux", "arm64"),
  Pair("darwin", "amd64"),
  Pair("darwin", "arm64")
)

tasks {
  for (p in platforms) { buildTask(p.first, p.second) }
}
```

4 個の near-duplicate な `just` recipe が 1 関数に collapse する。`examples/dogfood/Taskfile.pkl` は pkfire 自身の cross-compile をこの形で書いている。

### 3. cache hit がデフォルト

```sh
$ pkf run test
[pkf] build: ran 797a1bd1d46b
[pkf] test:  ran 0c2f31ab4e88
[pkf] done: 2 tasks · 0 hit · 2 ran · 0 uncached (3.4s)

# ファイルを触らずもう一度
$ pkf run test
[pkf] build: hit 797a1bd1d46b
[pkf] test:  hit 0c2f31ab4e88
[pkf] done: 2 tasks · 2 hit · 0 ran · 0 uncached (0.2s)
```

`inputs` の glob にマッチするファイルが 1 byte でも変われば cache miss、 それ以外は hit。 `outputs` は CAS にアーカイブされていて、 hit 時はそこから restore される (再 build しない)。 `cache = false` を明示したタスクは `ran (uncached) <hash>` で出るので、 summary 末尾の `uncached` カウンタで「キャッシュ無効のタスクが何個走ったか」が確認できる。

### 4. リモート cache が 1 env で有効

```sh
export PKFIRE_REMOTE_CACHE=https://cache.example.com
export PKFIRE_REMOTE_TOKEN=...
pkf run ci
```

CI と開発者が同じ cache を share できる。`pkf run --remote-only` で「remote にちゃんと書き込んだか」だけを検証するモードもある。

### 5. 「PR の diff が触ったタスクだけ」を抽出

```sh
pkf affected --since=origin/main --dry-run
```

`inputs` glob が diff の changed file と交差したタスク + その dependent closure を出す。monorepo で「触った package の test だけ動かしたい」が、設定ファイル 0 行で実現する。

### 6. service オーケストレーション

```pkl
local api = new Task {
  name = "api"; service = true
  cmd = "go run ./cmd/api"
  readyPort = 8080
}

local e2e = new Task {
  name = "e2e"
  cmd = "playwright test"
  services { api }      // ← e2e 中だけ api を上げて、終わったら止める
}
```

`pkf run e2e` で api を spawn → port 8080 が開くのを待つ → e2e を実行 → SIGTERM で api を止める、まで自動。`pkf up api` で別 terminal の dev server を立てておけば、`pkf run e2e` は spawn せず既存プロセスを reuse する (port を probe して判定)。

### 7. typed params

```pkl
local release = new Task {
  name = "release"
  cmd = "git tag -a v$VERSION -m 'release v$VERSION'"
  params {
    new { name = "version"; type = "string"; description = "semver to tag" }
  }
}
```

`pkf run release --version=0.10.0` で実行。 enum / int / bool もある (`--bump=patch|minor|major` のような縛り)。 param value は action key に folded されるので、`--version=0.10.0` と `--version=0.11.0` は別 cache entry。

### 8. git hooks が pkfire-native

```pkl
local prePush = new Task {
  name = "pre-push"
  cache = false
  deps { secretlint; specCheck }   // ← 中身は他のタスクの組み合わせ
  cmd = "echo pre-push ok"
}
```

`pkf hooks install` で `.git/hooks/pre-push` が `pkf run pre-push` に shim される。`pkf hooks list` で「どの event がどの task に繋がっているか」が見える。

### 9. pkspec との spec ↔ task リンク

[`mizchi/pkspec`](https://github.com/mizchi/pkspec) は spec / test contract tool。 pkfire の main branch (次の 0.11.0 リリースで入る) で `Task.specRef` が入って、 release / migration 系の "コードに居場所が無い" 実装も spec から指せるようになった。 0.10.0 ではまだ使えないので、 試すなら `go install github.com/mizchi/pkfire/cmd/pkf@main` で main を入れる。

```pkl
local release = new Task {
  name = "release"
  cmd = "..."
  specRef = "release-pipeline"   // ← pkspec の Scenario.id
}
```

```sh
pkf describe release                    # spec: release-pipeline が表示される
pkf affected --since=HEAD~1 --with-specs # diff が触った Scenario id を集計
pkf affected --since=HEAD~1 --specs-only | xargs pkspec lint --scan
```

逆向きには pkspec の `Implementation { kind = "task"; at = "Taskfile.pkl#release" }` で spec が task を名指せる。 `pkspec check --strict` が `pkf list --json` を呼んで「named task が実在するか」までクロス検証する。

詳細は `examples/with-pkspec/` と `skills/pkfire/assets/recipes/19-spec-task-link.pkl`。

## どこに居るか / どこに居ないか

- **居る**: 個人 / 小チームの monorepo、CI gate を pkfire に集約したい OSS、cross-compile マトリクスを単純化したい Go / Rust / Node project
- **居ない**: Bazel をフル投入している巨大 monorepo (pkfire は build cache であって build system ではない、レイヤを越えて language-aware には踏み込まない)、IDE 統合が必須のチーム (現状 CLI 単独)

## 設計上の限界

- **言語非依存 = 言語固有最適化を持たない**。`go test -count=1` の cache 機構と pkfire の cache は別物。pkfire が cache miss して内部の `go test` も全テスト走らせる、みたいな二重 cache の話は出る (普通は気にならないが)
- **Pkl の学習コスト**。amends / template / `for` 構文に最初慣れる必要がある。引き換えに型と composition が手に入る、というトレードオフを受け入れられないと選ぶ意味がない
- **Mac × Nix のビルド遅延**。Nix 経由 install は flake build に少し時間がかかる。手っ取り早く触るなら `go install` が早い

## 次のリリース

0.11.0 で `Task.specRef` + `pkf affected --with-specs` + 全 subcommand の `-h` 整備 + `pkf describe TASK` + `pkf cache --help` 修正 + `pkf doctor` の cache 閾値 WARN + `bump-version` recipe を入れた。 issue #11–#14 を解消した dogfood サイクルの成果。

## さわってみる

```sh
go install github.com/mizchi/pkfire/cmd/pkf@latest
pkf init && pkf list && pkf run hello
```

既存 just / Makefile からの移行サンプルは
[`examples/`](https://github.com/mizchi/pkfire/tree/main/examples) を見るのが早い。
`basic` (最小)、 `dogfood` (pkfire 自身の cross-compile マトリクス)、 `monorepo` /
`split-import` / `node` / `rust` / `diagnostics` / `remote-cache-worker` /
`with-pkspec` (今回の spec 連携) が並んでいる。

Repo: https://github.com/mizchi/pkfire
