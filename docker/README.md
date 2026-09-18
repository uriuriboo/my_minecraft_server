# docker/ — 監視構成の2パターン

Minecraft サーバー本体＋監視をどう組むかの選択肢を、パターンごとにディレクトリで分けている。
**どちらか一方だけ**を使うこと（両方同時に起動するとポートとコンテナ名が衝突する）。

```text
docker/
├── all_self_host/          パターンA: すべて自宅内で完結
│   ├── server/             └ Raspberry Pi 側（Minecraft + 収集 + 保存）
│   └── client/             └ 別PC側（Grafana の表示だけ）
└── cloud/                  パターンB: 収集だけ自宅、保存と表示は Grafana Cloud
```

| | パターンA (all_self_host) | パターンB (cloud) |
| --- | --- | --- |
| メトリクス保存 | VictoriaMetrics (Pi) | Grafana Cloud |
| ログ保存 | Loki + Promtail (Pi) | Grafana Cloud (Alloy 経由) |
| ダッシュボード | 別PCの Grafana | Grafana Cloud |
| Pi のメモリ追加消費 | 約 600MB | 約 128MB |
| 外部サービス依存 | なし | あり（無料枠あり） |
| Pi 停止中の閲覧 | 不可 | 可（過去分） |

## パターンA: すべてセルフホスト

Grafana だけを別PCで動かし、Pi 上の VictoriaMetrics / Loki を LAN 越しに参照する。

### 1. Raspberry Pi 側

```bash
cd docker/all_self_host/server
cp .env_sample .env
# LAN_BIND_IP に Pi の LAN アドレス（または VPN アドレス）を設定する
docker compose up -d
```

`LAN_BIND_IP` を設定しないと 8428 / 3100 は 127.0.0.1 にしか bind されず、別PCから繋がらない。
**VictoriaMetrics と Loki は認証を持たない**ので、この2ポートは LAN か VPN の内側だけに公開すること
（ルーターでポート開放しない）。

### 2. 別PC側（Grafana）

```bash
cd docker/all_self_host/client
cp .env_sample .env
# MC_SERVER_HOST に Pi のアドレス、GF_ADMIN_PASSWORD に任意のパスワードを設定する
docker compose up -d
```

`http://localhost:3000` を開く。データソース（VictoriaMetrics / Loki）は
`provisioning/datasources/` で自動登録されるので、UI での追加作業は不要。

ダッシュボードは Grafana UI の **Dashboards → New → Import** から ID を入れるのが早い:

- `1860` Node Exporter Full（CPU / メモリ / 温度 / ディスク）
- 自作したものは `dashboards/` に JSON を置けば自動で読み込まれる（フォルダ「Minecraft」に入る）

主なメトリクス:

- `mc_status_players_online_count` — 接続人数（mc-monitor）
- `mc_status_healthy` — サーバー死活（mc-monitor）
- `mc_router_connections` — ルーター経由の接続数
- `node_*` — Pi のリソース（node-exporter）

## パターンB: Grafana Cloud 併用

```bash
cd docker/cloud
cp .env_sample .env
# Grafana Cloud のスタックから取得した URL / ユーザーID / API キーを設定する
docker compose up -d
```

Alloy が Pi 上でメトリクスとコンテナログを集め、Grafana Cloud に remote_write する。
Pi 側にダッシュボードは無く、閲覧は Grafana Cloud の Web UI で行う。

## 接続経路

両パターンとも同じ:

```text
プレイヤー → playit.gg トンネル → Pi の 127.0.0.1:25565 → mc-router → papermc:25565
```

playit を残しているのでフレンド側に追加インストールは不要。mc-router は接続数メトリクス、
レート制限、そして後述の scale to zero を担当する。mc-router の待ち受けは既定で `127.0.0.1` なので、
ルーターのポート開放は不要。LAN 内から直接繋ぎたいときだけ `.env` の `MC_BIND_IP` を変更する。

