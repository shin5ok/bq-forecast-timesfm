-- ============================================================
-- 投入した売上実績データの確認
-- 「00納豆」以外の商品も入っていること、期間・件数が想定通りかを見る
-- ============================================================
SELECT
  item_name,
  store_id,
  COUNT(*)       AS days,
  MIN(date)      AS from_date,
  MAX(date)      AS to_date,
  MIN(sales_qty) AS min_qty,
  CAST(ROUND(AVG(sales_qty)) AS INT64) AS avg_qty,
  MAX(sales_qty) AS max_qty
FROM `@PROJECT_ID@.@DATASET@.daily_sales`
GROUP BY item_name, store_id
ORDER BY item_name, store_id;
