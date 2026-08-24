-- ============================================================
-- 予測結果をテーブルに保存する
--   `@DATASET@.forecast_results`
--
-- 毎朝バッチで実行して発注システムに連携する、という運用を想定。
-- generated_at を持たせておくと「いつ時点の予測か」を追跡できる。
-- ============================================================
CREATE OR REPLACE TABLE `@PROJECT_ID@.@DATASET@.forecast_results`
PARTITION BY sales_date
CLUSTER BY store_id, item_name
AS
SELECT
  CURRENT_TIMESTAMP() AS generated_at,
  store_id,
  item_name,
  DATE(forecast_timestamp) AS sales_date,
  forecast_value,
  prediction_interval_lower_bound AS lower_bound,
  prediction_interval_upper_bound AS upper_bound,
  confidence_level,
  ai_forecast_status
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
);