`MC_BIND_IP` を特定のLANアドレス（例: `192.168.1.50`）に変更する場合は要注意。playit は
`network_mode: host` でPi自身の`127.0.0.1`経由でmc-routerに繋ぐため、`MC_BIND_IP`を`127.0.0.1`
以外の**特定の**アドレスにすると、そのアドレスでしか待ち受けなくなりplayit経由の接続が切れる。
LANからも直接繋ぎつつplayitも生かしたい場合は、特定アドレスではなく`0.0.0.0`（全インターフェース）
を指定すること。

なお playit → mc-router → papermc と2段挟むため、papermc から見た接続元IPは全プレイヤー同一になる。
IP 単位の BAN や Paper の `connection-throttle` は効かないので、アクセス制御は
`ENFORCE_WHITELIST` で行う。

## ワールドデータ

既定ではリポジトリルートの `data/` をバインドマウントする（`MC_DATA_DIR` の既定値）。
別の場所に置く場合は `.env` の `MC_DATA_DIR` に絶対パスを指定する。
推奨する配置と移行手順は [docs/operations.md](../docs/operations.md) の
「ワールドデータの配置場所」を参照。

## バックアップ

両パターンとも `backup` サービス（[itzg/mc-backup](https://github.com/itzg/docker-mc-backup)）を
含んでいる。`profiles: ["backup"]` と `BACKUP_INTERVAL: "0"` により常駐せず、
呼んだときだけ1回走って終了する。

```bash
docker compose run --rm backup
```

`save-off` → `save-all` → tar → Cloudflare R2 へ転送 → `save-on` → 古い世代の削除、までを
コンテナ側がやる。rcon で `papermc` に繋ぐので、backup は papermc と同じ compose に置く必要がある
（別プロジェクトに切り出すとサービス名を解決できない）。cron 登録は
[docs/operations.md](../docs/operations.md) を参照。

## 使うときだけ起動する（scale to zero）

mc-router の `AUTO_SCALE_UP` / `AUTO_SCALE_DOWN` を有効にしてあり、**既定で有効**。

- プレイヤーが接続すると mc-router が papermc コンテナを起動し、起動完了まで接続を保持する
- 最後のプレイヤーが抜けて `AUTO_SCALE_DOWN_AFTER`（既定 30 分）経つとコンテナを停止する
- 停止は Docker の stop API 経由なので papermc の `stop_grace_period: 1m` が尊重される

常時起動に戻すには `.env` に `AUTO_SCALE=false` を書く。

### 仕組み上の注意

- **papermc の `mc-router.*` ラベルが経路の唯一の定義**。`MAPPING` / `DEFAULT` 環境変数は
  コンテナを特定できず auto-scale に使えないため廃止した。ラベルを消すと経路が1つも登録されず
  誰も接続できなくなる。起動後に `docker compose logs mc-router` で経路が登録されているか確認する。
- **初回接続は待たされる**。mc-router は起動完了を最大60秒ほど待つが、10G ヒープの Paper が
  それを超えるとクライアント側がタイムアウトする。その場合は一度切って再接続すれば入れる。
  頻繁に起きるようなら `AUTO_SCALE_DOWN_AFTER` を延ばす。
- **停止中は `mc_status_healthy` が 0 になる**。mc-monitor は mc-router を介さず papermc に
  直接繋ぐため、スケールダウン中は「落ちている」と記録される。死活アラートをこの値だけで
  組まないこと。
- **バックアップは影響を受けない**。`docker compose run --rm backup` は `depends_on` により
  papermc を起動してから走る。
- mc-router は **Java Edition (TCP) 専用**。Bedrock (UDP 19132) には使えない。

### AUTOPAUSE を使っていない理由

itzg/minecraft-server の `ENABLE_AUTOPAUSE` は、ポート 25565 への接続を knockd で監視し、
一定時間プレイヤーがいなければ Java プロセスを SIGSTOP する機能。ただし2点で auto-scale に劣る。

1. サーバー一覧のメニュー ping も「ノック」として数えられ `AUTOPAUSE_TIMEOUT_KN`（既定120秒）を
   リセットする。mc-monitor が 60 秒ごとに ping するので、そもそも発火しない。
2. 発火してもプロセスを止めるだけで、確保済みのヒープは解放されない。

auto-scale はコンテナごと落とすので RAM も返る。
