# PaperMC on Raspberry Pi 5 - 運用手順

## 前提: 作業ディレクトリ

compose は `docker/` 配下にパターン別に置いてある（[docker/README.md](../docker/README.md)）。
`docker compose` 系のコマンドは、稼働させている構成のディレクトリで実行する。

```bash
cd ~/papermc/docker/all_self_host/server   # 全セルフホスト構成の場合
cd ~/papermc/docker/cloud                  # Grafana Cloud 構成の場合
```

以降の `docker compose ...` はこのディレクトリにいる前提。`docker exec` 系はどこからでも動く。

## 日常コマンド

```bash
docker exec papermc rcon-cli list        # 接続中プレイヤー確認
docker exec papermc rcon-cli tps         # TPS確認（20が満点）
docker exec papermc rcon-cli say "メッセージ"  # 全体アナウンス
docker exec papermc rcon-cli save-all    # 手動セーブ
```

## 安全な停止・再起動

```bash
docker compose stop papermc    # SIGTERM経由でMinecraft側のstop相当処理→正常終了
docker compose start papermc
docker compose restart papermc
```

なお通常時は mc-router の scale to zero により、プレイヤーがいなくなると papermc は自動で停止する
（詳細は [docker/README.md](../docker/README.md)）。手で止める必要があるのはメンテナンス時だけ。

⚠️ **禁止事項**

- `docker kill` の使用（ワールド破損リスク）
- 電源を直接切る（同上）

## アップデート手順

```bash
docker compose pull papermc
docker compose up -d papermc
```

- `VERSION` を空文字にしている場合、再作成のたびに最新Paperビルドを自動解決
- 特定バージョンに固定している場合は compose の `VERSION` を書き換えてから実行
- **メジャーバージョンアップ前（例: 1.21→1.22）は必ずバックアップを取る**（ワールド互換性は前方のみ）

## ワールドデータの配置場所

### 現在のディレクトリ構成

Paper 26.2 では3ディメンションがすべて `world/` 配下に統合されている。

```text
<MC_DATA_DIR>/world/
├── level.dat
├── dimensions/minecraft/overworld/    # 旧 world
├── dimensions/minecraft/the_nether/   # 旧 world_nether
├── dimensions/minecraft/the_end/      # 旧 world_the_end
└── players/
```

古い手順で使われていた `world_nether` / `world_the_end` は存在しないため、tar や rm の対象に含めると
「そんなファイルは無い」というエラーになる。

### 置き場所の指定

`papermc` のマウント元と `backup` のバックアップ元は、どちらも `.env` の `MC_DATA_DIR` を見る。
未設定ならリポジトリルートの `data/`。相対パスは compose ファイルのある場所が基準。

### 推奨: リポジトリの外、できれば SSD/NVMe 上に置く

既定の `~/papermc/data` はリポジトリの中にあり、次の点で望ましくない。

- `.gitignore` に入っていても `git clean -xdf` は `-x` によって無視対象ごと削除する。ワールドが消える。
- 設定（バージョン管理したい・小さい）と実行時状態（可変・数百MB以上）が同じツリーに同居する。
- リポジトリを別マシンに clone/同期したとき、`data/` だけ付いてこないため前提が崩れる。

さらに Raspberry Pi 特有の理由として、Minecraft はチャンク保存で書き込みが多く、**microSD は摩耗で
壊れる**。Pi 5 なら NVMe HAT か USB SSD に逃がすのが望ましい。

```text
~/papermc/            git clone（compose と docs だけ）
/mnt/ssd/minecraft/   ワールド実体（MC_DATA_DIR）
/mnt/ssd/backups/     ローカルのtar（BACKUP_DIR）
```

SSD が無いなら最低限 `/srv/minecraft` などリポジトリ外に出すだけでも上記3点は解消する。
**NFS / SMB などのネットワークマウントには置かないこと**（`session.lock` のファイルロックが
正しく働かず破損の原因になる）。

### 移行手順

```bash
docker compose stop papermc
sudo mkdir -p /mnt/ssd/minecraft
sudo rsync -a --info=progress2 ~/papermc/data/ /mnt/ssd/minecraft/
sudo chown -R "$USER:$USER" /mnt/ssd/minecraft

echo 'MC_DATA_DIR=/mnt/ssd/minecraft' >> .env
docker compose up -d papermc   # マウント元の変更は restart では反映されない
```

起動してワールドが正しく読めたことを確認してから、旧 `~/papermc/data` を削除する。

## バックアップ

