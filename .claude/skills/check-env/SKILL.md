---
name: check-env
description: 実機（Raspberry Pi / Grafana 用の別PC）に接続した状態で、その機器の .env が使っている compose に対して正しいかを実測して検証する。「Piに繋いだ」「専用機器に接続した」「.env これで合ってる？」「環境変数チェックして」などの合図で使う。サーバー側は自分の実在アドレスと、Grafana クライアント側はサーバー機器の名前解決結果と突き合わせ、マスクした判定表と修正案を出す。Verify .env against the compose file on the actual machine.
---

# .env 検証（実機）

対象機器の**実値を測って** `.env` と突き合わせる。測れていないものを「たぶん合っている」で OK にしない。判定は `OK` / `NG` / `未検証` の3つだけ。

## 0. 最初に: どの compose を使うか確認する（省略不可）

compose は3つあり、Pi 側の2つ（`server` / `cloud`）は container_name とポートが衝突するので**排他**。どれを見るかで正しい変数セットが変わるため、必ず最初にユーザーに確認する（AskUserQuestion）。

| 選択 | 実行場所 | ディレクトリ |
| --- | --- | --- |
| all_self_hostのサーバー側 | Raspberry Pi | `docker/all_self_host/server` |
| all_self_hostのクライアント側 | 別PC（Grafana） | `docker/all_self_host/client` |
| サーバーとクラウド利用 | Raspberry Pi | `docker/cloud` |

検出結果は「候補」として選択肢の先頭に置くだけで、確認そのものを飛ばさない。検出のヒント（対象機器上で実行）:

```bash
docker compose ls
docker ps --format '{{.Names}}'
```

- `victoriametrics` / `loki` / `promtail` がいる → `all_self_host/server`
- `alloy` がいる → `cloud`
- `grafana` だけ → `all_self_host/client`

Pi 上で `victoriametrics` と `alloy` が同時にいる、または両方のディレクトリに `.env` がある場合は排他違反なのでその場で報告する。

### 同じ確認でまとめて聞くこと

**分からないことは遠慮なく聞く**（推測で埋めない）。ただし後から小刻みに聞かず、この最初の確認に相乗りさせて1回で済ませる。まず `hostname -s; id -un` を自分（Claude Code のシェル）で実行し、その結果を「これがサーバーですか？」の確認材料としてユーザーに見せた上で、必ず次を確認する。自己判定だけで決めない（別PCから ssh 済みでローカルホスト名がPiのものに見えるケースもある）。

同一LAN内で完結する構成のため、以降の名前解決・ssh 接続はすべて**ホスト名 + ユーザー名**で行い、IPアドレスの確認は要求しない（IPは §3 のサーバー側 `LAN_BIND_IP` / `MC_BIND_IP` の検証でのみ実測する）。

- どの compose を使っているか（上の3択）
- **今 Claude Code が動いている機器そのものがサーバー（Pi）かどうか** — Yes ならホスト名・ユーザー名は上の実行結果をそのまま使ってよいか確認するだけでよい。No（別PCやクライアント機からの操作）なら次の2つを必ず聞く
- **サーバー機器（Pi）のホスト名** — §4 の名前解決の起点になる。自己判定では埋めない
- **サーバーに入るためのユーザー名** — ssh 接続文字列 `<user>@<host>` を組み立てるのに必要。自己判定では埋めない

## 1. チェックを実行する場所を確定する

`.env` は `.gitignore` 済みでリポジトリには無い。**対象機器の上でしか検証できない。**

```bash
hostname -s; uname -srm; id -un
```

- Claude Code のシェルが既に対象機器上 → そのまま実行する
- 別マシン（例: Windows の開発機から Pi を見ている）→ 以降のコマンドを `ssh <user>@<host> '<cmd>'` 経由で実行する。接続先は §0 で聞いたホスト名を使う
- Grafana クライアントが Windows の場合は §4 の PowerShell 版を使う

## 2. 変数の一覧は compose.yml を正とする

下の表は補助。実体は compose ファイル。食い違ったら compose を正として表を直す（`docs/setup.md` に compose の中身を転記しない方針と同じ理由）。

```bash
cd <選んだディレクトリ>
grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*(:[-?][^}]*)?\}' compose.yml | sort -u   # 参照している変数と既定値
grep -oE '^[A-Za-z_][A-Za-z0-9_]*' .env | sort -u                            # 実際に設定されている変数
docker compose --profile backup config > /dev/null && echo CONFIG_OK         # :? 付き必須変数の欠落はここで落ちる
```

- `config` が落ちたら、エラーに出ている変数が未設定。これは即 `NG`
- `config` の標準出力には**シークレットが展開されて出る**。`> /dev/null` を付け、中身を貼り付けない
- `.env` にあるのに compose が参照していない変数は効いていない。綴り間違いを疑って報告する

### 値の扱い（厳守）

