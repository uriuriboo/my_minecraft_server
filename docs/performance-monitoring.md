# パフォーマンス監視（spark / TPSメトリクス / JVMプロファイル）

サーバーの重さ・ラグを調査するための仕組みを追加した。既存の死活監視（[docker/README.md](../docker/README.md)
の mc-monitor）とは別物で、「落ちているか」ではなく「重くなっていないか・なぜ重いか」を見るための追加。

## ⚠️ 現在 spark / prometheus-exporter は無効化中

導入直後から papermc が起動できなくなっていたため、両 compose.yml の `MODRINTH_PROJECTS` をコメントアウトして無効化した。

- **spark**: Modrinth上でPaper/Bukkit向けビルドの提供が終了している（fabric/forge/neoforge/quiltのみ）。バージョンを合わせても解決しない。
- **prometheus-exporter**: Modrinthのビルドが `26.1.2` までしか対応しておらず、`VERSION: "26.2"` 以降では入手できない。

この結果、`papermc-performance.json` ダッシュボード（TPS / Tick Duration / Loaded Chunks / Entities）は
データソースが無いため **すべて No Data 表示になる**。ダッシュボードのJSON自体は壊れていないので、
代替の入手方法が見つかるか、各プラグインが対応バージョンを出すまではこの状態のまま。

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

## JVM継続的プロファイリング（Pyroscope）

Alloy の `pyroscope.java` コンポーネントで papermc の JVM を async-profiler で継続的にプロファイリングしている。
spark（手動の単発プロファイル）・prometheus-exporter（TPS等のメトリクス、現在無効化中）とは別軸で、
「どのメソッドがCPUを使っているか」をフレームグラフで継続的に見られる。両パターンで導入済み。

- **`docker/cloud`**: `config.alloy` の `pyroscope.write` が Grafana Cloud Profiles へ送る。
  `.env` に `GRAFANA_CLOUD_PROFILES_URL` / `GRAFANA_CLOUD_PROFILES_USER` の追加が必要
  （値は Grafana Cloud の Profiles スタック詳細ページ）。既存の `GRAFANA_CLOUD_API_KEY` を再利用する。
  確認は Grafana Cloud の Explore Profiles で `service_name="papermc"` を見る。
- **`docker/all_self_host`**: `server/compose.yml` に `pyroscope`（`grafana/pyroscope:latest`）コンテナを追加し、
  `config.alloy` の `pyroscope.write` はそこへ push する。VictoriaMetrics/Lokiと同様に認証が無いポート(4040)を
  `LAN_BIND_IP` で絞って公開し、`client` 側の Grafana に `Pyroscope` データソース（`grafana-pyroscope-datasource`）
  を provisioning で追加した。確認は別PCのGrafanaの Explore で Pyroscope データソースを選び
  `service_name="papermc"` を見る。
- 両パターン共通で、alloy コンテナに `pid: "service:papermc"` と `cap_add: [SYS_PTRACE]` を追加している。
  discovery.process が papermc コンテナ内のプロセス（PID 1 = java想定）を見えるようにするための設定で、
  host全体のPIDを見る `pid: host` にはしていない。
- 反映後は Pi 上で `docker compose up -d` してから、プロファイルが届いているか確認する。届かない場合は
  `docker compose logs alloy` で `pyroscope.java` 周りのエラー（ptrace権限やPIDネームスペース関連）を確認する。

### Grafanaダッシュボード（papermc-profiles.json）

`docker/all_self_host/client/dashboards/papermc-profiles.json` を追加した。Explore Profilesの時系列グラフに
出てくる代表的な3値（CPU使用率・メモリ確保レート・メモリ確保個数）を並べただけの構成で、Flame Graphは含まない
（Flame Graphは特定時点の詳細調査用のため、常時表示する定点観測ダッシュボードには向かない）。

- **`docker/all_self_host`**: `papermc-performance.json` と同様に自動でGrafanaの「Minecraft」フォルダに表示される。
  データソースは provisioning で追加した `Pyroscope`（uid: `pyroscope`）を固定で参照している。
- **`docker/cloud`**: `dashboards/papermc-performance.json` 等と同じ運用。`docker/cloud/dashboards/papermc-profiles.json`
  はデータソースのuidが `REPLACE_WITH_YOUR_PYROSCOPE_DATASOURCE_NAME` のプレースホルダのままコミットしてある
  （Grafana CloudのPyroscopeデータソースのuidは環境ごとに異なり、リポジトリに実値を書けないため）。
  Pi上で実際のuid（Grafana Cloud → Connections → Data sources → Pyroscope詳細ページで確認）に置き換えた
  `papermc-profiles.local.json` を作ってGrafana CloudのUI（Dashboards → Import → JSON貼り付け）で取り込む。
  `*.local.json` は `.gitignore` 対象なのでコミットされない。
- `profileTypeId` はPyroscope Javaの一般的な命名（`process_cpu:cpu:nanoseconds:cpu:nanoseconds` /
  `memory:alloc_in_new_tlab_bytes:bytes:space:bytes` / `memory:alloc_in_new_tlab_objects:count:space:bytes`）で
  組んでいるが、実際にどの値がドロップダウンに出るかはPyroscopeのバージョンで変わりうる。反映後、パネルが
  「No data」になる場合はパネル編集画面の Profile type ドロップダウンで実際のIDに直す。

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