バックアップは [itzg/mc-backup](https://github.com/itzg/docker-mc-backup) コンテナが行う。
各 compose の `backup` サービスで、`save-off` → `save-all` → tar → Cloudflare R2 へ転送 →
`save-on` → 古い世代の削除、までを一括でやってくれる。

常駐させる必要はない。`profiles: ["backup"]` と `BACKUP_INTERVAL: "0"`（= 1回だけ実行して終了）を
指定してあるので、`docker compose up -d` では起動せず、呼んだときだけ立ち上がって終了する。
rcon で `papermc` に繋ぐ必要があるため、backup は papermc と同じ compose の中に置いてある。

### 手動実行

```bash
docker compose run --rm backup
```

これを cron に登録すれば定期バックアップになる（後述）。

### 事前準備

1. `.env` に `RCON_PASSWORD` を設定する。未設定だと itzg イメージが起動ごとにランダムな
   パスワードを生成してしまい、backup コンテナから rcon で繋がらない。
   **設定・変更したら `docker compose up -d papermc` でコンテナを作り直す**（`restart` では反映されない）。
2. Cloudflare ダッシュボードで R2 バケットを作り、「Manage R2 API Tokens」で
   Object Read & Write のトークンを発行する。
3. `.env` に `R2_ENDPOINT` / `R2_BUCKET` / `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` を書く。
   書式は稼働中の構成の `.env_sample`（例:
   [docker/all_self_host/server/.env_sample](../docker/all_self_host/server/.env_sample)）を参照。

### cron登録（毎日3時実行）

ラッパースクリプトは置いていない。`cd` して `docker compose run` するだけなので、crontab に直接書く。

```bash
crontab -e
# 以下を追加（cron は PATH が短いので絶対パスで書く）
0 3 * * * cd /home/pi/papermc/docker/all_self_host/server && /usr/bin/docker compose run --rm backup
```

Grafana Cloud 構成で運用している場合は `docker/cloud` に読み替える。

`docker compose run` は backup コンテナの終了コードをそのまま返すので、失敗すれば cron の
メール通知で気づける。

### 世代管理

`RETENTION_DAYS`（既定7日）より古いバックアップが削除される。R2 側の保持期間を確実に管理したい場合は、
スクリプト任せにせず R2 バケットのライフサイクルルールで設定するほうが堅い。

### 復元手順

R2 から取得する場合は、まず一覧を見て対象を落とす。

```bash
docker compose run --rm --entrypoint rclone backup lsl r2:$R2_BUCKET/$R2_PREFIX
docker compose run --rm --entrypoint rclone backup \
  copy r2:$R2_BUCKET/$R2_PREFIX/world_YYYY-MM-DD_HHMM.tgz /backups
```

展開してサーバーを起動する。`$MC_DATA_DIR` / `$BACKUP_DIR` は `.env` で設定した実際のパスに読み替える
（未設定ならそれぞれリポジトリルートの `data/` と `backups/`）。

```bash
docker compose stop papermc
rm -rf "$MC_DATA_DIR/world"
tar xzf "$BACKUP_DIR/world_YYYY-MM-DD_HHMM.tgz" -C "$MC_DATA_DIR"
docker compose start papermc
```

## プラグイン更新

- 配置場所: `$MC_DATA_DIR/plugins`（未設定ならリポジトリルートの`data/plugins`）
- 更新は必ず **サーバー停止中** に差し替える（稼働中の書き換えはクラスロード不整合でクラッシュの可能性）

## ログ監視

```bash
docker compose logs -f papermc --tail 100
```

- `Can't keep up!` のような警告が出ていないか定期確認
- TPSが20を大きく下回る場合、`VIEW_DISTANCE` / `SIMULATION_DISTANCE` を下げる調整を検討

## トラブルシューティング早見表

| 症状 | 確認箇所 |
| --- | --- |
| 友人が接続できない | `docker compose logs -f playit` でエージェントの接続状態確認。次に `docker compose logs mc-router` で papermc への経路が登録されているか（`mc-router.*` ラベルが効いているか）確認 |
| 久しぶりの接続で1回目が弾かれる | scale to zero からの起動待ち。一度切って再接続する。頻発するなら `AUTO_SCALE_DOWN_AFTER` を延ばす |
| 誰も遊んでいない時間に「サーバーが落ちている」と出る | scale to zero で停止中の正常な状態。`mc_status_healthy` は停止中 0 になる |
| ラグがひどい | `rcon-cli tps` でTPS確認、`VIEW_DISTANCE`調整 |
| ワールドが読み込まれない/壊れた | `$MC_DATA_DIR/world`（未設定なら`data/world`）フォルダの存在確認、バックアップから復元 |
| アップデート後起動しない | `docker compose logs papermc` でエラー内容確認、バージョン間の非互換プラグインがないか確認 |

## FAQ（よくある誤解）

- **Q. シードを設定すればワールドが途切れない？**
  A. いいえ。シードは初回生成時のみ有効な設定で、ワールドの継続性とは無関係。継続性を守るのは「正常停止」「`MC_DATA_DIR`（データディレクトリ）の保全」「定期バックアップ」の3点。

- **Q. Cloudflare Tunnelではダメ？**
  A. 友人側にもcloudflaredのインストールが必要になるため、不特定多数への公開には不向き。playit.ggはクライアント側の準備が不要なため採用。

- **Q. RCONを外部公開してDiscord Bot等から操作したい**
  A. RCONは平文プロトコルのため直接の外部公開は非推奨。VPN（WireGuard等）やCloudflare Tunnel経由でプライベートにアクセスする構成を推奨。
