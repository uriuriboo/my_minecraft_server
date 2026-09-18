# PaperMC on Raspberry Pi 5 - 初期構築手順

## 前提環境

- Raspberry Pi 5 16GBモデル (Raspberry Pi OS 64bit)
- Docker / Docker Compose
- playit.gg アカウント（無料プラン）

## 1. Docker環境の準備

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
sudo apt install -y docker-compose-plugin
```

上記実行後、一度ログアウト→再ログインしてグループ権限を反映させる。

## 2. playit.gg エージェント登録

1. <https://playit.gg> でアカウント作成
2. ダッシュボードの **Agents** ページで新規 Docker Agent を作成
3. 表示される `SECRET_KEY` を控える（**再表示不可のため必ず保存**）

参考: Freeプランは 2 agents / 4 ports まで。1台構成なら十分。

## 3. リポジトリの配置

```bash
git clone <このリポジトリ> ~/papermc
```

compose はリポジトリルートではなく `docker/` 配下に構成別に置いてある。
どちらを使うかは [docker/README.md](../docker/README.md) の比較表を見て決める。

```bash
cd ~/papermc/docker/all_self_host/server   # すべてセルフホストで監視する場合
cd ~/papermc/docker/cloud                  # Grafana Cloud を使う場合
```

以降はこのディレクトリで作業する。

## 4. .env作成

```bash
cp .env_sample .env
```

最低限、次の3つを埋める。

- `PLAYIT_SECRET_KEY` — 手順2で控えたシークレットキー
- `RCON_PASSWORD` — 任意の文字列。バックアップコンテナが rcon で繋ぐのに使う
- `R2_*` — Cloudflare R2 へバックアップを送る場合（後回しでも可）

`.env` は `.gitignore` で除外済み。`docker compose` は **compose.yml と同じディレクトリの `.env`**
しか自動で読まないため、必ずこの階層に置く。

ワールドデータの置き場所（`MC_DATA_DIR`）は、リポジトリ外・できれば SSD を推奨している。
理由は [docs/operations.md](operations.md) の「ワールドデータの配置場所」を参照。

## 5. 起動

```bash
docker compose up -d
docker compose logs -f papermc   # "Done" 表示を確認
docker compose logs -f playit    # "Connected" 表示を確認
```

各サービスの内容と構成ごとの違いは [docker/README.md](../docker/README.md) を参照。

## 6. playit.gg トンネル作成

1. ダッシュボードの **Tunnels** ページで「Add Tunnel」
2. Tunnel Type: `Minecraft Java`
3. Local IP: `127.0.0.1`（繋がらない場合は `172.17.0.1`）
4. Local Port: `25565`
5. 発行されたアドレス（例: `xx-xx.craft.playit.gg`）を確認

注: このアドレスは基本固定（ランダムだが変わらない）。トンネルやエージェントを作り直さない限り維持される。

## 7. 動作確認

- 自分のスマホをモバイル通信に切り替え、発行アドレスに接続してテスト
- 家庭内LAN特有の挙動と切り分けるため、Wi-Fi接続では確認しない

## 8. 友人への共有

発行アドレスをそのままMinecraftの「サーバーを追加」画面に入力してもらう（ポート番号の指定不要）。

## 9. バックアップの設定

R2 への定期バックアップは [docs/operations.md](operations.md) の「バックアップ」を参照。
`docker compose run --rm backup` で1回だけ実行できるので、cron に入れる前に手で動かして確認する。

## 参考: 各サービスの役割

| コンポーネント | 役割 |
| --- | --- |
| itzg/minecraft-server | Paperサーバー本体のDockerイメージ。TYPE/VERSION等の環境変数でPaper自動セットアップ |
| playit-agent | ローカルの25565をplayit.gg経由で外部公開するトンネルクライアント。CGNAT配下でもポート開放不要 |
| mc-router | 25565の受け口。playit からの接続を papermc に中継しつつ、接続数メトリクスとレート制限を提供 |
| itzg/mc-backup | 呼んだときだけ起動し、save-off → tar → R2 転送 → save-on を行うバックアップジョブ |
| RCON (itzgイメージ標準搭載) | コンテナ内から `rcon-cli` でサーバーコマンドを実行するための仕組み。外部公開は非推奨 |
