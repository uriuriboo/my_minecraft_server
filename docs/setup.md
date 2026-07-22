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

## 3. ディレクトリ作成

```bash
mkdir -p ~/papermc && cd ~/papermc
mkdir -p ~/backups
```

## 4. .env作成

```bash
echo "PLAYIT_SECRET_KEY=手順2で控えたシークレットキー" > .env
```

`.env`は`.gitignore`で除外済み。`docker-compose.yml`と同じディレクトリに置けば`docker compose`が自動で読み込む。

## 5. docker-compose.yml

```yaml
services:
  papermc:
    image: itzg/minecraft-server:latest
    container_name: papermc
    ports:
      - "25565:25565"
    environment:
      EULA: "true"
      TYPE: "PAPER"
      VERSION: "1.21.11"
      MEMORY: "10G"                # 16GBモデル前提。OS/Docker/playit-agent用に4〜6G残す
      USE_AIKAR_FLAGS: "true"
      TZ: "Asia/Tokyo"
      WHITELIST: ""                # 例: "user1,user2"
      ENFORCE_WHITELIST: "true"
      MAX_PLAYERS: "10"
      VIEW_DISTANCE: "8"
      SIMULATION_DISTANCE: "6"
      # SEED: ""                   # 初回ワールド生成時のみ有効
    volumes:
      - ./data:/data
    restart: unless-stopped
    stdin_open: true
    tty: true

  playit:
    image: ghcr.io/playit-cloud/playit-agent:0.17
    container_name: playit
    network_mode: host
    environment:
      SECRET_KEY: ${PLAYIT_SECRET_KEY}
    restart: unless-stopped
```

## 6. 起動

```bash
docker compose up -d
docker compose logs -f papermc   # "Done" 表示を確認
docker compose logs -f playit    # "Connected" 表示を確認
```

## 7. playit.gg トンネル作成

1. ダッシュボードの **Tunnels** ページで「Add Tunnel」
2. Tunnel Type: `Minecraft Java`
3. Local IP: `127.0.0.1`（繋がらない場合は `172.17.0.1`）
4. Local Port: `25565`
5. 発行されたアドレス（例: `xx-xx.craft.playit.gg`）を確認

注: このアドレスは基本固定（ランダムだが変わらない）。トンネルやエージェントを作り直さない限り維持される。

## 8. 動作確認

- 自分のスマホをモバイル通信に切り替え、発行アドレスに接続してテスト
- 家庭内LAN特有の挙動と切り分けるため、Wi-Fi接続では確認しない

## 9. 友人への共有

発行アドレスをそのままMinecraftの「サーバーを追加」画面に入力してもらう（ポート番号の指定不要）。

## 参考: 各サービスの役割

| コンポーネント | 役割 |
| --- | --- |
| itzg/minecraft-server | Paperサーバー本体のDockerイメージ。TYPE/VERSION等の環境変数でPaper自動セットアップ |
| playit-agent | ローカルの25565をplayit.gg経由で外部公開するトンネルクライアント。CGNAT配下でもポート開放不要 |
| RCON (itzgイメージ標準搭載) | コンテナ内から `rcon-cli` でサーバーコマンドを実行するための仕組み。外部公開は非推奨 |
