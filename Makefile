# ============================================================
# BigQuery ML AI.FORECAST (TimesFM) — 小売店の納豆需要予測デモ
#
# 使い方:
#   make setup       … データセット + サンプルデータを用意
#   make forecast    … 需要予測を実行
#   make order-plan  … 発注量を算出
#   make help        … 全ターゲット一覧
# ============================================================

# -------------------------------------------------------
# 設定 (環境変数 or make 実行時に上書き可)
#   例: make forecast HORIZON=14 ITEM_NAME=絹ごし豆腐
# -------------------------------------------------------
#
# 注意: `VAR ?= value  # comment` と書くと末尾の空白まで値に含まれてしまうため、
#       コメントは必ず行を分ける。
#
PROJECT_ID       ?= $(shell gcloud config get-value project 2>/dev/null)
DATASET          ?= retail_demand
LOCATION         ?= asia-northeast1
TIMEZONE         ?= Asia/Tokyo

# 予測対象の商品名
ITEM_NAME        ?= みんなの納豆
# 使用するモデル (TimesFM 2.5 / TimesFM 2.0)
MODEL            ?= TimesFM 2.5
# 何日先まで予測するか [1, 10000]
HORIZON          ?= 7
# バックテスト (make evaluate) で答え合わせに使う日数。
# HORIZON とは独立。短すぎると指標が数点のノイズで振れるため既定は 4 週間。
EVAL_HORIZON     ?= 28
# 予測区間の信頼度 [0, 1)
CONFIDENCE_LEVEL ?= 0.95
# サンプルデータの過去日数
HISTORY_DAYS     ?= 180
# 発注ケース入数 (個/ケース)
CASE_LOT         ?= 10

# 出力形式 (pretty / csv / json / prettyjson)
FORMAT           ?= pretty
# 1 を指定すると構文チェックのみ (課金なし)
DRY_RUN          ?=

SQL_DIR          := sql

# -------------------------------------------------------
# 内部変数
# -------------------------------------------------------
ifeq ($(DRY_RUN),1)
  DRY_RUN_FLAG := --dry_run
else
  DRY_RUN_FLAG :=
endif

BQ_QUERY = bq --project_id=$(PROJECT_ID) --location=$(LOCATION) --format=$(FORMAT) \
	query --use_legacy_sql=false $(DRY_RUN_FLAG)

# SQL 内のプレースホルダを設定値に置換する
RENDER = sed \
	-e 's|@PROJECT_ID@|$(PROJECT_ID)|g' \
	-e 's|@DATASET@|$(DATASET)|g' \
	-e 's|@TIMEZONE@|$(TIMEZONE)|g' \
	-e 's|@ITEM_NAME@|$(ITEM_NAME)|g' \
	-e 's|@MODEL@|$(MODEL)|g' \
	-e 's|@HORIZON@|$(HORIZON)|g' \
	-e 's|@EVAL_HORIZON@|$(EVAL_HORIZON)|g' \
	-e 's|@CONFIDENCE_LEVEL@|$(CONFIDENCE_LEVEL)|g' \
	-e 's|@HISTORY_DAYS@|$(HISTORY_DAYS)|g' \
	-e 's|@CASE_LOT@|$(CASE_LOT)|g'

.DEFAULT_GOAL := help

# setup / demo は「データセット作成 → 投入 → 予測」の順序に意味があるため、
# make -j で並列実行されないようにする。
.NOTPARALLEL:

.PHONY: help check config enable-apis dataset seed setup show-data \
        forecast order-plan evaluate history save demo dry-run print-sql clean

# -------------------------------------------------------
# ヘルプ / 設定確認
# -------------------------------------------------------
help: ## このヘルプを表示
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  設定を上書きする例:"
	@echo "    make forecast HORIZON=14"
	@echo "    make forecast ITEM_NAME=絹ごし豆腐"
	@echo "    make forecast FORMAT=csv > forecast.csv"
	@echo "    make forecast DRY_RUN=1        # 課金なしの構文チェック"

config: ## 現在の設定値を表示
	@echo "PROJECT_ID       = $(PROJECT_ID)"
	@echo "DATASET          = $(DATASET)"
	@echo "LOCATION         = $(LOCATION)"
	@echo "ITEM_NAME        = $(ITEM_NAME)"
	@echo "MODEL            = $(MODEL)"
	@echo "HORIZON          = $(HORIZON)"
	@echo "EVAL_HORIZON     = $(EVAL_HORIZON)"
	@echo "CONFIDENCE_LEVEL = $(CONFIDENCE_LEVEL)"
	@echo "HISTORY_DAYS     = $(HISTORY_DAYS)"
	@echo "CASE_LOT         = $(CASE_LOT)"

