# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

BigQuery ML の `AI.FORECAST` (TimesFM) を使った小売需要予測のデモ。実装は Makefile + 素の SQL のみで、アプリケーションコードやビルド成果物は存在しない。

## テンプレート機構 (最重要)

`sql/*.sql` は **そのままでは実行できない**。`@PROJECT_ID@` `@DATASET@` `@ITEM_NAME@` `@HORIZON@` などのプレースホルダを含んでおり、Makefile の `RENDER` 変数 (sed パイプライン) が置換した結果を `bq query` に標準入力で流し込む。

```
sql/10_forecast.sql --[ RENDER = sed -e 's|@FOO@|value|g' ]--> bq query --use_legacy_sql=false
```

したがって:
- SQL ファイルを直接 `bq query < sql/xx.sql` してはいけない。必ず make ターゲット経由か `make print-sql` を通す
- 新しい設定値を足すときは **Makefile の変数定義と `RENDER` の `-e` 行の両方** を更新する
- SQL 側でリテラルの `@` を使うと sed に巻き込まれる可能性がある

## コマンド

```bash
make help                          # ターゲット一覧 (デフォルトゴール)
make config                        # 現在の変数値を確認
make check                         # gcloud/bq の有無・ADC・PROJECT_ID を検証

make setup                         # dataset + seed + show-data
make forecast                      # 本題: AI.FORECAST を実行
make order-plan                    # 予測値 → 発注ケース数
make demo                          # setup → forecast → order-plan

make clean                         # データセットごと削除 (確認プロンプトあり)
make clean FORCE=1                 # 確認なしで削除 (破壊的)
```

設定は環境変数か make 引数で上書きする: `make forecast HORIZON=14 ITEM_NAME=絹ごし豆腐`。全変数は README の表を参照。

### 検証 (ユニットテストは存在しない)

テストフレームワークはない。代わりに以下の 2 つを使う。

```bash
make dry-run                       # 全 SQL の構文チェック。クエリ実行なし = 課金なし
make forecast DRY_RUN=1            # 単一ターゲットだけ構文チェック
make print-sql FILE=sql/10_forecast.sql   # 置換後の SQL を目視確認 (BigQuery に接続しない)
make evaluate                      # AI.EVALUATE によるバックテスト (精度の回帰確認)
```

SQL を編集したら最低限 `make dry-run` を通すこと。`make print-sql` は置換結果だけ見たいとき (認証不要) に使える。

## アーキテクチャ

### モデル学習が存在しない

TimesFM はゼロショット基盤モデルなので `CREATE MODEL` を行わない。学習済みモデルという成果物がなく、**クエリのたびに `AI.FORECAST` が推論する**。

この帰結として、`AI.FORECAST(...)` の呼び出しブロックが **4 ファイルに重複している** (`10_forecast` / `11_forecast_save` / `12_order_plan` / `14_forecast_with_history`)。予測パラメータのロジックを変更する場合は 4 箇所すべてを直す必要がある。共通化されていないのは、各 SQL 単体を読んで理解できるようにするデモ上の意図。

### データフロー

```
01_seed_daily_sales      → daily_sales (3店舗 × 3商品 × HISTORY_DAYS 日)
02_seed_inventory_promotions → current_inventory, promotions
                                        │
daily_sales ──WHERE item_name──> AI.FORECAST ──> forecast_value / 予測区間
                                        │
                    promotions + current_inventory と JOIN
                                        ▼
                              12_order_plan → 発注ケース数
```

ファイル番号は実行順序の階層を表す: `0x` = セットアップ、`1x` = 予測とその応用。

### 発注ロジック (`sql/12_order_plan.sql`)

需要予測そのものより、このファイルが業務ロジックの中心。

- **通常日は `forecast_value` (中央値)、特売日のみ `prediction_interval_upper_bound` (上限値)** を必要数量とする。納豆は賞味期限が短く、上限値を常用すると廃棄ロスになるため特売日に限定している
- 現在庫はウィンドウ関数 `SUM(...) OVER (... ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)` で古い日付から順に消化させる
- 最後に `CASE_LOT` 単位で切り上げる

このバランスを変えるときは `needed_qty` の定義を書き換える。

## 注意点

### Makefile の変数定義

`VAR ?= value  # comment` と書くと **末尾の空白までが値に含まれる**。コメントは必ず変数定義とは別の行に置く (Makefile 冒頭にも同じ注意書きあり)。

`setup` / `demo` は順序に意味があるため `.NOTPARALLEL:` で `make -j` を無効化している。

### PROJECT_ID の解決順

`PROJECT_ID ?= $(shell gcloud config get-value project)` のため、**シェルに `PROJECT_ID` 環境変数があるとそちらが優先され、`gcloud config` の値より強い**。意図しないプロジェクトに対して課金・テーブル作成が走らないよう `make config` で確認する。

### シードデータは CURRENT_DATE 相対

`daily_sales` は「昨日」で終わるため、予測期間は `CURRENT_DATE` 〜 `CURRENT_DATE + HORIZON - 1` になる。`promotions` の特売日は `CURRENT_DATE + 2 日` (S01/S02) と `+5 日` (S03) にハードコードされているので、**`HORIZON` が 6 未満だと S03 の特売日が予測期間から外れ、`order-plan` の特売分岐が動かなくなる** (S01/S02 は `HORIZON >= 3` で足りる)。デフォルトの `HORIZON=7` は両方を含む前提の値。

### `output_historical_time_series => TRUE` で列名が変わる

`14_forecast_with_history.sql` のみこのモードを使う。`forecast_timestamp` / `forecast_value` ではなく `time_series_type` / `time_series_timestamp` / `time_series_data` が返る。他の SQL からコピペするとここで壊れる。

### .gitignore

`*.csv` / `*.json` を除外している。`make forecast FORMAT=csv > forecast.csv` のようにクエリ結果をリポジトリ内へリダイレクトする使い方を想定しているため。`.claude/settings.local.json` だけ `!` で除外解除して追跡している。