- 値をそのままチャットに出さない。`PLAYIT_SECRET_KEY` / `RCON_PASSWORD` / `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` / `GRAFANA_CLOUD_API_KEY` / `GF_ADMIN_PASSWORD` は「設定あり（32文字）」「未設定」「サンプルのまま」だけを報告する
- 「サンプルのまま」の判定: 値が `...` / `change-me` そのもの、`<` `>` を含む、`xxx` を含む
- アドレスやバケット名は内容を出してよい（判断に必要）

## 3. サーバー側（server / cloud）: 自分のアドレスと突き合わせる

```bash
ip -4 -o addr show scope global | awk '{print $2, $4}'                  # 実在するアドレス一覧
ip -4 route get 1.1.1.1 | sed -n 's/.*src \([0-9.]*\).*/\1/p'           # 既定経路の送信元 = 主 LAN アドレス
ip -4 -o addr show dev wg0 2>/dev/null                                  # VPN 経由で見る場合
hostname -s; hostname -f
ss -ltn | grep -E ':(25565|8428|3100)'                                  # 今どのアドレスで待っているか
```

### LAN_BIND_IP（server のみ）

- 入れる値は**この機器に実在するアドレス**。`ip -4 -o addr` の一覧に無ければ `NG`（VictoriaMetrics / Loki がポートバインドに失敗して起動しない）。`.env_sample` の例 `192.168.1.50` がそのまま残っている事故が最も多い
- `127.0.0.1`（未設定時の既定）は別PCの Grafana から繋がらない。クライアント構成を併用しているなら `NG`
- RFC1918 でも VPN でもないグローバルアドレスは `NG`。8428 / 3100 は**無認証**なので LAN か VPN の内側だけに bind する
- ホスト名: ここは docker の publish アドレスなので**IP を入れる**。名前解決の結果が変わると bind 先も変わる。どうしても名前で書く場合は、`docker compose up -d` 後に `ss -ltn` で 8428 / 3100 が意図したアドレスで待っていることを実測するまで `OK` にしない

### MC_BIND_IP（server / cloud）

- 実質 `127.0.0.1`（既定。playit 経由のみ）か `0.0.0.0`（LAN からも直結）の2値だけ
- **特定の LAN アドレスは `NG`** — playit は `network_mode: host` で Pi 自身の `127.0.0.1` から mc-router に繋ぐため、そのアドレスでしか待たなくなると playit 経由の接続が切れる。ホスト名も同じ理由で使わない

### MC_DATA_DIR / BACKUP_DIR

解決後の実パスは、動いているコンテナから取るのが確実（シークレットも出ない）:

```bash
docker inspect papermc --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}'
ls -d "<解決したパス>/world" "<解決したパス>/world/dimensions/minecraft"/*
stat -c '%U:%G %a' "<解決したパス>"
df -h "<解決したパス>"
```

- 相対パスの基準は compose.yml のあるディレクトリ。既定値は server が `../../../data`、cloud が `../../data` で**階層が違う**。取り違えない
- 存在しないパスを書くと docker が空ディレクトリを作り、**別のワールドが新規生成される**。`world/` の有無を必ず見る
- 正は `world/dimensions/minecraft/{overworld,the_nether,the_end}`。`world_nether` / `world_the_end` があれば旧レイアウトなので報告する
- 既存ワールドを切り離す変更（名前付きボリューム化など）は提案しない。移設は `docs/operations.md` の手順に従う
- `BACKUP_DIR` は tar の一時置き場。転送後にローカルは消えるので溜まっていなくて正常。書き込み可能と空き容量だけ見る

### その他（server / cloud 共通）

- `RCON_PASSWORD` — 空 / `...` は `NG`。変更したら `docker compose up -d papermc` でコンテナ再作成が必要（`restart` では入らない）と添える
- `PLAYIT_SECRET_KEY` — 空 / `...` は `NG`。実測は `docker compose logs playit --tail 20` の `Connected`
- `RETENTION_DAYS` — 整数のみ
- `AUTO_SCALE` — `true` / `false` のみ（`1` / `yes` は不可）。`AUTO_SCALE_DOWN_AFTER` — `30m` / `1h` 形式
- `R2_ENDPOINT` — `https://<アカウントID>.r2.cloudflarestorage.com`。`<` `>` が残っていたらプレースホルダのまま
- `R2_BUCKET` / `R2_PREFIX` / R2 の鍵 — 実際の疎通は `docker compose run --rm backup` でしか分からない。これは `save-off` からワールドに触るので**勝手に走らせない**。必要ならユーザーに確認して実行し、未実行なら `未検証` と書く
- papermc が停止している（scale to zero 中）と `docker inspect` や rcon が空振りする。停止中であることを報告し、起動は勝手にしない

### cloud 構成のみ

`GRAFANA_CLOUD_*` は compose で `:?` が付いていない。**未設定でも `docker compose config` は通り、Alloy が黙って失敗する**ので、ここは必ず中身を見る。参照元は `config.alloy` の `env(...)`。

