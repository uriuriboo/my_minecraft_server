# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## このリポジトリについて

アプリケーションコードは無く、自宅の Raspberry Pi 5 上で稼働させている個人用 PaperMC (Minecraft) サーバーの構築・運用手順とDocker構成を管理するリポジトリ。ビルド/lint/テストの概念は無い。

構成要素:

- `docker-compose.yml` — 実際に使用している compose 定義。`papermc` (itzg/minecraft-server, TYPE=PAPER) と `playit` (playit.gg トンネルエージェント) の2サービス。
- `docs/setup.md` — 初期構築手順（Docker導入〜playit.ggトンネル作成〜起動確認）。中の compose 例は掲載時点のスナップショットなので、内容が食い違った場合は `docker-compose.yml` の方を信頼する。
- `docs/operations.md` — 日常運用手順（プレイヤー確認・TPS確認・停止再起動・バックアップ/復元・プラグイン更新・トラブルシューティング）。
- `README.md` — 一行概要のみ。

## よく使うコマンド

すべて Raspberry Pi 側（サーバー実機）で実行する前提（`~/papermc` 直下、`docker-compose.yml` と同階層）。

```bash
# 起動・停止・再起動（正常終了のため必ず stop/start/restart を使う）
docker compose up -d
docker compose stop papermc
docker compose start papermc
docker compose restart papermc

# ログ確認
docker compose logs -f papermc --tail 100
docker compose logs -f playit

# サーバー内コマンド（rcon-cli経由）
docker exec papermc rcon-cli list
docker exec papermc rcon-cli tps
docker exec papermc rcon-cli say "メッセージ"
docker exec papermc rcon-cli save-all

# Paperの更新
docker compose pull papermc
docker compose up -d papermc
```

バックアップ／復元の具体的な手順（`save-off`→`save-all`→tar→`save-on`、cron登録、復元時のディレクトリ削除→展開）は [docs/operations.md](docs/operations.md) を参照。ワールドデータに触る変更を提案する際は必ずこの手順を踏襲すること。

## 重要な運用上の制約（ドキュメントに明記されている禁止事項・注意点）

- **`docker kill` や電源off直接切断は禁止** — ワールド破損リスクがあるため、必ず `docker compose stop`（SIGTERM経由）を使う。
- **プラグイン更新はサーバー停止中のみ** — 稼働中の `data/plugins` 書き換えはクラスロード不整合でクラッシュの可能性がある。
- **メジャーバージョンアップ（例: 1.21→1.22）前は必ずバックアップ** — ワールドの互換性は前方のみ（新→旧には戻せない）。
- **SEEDは初回ワールド生成時のみ有効** — 既存の `data/world` がある状態でSEEDを変えても無視される。ワールドの継続性は「正常停止」「`./data` ボリュームの保全」「定期バックアップ」の3点で守られる。
- **RCONは平文プロトコルのため外部公開しない** — Discord Bot等から操作したい場合はVPN（WireGuard等）やCloudflare Tunnel経由のプライベートアクセスを前提に構成する。
- 外部公開手段としてplayit.ggを採用している理由は「フレンド側の追加インストールが不要」なため（Cloudflare Tunnelは接続先にもcloudflaredが必要になり不採用）。

## Git管理状態の注意

現時点でgitに追跡されているのは `README.md` のみで、`docs/setup.md` / `docs/operations.md` / `docker-compose.yml` / `.gitignore` / `.env` は未追跡（untracked）。`.gitignore` は `.env` のみを除外対象にしている。playit.gg の `SECRET_KEY` など実際のシークレットはコミットしないこと。
