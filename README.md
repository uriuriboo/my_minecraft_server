# my_minecraft_server

宅鯖用MC設定 — Raspberry Pi 5 上で動かす個人用 PaperMC サーバーの構築・運用ドキュメント。

## 概要

- サーバー本体: [itzg/minecraft-server](https://github.com/itzg/docker-minecraft-server)（`TYPE=PAPER`）をDocker Composeで起動
- 外部公開: [playit.gg](https://playit.gg) のトンネルエージェントを併用し、ポート開放不要でフレンドに接続してもらう
- 運用は `docker compose` と `rcon-cli` のみで行い、専用のビルド・アプリケーションコードは無い

## 構成

| コンポーネント | 役割 |
| --- | --- |
| itzg/minecraft-server | Paperサーバー本体。`TYPE`/`VERSION`等の環境変数でセットアップ |
| playit-agent | ローカルの25565をplayit.gg経由で外部公開するトンネルクライアント |
| RCON（itzgイメージ標準搭載） | `rcon-cli`でコンテナ内からサーバーコマンドを実行する仕組み |

## ドキュメント

- 初期構築手順: [docs/setup.md](docs/setup.md)
- 日常運用（起動停止・バックアップ・トラブルシューティング等）: [docs/operations.md](docs/operations.md)

## クイックスタート

```bash
docker compose up -d
docker compose logs -f papermc   # "Done" 表示を確認
docker compose logs -f playit    # "Connected" 表示を確認
```

詳細な初期セットアップ（Docker導入、playit.ggのエージェント登録、トンネル作成）は [docs/setup.md](docs/setup.md) を参照。
