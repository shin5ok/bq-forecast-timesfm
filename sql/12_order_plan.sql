-- ============================================================
-- 予測値 → 発注量への変換（仕入れ業務での使い方）
--
-- ロジック:
--   1. 通常日   … forecast_value（予測の中央値）を needed_qty とする
--      特売日   … prediction_interval_upper_bound（予測の上限値）を needed_qty とする
--                 → 品切れによる機会損失を防ぐ
--   2. 現在庫を古い日付から順に消化させ、足りない分だけを発注する
--   3. ケース入数（@CASE_LOT@ 個/ケース）に切り上げて実際の発注ケース数を出す
--
-- 納豆は賞味期限が短いため、上限値の採用は特売日に限定し、
-- 通常日は中央値ベースにして廃棄ロスを抑える。
-- ============================================================
WITH forecast AS (
  SELECT
    store_id,
    item_name,
    DATE(forecast_timestamp) AS sales_date,
    forecast_value,
    prediction_interval_upper_bound AS upper_bound
  FROM AI.FORECAST(
    (
      SELECT date, store_id, item_name, sales_qty
      FROM `@PROJECT_ID@.@DATASET@.daily_sales`
      WHERE item_name = '@ITEM_NAME@'
    ),
    model            => '@MODEL@',
    data_col         => 'sales_qty',
    timestamp_col    => 'date',
    id_cols          => ['store_id', 'item_name'],
    horizon          => @HORIZON@,
    confidence_level => @CONFIDENCE_LEVEL@
  )
),
-- 特売日かどうかを判定し、その日に確保すべき数量（needed_qty）を決める
needed AS (
  SELECT
    f.store_id,
    f.item_name,
    f.sales_date,
    f.forecast_value,
    f.upper_bound,
    p.promo_name,
    -- 特売日は上限値、通常日は予測値を採用
    IF(p.promo_date IS NULL, f.forecast_value, f.upper_bound) AS needed_qty
  FROM forecast AS f
  LEFT JOIN `@PROJECT_ID@.@DATASET@.promotions` AS p
    ON  f.store_id   = p.store_id
    AND f.item_name  = p.item_name
    AND f.sales_date = p.promo_date
),
-- 現在庫を日付の古い順に消化させる
with_stock AS (
  SELECT
    n.*,
    COALESCE(i.stock_qty, 0) AS stock_qty,
    -- その日より前に消化される見込み数量の累計
    COALESCE(
      SUM(n.needed_qty) OVER (
        PARTITION BY n.store_id, n.item_name
        ORDER BY n.sales_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
      ), 0
    ) AS consumed_before
  FROM needed AS n
  LEFT JOIN `@PROJECT_ID@.@DATASET@.current_inventory` AS i
    ON n.store_id = i.store_id AND n.item_name = i.item_name
)
SELECT
  store_id,
  item_name,
  sales_date,
  FORMAT_DATE('%a', sales_date) AS dow,
  IFNULL(promo_name, '-')       AS promo,
  ROUND(forecast_value, 1)      AS forecast_qty,
  ROUND(upper_bound, 1)         AS upper_bound,
  ROUND(needed_qty, 1)          AS needed_qty,
  -- その日の開始時点で使える在庫（前日までに消化された分を差し引く）
  ROUND(GREATEST(stock_qty - consumed_before, 0), 1) AS stock_available,
  -- 発注すべき素の数量
  CAST(CEIL(GREATEST(needed_qty - GREATEST(stock_qty - consumed_before, 0), 0)) AS INT64) AS raw_order_qty,
  -- ケース単位に切り上げた実際の発注
  CAST(CEIL(GREATEST(needed_qty - GREATEST(stock_qty - consumed_before, 0), 0) / @CASE_LOT@) AS INT64) AS order_cases,
  CAST(CEIL(GREATEST(needed_qty - GREATEST(stock_qty - consumed_before, 0), 0) / @CASE_LOT@) * @CASE_LOT@ AS INT64) AS order_qty
FROM with_stock
ORDER BY store_id, sales_date;
