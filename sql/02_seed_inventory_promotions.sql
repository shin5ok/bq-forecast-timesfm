-- ============================================================
-- サンプルデータ生成: 発注計算に使うマスタ2種
--   `@DATASET@.current_inventory` … 各店舗の現在庫（発注量から差し引く）
--   `@DATASET@.promotions`        … 特売カレンダー（欠品を避けたい日）
--
-- 実運用では在庫管理システム / 販促計画システムから連携される想定。
-- ============================================================

-- ------------------------------------------------------------
-- 現在庫: 発注のタイミングで店頭 + バックヤードに残っている数
-- ------------------------------------------------------------
CREATE OR REPLACE TABLE `@PROJECT_ID@.@DATASET@.current_inventory` AS
SELECT * FROM UNNEST([
  STRUCT('S01' AS store_id, '00納豆' AS item_name, 40 AS stock_qty),
  STRUCT('S02',             '00納豆',              25),
  STRUCT('S03',             '00納豆',              12)
]);

-- ------------------------------------------------------------
-- 特売カレンダー: この日は prediction_interval_upper_bound を基準に
-- 多めに発注し、欠品による機会損失を防ぐ
-- ------------------------------------------------------------
CREATE OR REPLACE TABLE `@PROJECT_ID@.@DATASET@.promotions` AS
SELECT
  store_id,
  item_name,
  promo_date,
  promo_name
FROM UNNEST([
  -- 予測対象期間（daily_sales の最終日=昨日 の翌日から @HORIZON@ 日間）の中に特売日を差し込む
  STRUCT('S01' AS store_id, '00納豆' AS item_name,
         DATE_ADD(CURRENT_DATE('@TIMEZONE@'), INTERVAL 2 DAY) AS promo_date,
         '納豆の日セール' AS promo_name),
  STRUCT('S02',             '00納豆',
         DATE_ADD(CURRENT_DATE('@TIMEZONE@'), INTERVAL 2 DAY),
         '納豆の日セール'),
  STRUCT('S03',             '00納豆',
         DATE_ADD(CURRENT_DATE('@TIMEZONE@'), INTERVAL 5 DAY),
         '週末朝市')
]);
