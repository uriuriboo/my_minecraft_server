# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## このリポジトリについて

アプリケーションコードは無く、自宅の Raspberry Pi 5 (16GB) 上で稼働させている個人用 PaperMC (Minecraft) サーバーの構築・運用手順と Docker 構成を管理するリポジトリ。ビルド/lint/テストの概念は無い。Markdown のみ markdownlint（`MD013` 無効）と `.editorconfig`（LF・UTF-8・2スペース）に従う。

## compose は `docker/` 以下の3つだけ

リポジトリルートに compose は無い（以前あった `docker-compose.yml` は `docker/` に統合して削除済み）。

| ファイル | 実行場所 | 位置づけ |
| --- | --- | --- |
| `docker/all_self_host/server/compose.yml` | Pi | 監視パターンA（全セルフホスト）。papermc + playit + mc-router + backup + VictoriaMetrics/Loki/Promtail |
| `docker/all_self_host/client/compose.yml` | 別PC | パターンA の Grafana。データソースは provisioning で自動登録 |
| `docker/cloud/compose.yml` | Pi | 監視パターンB（Grafana Cloud へ Alloy で remote_write）。papermc 側は A と同じ |

Pi 側の2つは**排他**（container_name とポートが衝突する）。詳細は [docker/README.md](docker/README.md)。

`docs/setup.md` には compose の中身を転記しない方針（過去に転記された例が実体とずれて事故のもとになった）。設定値を知りたいときは compose ファイルそのものを読む。

## `.env` の置き場所

`docker compose` は **compose.yml と同じディレクトリの `.env`** しか自動で読まない。そのため `.env_sample` も compose と同じ階層に置いてある（`docker/all_self_host/server` / `docker/all_self_host/client` / `docker/cloud`）。別階層のものを使わせたい場合は `--env-file` を明示する。

## よく使うコマンド

Raspberry Pi 側で、稼働させている構成のディレクトリに `cd` してから実行する前提。

```bash
cd ~/papermc/docker/all_self_host/server   # または docker/cloud

# 起動・停止・再起動（正常終了のため必ず stop/start/restart を使う）
docker compose up -d
docker compose stop papermc
docker compose start papermc
docker compose restart papermc

# ログ確認
docker compose logs -f papermc --tail 100
docker compose logs -f playit

# バックアップを1回だけ実行（profiles 付きなので up -d では起動しない）
docker compose run --rm backup

# サーバー内コマンド（rcon-cli経由。どのディレクトリからでも動く）
docker exec papermc rcon-cli list
docker exec papermc rcon-cli tps
docker exec papermc rcon-cli say "メッセージ"
docker exec papermc rcon-cli save-all

# Paperの更新
docker compose pull papermc
docker compose up -d papermc

# compose を編集したら構文と解決結果を確認する（Pi でなくても走る）
docker compose --env-file .env_sample -f <path> --profile backup config
```

## バックアップ

