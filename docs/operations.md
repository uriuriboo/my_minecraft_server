# PaperMC on Raspberry Pi 5 - 運用手順

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

⚠️ **禁止事項**

- `docker kill` の使用（ワールド破損リスク）
- 電源を直接切る（同上）

## アップデート手順

```bash
cd ~/papermc
docker compose pull papermc
docker compose up -d papermc
```

- `VERSION` を空文字にしている場合、再作成のたびに最新Paperビルドを自動解決
- 特定バージョンに固定している場合は `docker-compose.yml` の `VERSION` を書き換えてから実行
- **メジャーバージョンアップ前（例: 1.21→1.22）は必ずバックアップを取る**（ワールド互換性は前方のみ）

## バックアップ

### スクリプト（`~/papermc/backup.sh`）

```bash
#!/bin/bash
cd ~/papermc
docker exec papermc rcon-cli save-off
docker exec papermc rcon-cli save-all
sleep 5
tar czf /home/pi/backups/world_$(date +%F_%H%M).tar.gz -C data world world_nether world_the_end
docker exec papermc rcon-cli save-on

# 7日以上前のバックアップを削除
find /home/pi/backups -name "world_*.tar.gz" -mtime +7 -delete
```

```bash
chmod +x ~/papermc/backup.sh
```

### cron登録（毎日3時実行）

```bash
crontab -e
# 以下を追加
0 3 * * * /home/pi/papermc/backup.sh
```

### 復元手順

```bash
docker compose stop papermc
cd ~/papermc
rm -rf data/world data/world_nether data/world_the_end
tar xzf /home/pi/backups/world_YYYY-MM-DD_HHMM.tar.gz -C data
docker compose start papermc
```

## プラグイン更新

- 配置場所: `data/plugins`
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
| 友人が接続できない | `docker compose logs -f playit` でエージェントの接続状態確認 |
| ラグがひどい | `rcon-cli tps` でTPS確認、`VIEW_DISTANCE`調整 |
| ワールドが読み込まれない/壊れた | `data/world` フォルダの存在確認、バックアップから復元 |
| アップデート後起動しない | `docker compose logs papermc` でエラー内容確認、バージョン間の非互換プラグインがないか確認 |

## FAQ（よくある誤解）

- **Q. シードを設定すればワールドが途切れない？**
  A. いいえ。シードは初回生成時のみ有効な設定で、ワールドの継続性とは無関係。継続性を守るのは「正常停止」「`./data`ボリュームの保全」「定期バックアップ」の3点。

- **Q. Cloudflare Tunnelではダメ？**
  A. 友人側にもcloudflaredのインストールが必要になるため、不特定多数への公開には不向き。playit.ggはクライアント側の準備が不要なため採用。

- **Q. RCONを外部公開してDiscord Bot等から操作したい**
  A. RCONは平文プロトコルのため直接の外部公開は非推奨。VPN（WireGuard等）やCloudflare Tunnel経由でプライベートにアクセスする構成を推奨。