check: ## 前提条件 (CLI / 認証 / プロジェクト) を確認
	@command -v gcloud >/dev/null || { echo "ERROR: gcloud が見つかりません → https://cloud.google.com/sdk/docs/install"; exit 1; }
	@command -v bq     >/dev/null || { echo "ERROR: bq が見つかりません (gcloud components install bq)"; exit 1; }
	@test -n "$(PROJECT_ID)" || { echo "ERROR: PROJECT_ID が未設定です → gcloud config set project <ID> または make forecast PROJECT_ID=<ID>"; exit 1; }
	@gcloud auth application-default print-access-token >/dev/null 2>&1 \
		|| echo "WARN: ADC が未設定の可能性があります → gcloud auth application-default login"
	@echo "OK: project=$(PROJECT_ID) location=$(LOCATION)"

# -------------------------------------------------------
# セットアップ
# -------------------------------------------------------
enable-apis: ## BigQuery 関連 API を有効化
	gcloud services enable bigquery.googleapis.com bigqueryconnection.googleapis.com \
		--project=$(PROJECT_ID)

dataset: check ## データセットを作成 (既存ならスキップ)
	@bq --project_id=$(PROJECT_ID) show --dataset $(DATASET) >/dev/null 2>&1 \
		&& echo "dataset $(DATASET) は既に存在します" \
		|| bq --project_id=$(PROJECT_ID) mk --dataset --location=$(LOCATION) \
			--description="AI.FORECAST (TimesFM) 需要予測デモ" $(DATASET)

seed: ## サンプルデータ (売上実績 / 在庫 / 特売) を投入
	@echo "==> daily_sales ($(HISTORY_DAYS) 日分) を作成中..."
	@$(RENDER) $(SQL_DIR)/01_seed_daily_sales.sql | $(BQ_QUERY)
	@echo "==> current_inventory / promotions を作成中..."
	@$(RENDER) $(SQL_DIR)/02_seed_inventory_promotions.sql | $(BQ_QUERY)
	@echo "==> 完了"

setup: dataset seed show-data ## データセット作成 + サンプルデータ投入 + 確認

show-data: ## 投入した売上実績データの内訳を表示
	@$(RENDER) $(SQL_DIR)/00_show_data.sql | $(BQ_QUERY)

# -------------------------------------------------------
# 予測
# -------------------------------------------------------
forecast: ## 【本題】対象商品の店舗別 需要予測を実行
	@$(RENDER) $(SQL_DIR)/10_forecast.sql | $(BQ_QUERY)

save: ## 予測結果を forecast_results テーブルに保存
	@$(RENDER) $(SQL_DIR)/11_forecast_save.sql | $(BQ_QUERY)
	@echo "==> $(PROJECT_ID):$(DATASET).forecast_results に保存しました"

order-plan: ## 予測値から発注量 (ケース数) を算出
	@$(RENDER) $(SQL_DIR)/12_order_plan.sql | $(BQ_QUERY)

evaluate: ## 直近 EVAL_HORIZON 日でバックテストして精度を確認
	@$(RENDER) $(SQL_DIR)/13_evaluate.sql | $(BQ_QUERY)

history: ## 実績 + 予測をまとめて出力 (グラフ用)
	@$(RENDER) $(SQL_DIR)/14_forecast_with_history.sql | $(BQ_QUERY)

demo: setup forecast order-plan ## セットアップから発注量算出まで一気に実行

# -------------------------------------------------------
# 開発補助
# -------------------------------------------------------
dry-run: ## 全 SQL を構文チェック (クエリは実行されず課金もされない)
	@for f in $(SQL_DIR)/*.sql; do \
		printf '%-42s' "$$f"; \
		if $(RENDER) $$f | bq --project_id=$(PROJECT_ID) --location=$(LOCATION) \
			query --use_legacy_sql=false --dry_run >/dev/null 2>&1; then \
			echo "OK"; \
		else \
			echo "FAILED"; \
			$(RENDER) $$f | bq --project_id=$(PROJECT_ID) --location=$(LOCATION) \
				query --use_legacy_sql=false --dry_run 2>&1 | head -5; \
		fi; \
	done

print-sql: ## 置換後の SQL を表示 (例: make print-sql FILE=sql/10_forecast.sql)
	@test -n "$(FILE)" || { echo "ERROR: FILE=sql/10_forecast.sql のように指定してください"; exit 1; }
	@$(RENDER) $(FILE)

# -------------------------------------------------------
# 後始末
# -------------------------------------------------------
clean: ## データセットを中のテーブルごと削除 (確認あり / FORCE=1 でスキップ)
	@bq --project_id=$(PROJECT_ID) ls $(DATASET) 2>/dev/null || true
	@# 確認と削除は必ず同じシェルで実行する。
	@# 別レシピ行に分けると、確認を中断しても次の行で削除が走ってしまう。
	@if [ "$(FORCE)" != "1" ]; then \
		printf "上記テーブルを含む %s:%s を削除します。よろしいですか? [y/N] " "$(PROJECT_ID)" "$(DATASET)"; \
		read ans; \
		if [ "$$ans" != "y" ]; then echo "中止しました"; exit 0; fi; \
	fi; \
	set -x; \
	bq --project_id=$(PROJECT_ID) rm -r -f --dataset $(DATASET)