- `GRAFANA_CLOUD_PROM_URL` — `https://` 始まり `/api/prom/push` 終わり
- `GRAFANA_CLOUD_LOKI_URL` — `https://` 始まり `/loki/api/v1/push` 終わり
- `GRAFANA_CLOUD_PROM_USER` / `GRAFANA_CLOUD_LOKI_USER` — 数値のインスタンスID。**2つは別の値**。同一なら貼り間違いを疑う
- `GRAFANA_CLOUD_API_KEY` — `glc_` 始まり。Prom と Loki で共用
- 実測: `docker compose logs alloy --tail 50` に `401` / `403` / `error sending` が出ていないか

## 4. Grafana クライアント側: サーバー機器の名前から解決する

`MC_SERVER_HOST` は Pi のアドレス。行き先は Grafana のデータソース URL（`http://$MC_SERVER_HOST:8428` と `:3100`、`access: proxy`）なので、**ホスト名でもよい**。ただし解決するのは Grafana **コンテナの中**なので、そこで引けることを実測するまで `OK` にしない。

### 1) PC の名前から IP を引く（このPC上）

Linux / macOS:

```bash
getent hosts <pi-hostname>            # 例: raspberrypi / pi.lan
avahi-resolve -n <pi-hostname>.local  # mDNS の場合
```

Windows (PowerShell):

```powershell
Resolve-DnsName <pi-hostname> -Type A
ping -4 -n 1 <pi-hostname>
```

引けた IP が Pi 側 `.env` の `LAN_BIND_IP` と一致していること。ズレていれば `MC_SERVER_HOST` の綴りではなく DNS / DHCP 側の問題なので、そう報告する（Pi は固定IP か DHCP 予約が前提）。

### 2) このPCから到達するか

```bash
curl -fsS http://<host>:8428/health   # VictoriaMetrics → OK
curl -fsS http://<host>:3100/ready    # Loki → ready
```

```powershell
Test-NetConnection <host> -Port 8428
Test-NetConnection <host> -Port 3100
```

落ちたときの切り分け順: Pi 側のコンテナが起動しているか → `LAN_BIND_IP` が `127.0.0.1` のままでないか → 経路（VPN / セグメント / ファイアウォール）。

### 3) コンテナ内から引けるか（ホスト名を使うなら必須）

```bash
docker exec grafana getent hosts <host>
docker exec grafana wget -qO- http://<host>:8428/health
```

- 引けない典型は `*.local`。Grafana コンテナに mDNS の名前解決は入っておらず、ホストの `/etc/hosts` もコンテナには継承されない（DNS サーバーの設定は継承される）
- 対処は2つ。`MC_SERVER_HOST` を IP にする / compose の grafana に `extra_hosts: ["<host>:<ip>"]` を足す。どちらを取るかはユーザーに選ばせる
- Grafana が未起動でこの確認ができない場合は `未検証` と報告する。起動は勝手にしない

### その他（client）

- `MC_SERVER_HOST` に `127.0.0.1` / `localhost` は `NG`（コンテナ内の localhost は Grafana 自身）
- `GRAFANA_BIND_IP` — `127.0.0.1`（このPCだけ）か `0.0.0.0`（他からも開く）。Grafana は認証があるので `0.0.0.0` も可だが、パスワードがサンプルのままなら `NG`
- `GF_ADMIN_PASSWORD` — 空 / `change-me` は `NG`。既存の `grafana-data` ボリュームがある状態で書き換えても反映されないことがあるので、実際に新パスワードでログインできるか確かめるまで `OK` にしない
- `./provisioning` と `./dashboards` がクライアントディレクトリに実在すること（無いと docker が root 所有の空ディレクトリを作り、データソースが自動登録されない）

## 5. 報告のしかた

表で出す。列は **変数 / 現在値（マスク済み） / 判定 / 根拠（実測コマンドと結果） / 直し方**。根拠の無い行を `OK` にしない。

修正は**提案までを既定**にする。`.env` はシークレットを含む実機の設定ファイルなので、書き換える前にユーザーに確認する。書き換えたら必要な操作を明示する:

- `LAN_BIND_IP` / `MC_BIND_IP` / `RCON_PASSWORD` / `MC_DATA_DIR` / `MC_SERVER_HOST` / `GRAFANA_CLOUD_*` → `docker compose up -d`（**コンテナ再作成が必要。`restart` では反映されない**）
- papermc が動いているなら、再作成のタイミングをユーザーに確認する。`docker kill` や電源直切りは使わない（ワールド破損）
- `.env` はコミットしない。差分を git に載せる話には乗らない

このスキルでやらないこと（必要と分かったら提案し、承認を得てから）:

- compose ファイルの書き換え（`extra_hosts` の追加など）
- `docker compose run --rm backup` の実行、ワールドデータの移動、稼働中サーバーの停止・再起動
