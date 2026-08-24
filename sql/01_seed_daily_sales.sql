-- ============================================================
-- サンプルデータ生成: 日次売上実績テーブル
--   `@DATASET@.daily_sales`
--
-- 実運用では POS から連携される既存テーブルを使うため、
-- このファイルはデモ用の疑似データ生成にあたる。
--
-- 特徴:
--   - 3店舗 x 3商品 x @HISTORY_DAYS@ 日分の日次売上
--   - 「00納豆」以外の商品も混在させ、WHERE で絞り込む前提を再現
--   - 土日に需要が伸びる週次周期性 + 緩やかな増加トレンド
--   - FARM_FINGERPRINT を使った再現性のあるノイズ（実行しても結果が変わらない）
-- ============================================================
CREATE OR REPLACE TABLE `@PROJECT_ID@.@DATASET@.daily_sales`
PARTITION BY date
CLUSTER BY store_id, item_name
AS
WITH
  params AS (
    SELECT
      DATE_SUB(CURRENT_DATE('@TIMEZONE@'), INTERVAL @HISTORY_DAYS@ DAY) AS start_date,
      DATE_SUB(CURRENT_DATE('@TIMEZONE@'), INTERVAL 1 DAY)              AS end_date
  ),
  calendar AS (
    SELECT d AS date
    FROM params, UNNEST(GENERATE_DATE_ARRAY(params.start_date, params.end_date)) AS d
  ),
  stores AS (
    SELECT * FROM UNNEST([
      STRUCT('S01' AS store_id, '新宿店' AS store_name, 1.00 AS store_scale),
      STRUCT('S02',             '渋谷店',               0.72),
      STRUCT('S03',             '池袋店',               0.88)
    ])
  ),
  items AS (
    SELECT * FROM UNNEST([
      -- base_qty: 平日ベース需要 / weekend_lift: 土日の増加率 / noise_ratio: ばらつきの大きさ
      STRUCT('00納豆'        AS item_name, 110 AS base_qty, 0.18 AS weekend_lift, 0.10 AS noise_ratio),
      STRUCT('絹ごし豆腐',                   90,             0.12,                 0.12),
      STRUCT('成分無調整牛乳',               140,            0.08,                 0.09)
    ])
  )
SELECT
  c.date,
  s.store_id,
  s.store_name,
  i.item_name,
  GREATEST(
    CAST(ROUND(
      i.base_qty
      * s.store_scale
      -- 週次周期性: 日曜(1) と 土曜(7) は需要が伸びる
      * (1 + i.weekend_lift * IF(EXTRACT(DAYOFWEEK FROM c.date) IN (1, 7), 1, 0))
      -- 緩やかな右肩上がりのトレンド
      * (1 + 0.0008 * DATE_DIFF(c.date, p.start_date, DAY))
      -- 再現性のあるノイズ: -noise_ratio 〜 +noise_ratio の範囲
      * (1 + i.noise_ratio
             * (MOD(ABS(FARM_FINGERPRINT(CONCAT(s.store_id, i.item_name, CAST(c.date AS STRING)))), 2001) - 1000)
             / 1000)
    ) AS INT64),
    0
  ) AS sales_qty
FROM calendar AS c
CROSS JOIN stores AS s
CROSS JOIN items  AS i
CROSS JOIN params AS p;
