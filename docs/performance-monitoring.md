# パフォーマンス監視（spark / TPSメトリクス）

サーバーの重さ・ラグを調査するための2つの仕組みを追加した。既存の死活監視（[docker/README.md](../docker/README.md)
の mc-monitor）とは別物で、「落ちているか」ではなく「重くなっていないか・なぜ重いか」を見るための追加。

## spark（その場でのプロファイリング）

`MODRINTH_PROJECTS` にプラグイン `spark` を追加してある（`docker/cloud/compose.yml` /
`docker/all_self_host/server/compose.yml` の papermc サービス）。起動時に自動でダウンロードされる。

### 実行方法

#### ゲーム内チャット（プレイヤーとして）

Minecraftクライアントでサーバーに接続し、`T`キーでチャット欄を開いて実行する。OP権限が必要な場合がある。

```text
/spark tps
/spark health
/spark profiler start
/spark profiler stop
```

#### RCON経由（Pi上のコンソールから、プレイヤー権限不要）

```bash
docker exec papermc rcon-cli spark tps
docker exec papermc rcon-cli spark health
docker exec papermc rcon-cli spark profiler start
docker exec papermc rcon-cli spark profiler stop
```

- `spark profiler stop` の応答に spark.lucko.me のビューアURLが出るので、そこで詳細なプロファイル結果を見る。
- これは単発の調査用であり、継続的な記録にはならない（RCON応答はコンテナの標準出力ログには自動転記されないため、
  Loki/Grafana Cloudのログにも残らない）。

## prometheus-exporter（継続的なメトリクス収集）

`MODRINTH_PROJECTS` に `prometheus-exporter`（Modrinthスラッグ）を追加し、`spark,prometheus-exporter` としてある。
papermc コンテナ内で `9940` ポートに `/metrics` エンドポイントが立ち、TPSなどをPrometheus形式で公開する。

外部には公開しておらず、同じ compose ネットワーク内から以下でスクレイプする設定を追加済み。

- `docker/all_self_host/server/prometheus.yml` → VictoriaMetrics が `papermc:9940` を収集
- `docker/cloud/config.alloy` → Alloy が `papermc:9940` を収集して Grafana Cloud へ remote_write

### ⚠️ メトリクス名は未確認（要検証）

導入したプラグインが実際に公開するメトリクス名を、この時点ではドキュメント上でしか確認していない
（2つの情報源で表記が食い違っていた）。`mc_tps` は確度が高いが、`mc_loaded_chunks_total` /
`mc_entities_total` / `mc_tick_duration_average` などは推測に基づく。

反映後、Pi上で以下を実行して実際の名前を確認し、違っていればダッシュボードのクエリを直す。

```bash
docker exec papermc curl -s localhost:9940/metrics | grep mc_
```

### Grafanaダッシュボード

`docker/all_self_host/client/dashboards/papermc-performance.json` を追加した（Grafanaの「Minecraft」フォルダに
自動で表示される）。パネル: TPS / Tick Duration(ms) / Loaded Chunks(ワールド別) / Entities(ワールド別)。

`docker/cloud` 構成には自前のGrafanaが無く、Grafana Cloud上に直接ダッシュボードを作る運用のため、
同じ内容を見たい場合は上記JSONをGrafana CloudのUI（Dashboards → Import → JSON貼り付け）で取り込む。

## JVM/起動オプションの見直し

papermc の environment に以下も追加・変更した（両 compose.yml）。

- `USE_AIKAR_FLAGS` → `USE_MEOWICE_FLAGS: "true"` — Java 17+向けに再検証された新しいGCフラグセットに切替。
  切替後は `/spark health` などでGCポーズやTPS安定性に悪化が無いか、負荷のかかる時間帯を含めて数日程度観察する。
  悪化した場合は `USE_AIKAR_FLAGS: "true"` に戻せる（両フラグは併用不可）。
- `GUI: "false"` — コンテナ内で不要なGUIウィンドウ初期化をスキップする。副作用はない。

いずれも起動時に読み込まれる設定のため、反映には再作成が必要
（[docs/operations.md](operations.md) の「プラグイン更新」「アップデート手順」を参照。
`docker compose stop papermc` → `docker compose up -d papermc`）。

### 今後の見直し方針

`USE_MEOWICE_FLAGS` / `GUI` などJVM最適化系の変数は、一度決めたら固定という意味ではない。
JVMのバージョンや導入プラグインの構成が変われば最適解も変わるため、上記の TPS / Tick Duration
ダッシュボード（`papermc-performance.json`）を見て、悪化が見られたら適宜書き換える。
compose.yml側にもその旨のコメントを残してある。

- 切替候補: `USE_MEOWICE_FLAGS` ⇔ `USE_AIKAR_FLAGS`（両者は併用不可。片方だけ`"true"`にする）
- 判断基準: 切替後数日〜1週間、負荷のかかる時間帯を含めてTPS/Tick Durationに悪化が出ていないか確認する
- 変更時は `docker/cloud/compose.yml` と `docker/all_self_host/server/compose.yml` の両方を揃える
  （CLAUDE.mdの「papermc 側は A と同じ」方針）
