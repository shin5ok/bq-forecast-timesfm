-- ============================================================
-- AI.EVALUATE による精度検証（バックテスト）
--
-- 直近 @EVAL_HORIZON@ 日を「答え合わせ用」に切り出し、それ以前のデータだけで
-- 予測させて実績と突き合わせる。発注ロジックに乗せる前に、
-- 店舗ごとにどれくらいの誤差が出るかを把握しておくためのステップ。
--
-- 目安: MAPE（平均絶対パーセント誤差）が小さいほど精度が高い。
--       mean_absolute_scaled_error < 1 なら「前日の値をそのまま使う」より優秀。
--
-- 答え合わせ日数に HORIZON ではなく EVAL_HORIZON を使う理由:
--   HORIZON=7 だと評価に使える点がわずか 7 個しかなく、たまたま外れた 1〜2 日で
--   指標が大きく振れてしまう。既定の 28 日（4 週分）なら曜日パターンを 4 周
--   まわせるので、指標が「その週の運」ではなく実力を表すようになる。
--   `make evaluate EVAL_HORIZON=56` のように、さらに伸ばすこともできる。
--   ただし HISTORY_DAYS - EVAL_HORIZON がコンテキストとして残る日数になるため、
--   伸ばしすぎると今度は学習に使える履歴が痩せる点に注意。
-- ============================================================
WITH target_item AS (
  SELECT date, store_id, item_name, sales_qty
  FROM `@PROJECT_ID@.@DATASET@.daily_sales`
  WHERE item_name = '@ITEM_NAME@'
)
SELECT
  store_id,
  item_name,
  ROUND(mean_absolute_error, 2)                      AS mae,
  ROUND(root_mean_squared_error, 2)                  AS rmse,
  ROUND(mean_absolute_percentage_error, 2)           AS mape_pct,
  ROUND(symmetric_mean_absolute_percentage_error, 2) AS smape_pct,
  ROUND(mean_absolute_scaled_error, 3)               AS mase,
  ai_evaluate_status
FROM AI.EVALUATE(
  -- 学習（コンテキスト）データ: 直近 @EVAL_HORIZON@ 日を除いた過去データ
  (
    SELECT * FROM target_item
    WHERE date <= DATE_SUB((SELECT MAX(date) FROM target_item), INTERVAL @EVAL_HORIZON@ DAY)
  ),
  -- 答え合わせデータ: 直近 @EVAL_HORIZON@ 日の実績
  (
    SELECT * FROM target_item
    WHERE date > DATE_SUB((SELECT MAX(date) FROM target_item), INTERVAL @EVAL_HORIZON@ DAY)
  ),
  model         => '@MODEL@',
  data_col      => 'sales_qty',
  timestamp_col => 'date',
  id_cols       => ['store_id', 'item_name']
)
ORDER BY store_id;