[itzg/mc-backup](https://github.com/itzg/docker-mc-backup) の `backup` サービスが `save-off` → `save-all` → tar → Cloudflare R2 へ転送 → `save-on` → 古い世代の削除、まで一括で行う。`profiles: ["backup"]` + `BACKUP_INTERVAL: "0"` で常駐せず、`docker compose run --rm backup` で1回だけ走る。ラッパースクリプトは置かず、cron にこのコマンドを直接書く方針（過去にシェルスクリプト側が実体とずれて壊れたため、ロジックを二重に持たない）。

- **backup は papermc と同じ compose に置く** — rcon で `papermc` を名前解決する必要があるため、別プロジェクトに切り出すと動かない。
- **`RCON_PASSWORD` は `.env` で固定が必須** — 未設定だと itzg イメージが起動ごとにランダム生成し、backup 側と一致しない。変更後は `docker compose up -d papermc` でコンテナ再作成（`restart` では反映されない）。

手順の詳細は [docs/operations.md](docs/operations.md)。ワールドデータに触る変更を提案する際は必ずこの手順を踏襲すること。

## scale to zero（使うときだけ起動）

mc-router の `AUTO_SCALE_UP` / `AUTO_SCALE_DOWN` が**既定で有効**。プレイヤーの接続で papermc コンテナが起動し、最後の1人が抜けて `AUTO_SCALE_DOWN_AFTER`（既定30分）で停止する。`.env` の `AUTO_SCALE=false` で常時起動に戻せる。

- **経路は papermc の `mc-router.*` ラベルだけで決まる** — `MAPPING` / `DEFAULT` 環境変数はコンテナを特定できず auto-scale に使えないので廃止した。ラベルを消すと誰も接続できなくなる。
- **停止中は `mc_status_healthy` が 0 になる** — mc-monitor は mc-router を介さず papermc に直接繋ぐため。死活アラートをこの値だけで組まない。
- papermc の `restart: unless-stopped` は auto-scale と両立する（mc-router による停止は明示停止扱いなので勝手に復帰しない）。
- mc-router は Java Edition (TCP) 専用。Bedrock (UDP 19132) では使えない。

## 重要な運用上の制約（ドキュメントに明記されている禁止事項・注意点）

- **`docker kill` や電源off直接切断は禁止** — ワールド破損リスクがあるため、必ず `docker compose stop`（SIGTERM経由）を使う。同じ理由で compose には `stop_grace_period: 1m` が要る（Docker 既定の10秒では保存が間に合わない）。
- **プラグイン更新はサーバー停止中のみ** — 稼働中の `$MC_DATA_DIR/plugins` 書き換えはクラスロード不整合でクラッシュの可能性がある。
- **メジャーバージョンアップ（例: 1.21→1.22）前は必ずバックアップ** — ワールドの互換性は前方のみ（新→旧には戻せない）。`VERSION` を省略すると `LATEST` 扱いになり意図せず上がるので固定する。
- **SEEDは初回ワールド生成時のみ有効** — 既存の `world` がある状態でSEEDを変えても無視される。ワールドの継続性は「正常停止」「データディレクトリの保全」「定期バックアップ」の3点で守られる。ワールドを名前付きボリュームに移すような変更は既存ワールドを切り離すことになるので提案しない。
- **ワールドの実体は `.env` の `MC_DATA_DIR`** — papermc と backup の両方がここを見る。未設定ならリポジトリルートの `data/`。リポジトリ外・できれば SSD への移設を推奨している（理由と手順は [docs/operations.md](docs/operations.md) の「ワールドデータの配置場所」）。
- **RCONは平文プロトコルのため外部公開しない** — Discord Bot等から操作したい場合はVPN（WireGuard等）やCloudflare Tunnel経由のプライベートアクセスを前提に構成する。
- **監視スタックの VictoriaMetrics(8428) / Loki(3100) も認証が無い** — LAN か VPN の内側だけに bind する（`LAN_BIND_IP`）。インターネットに露出させない。
- **`MC_BIND_IP` を特定のLANアドレスにすると playit が繋がらなくなる** — playit は `network_mode: host` で Pi の `127.0.0.1` 経由で mc-router に接続するため、`MC_BIND_IP` を `127.0.0.1` 以外の特定アドレスにすると待ち受けがそのアドレスだけになり、playit経由の接続が切れる。LANからも直接繋ぎたい場合は特定アドレスではなく `0.0.0.0` を指定する。
- 外部公開手段としてplayit.ggを採用している理由は「フレンド側の追加インストールが不要」なため（Cloudflare Tunnelは接続先にもcloudflaredが必要になり不採用）。mc-router を挟む構成でも playit は外さない。
- **`MEMORY` は 10G** — 16GBモデルで OS / Docker / playit / 監視スタックに残す分。増やす提案をしない。

## 既知の不整合（触るときに注意）

- **ワールドは `$MC_DATA_DIR/world` の1ディレクトリで完結する** — Paper 26.2 では3ディメンションが `world/dimensions/minecraft/` 配下に統合されており、旧レイアウトの `world_nether` / `world_the_end` は存在しない。バックアップ・復元手順でこれらを対象に含めない。
- **`ENABLE_AUTOPAUSE` は使わない（`false` 固定）** — mc-monitor の 60 秒ごとの status ping が「ノック」として数えられ `AUTOPAUSE_TIMEOUT_KN`（既定120秒）を毎回リセットするため発火せず、発火してもヒープは解放されない。代わりに mc-router の auto-scale を使っている。
- **playit → mc-router → papermc と2段挟むと接続元IPが全プレイヤー同一になる** — IP BAN や Paper の `connection-throttle` は効かない。アクセス制御は `ENFORCE_WHITELIST` で行う。

## Git管理状態の注意

`docker/` はまだ未追跡（untracked）。それ以外（`CLAUDE.md` / `README.md` / `docs/` / `.gitignore` / `.editorconfig` / `.markdownlint.json` / `.vscode/tasks.json`）は追跡済み。ルートの `docker-compose.yml` と `backup.sh` は削除済み。`.gitignore` は `.env` / `data` / `backups` を除外している（いずれも階層を問わずマッチする）。playit.gg の `SECRET_KEY`、R2 のアクセスキー、Grafana Cloud の API キーなど実際のシークレットはコミットしないこと。
