-- ============================================================
-- 実績 + 予測を1つの時系列として出力する
--
-- output_historical_time_series => TRUE を指定すると、
-- 入力した過去データと予測値が同じ列に並んで返る。
-- Looker Studio / スプレッドシートでそのままグラフ化するとき用。
--
-- 注意: このモードでは出力列名が変わる
--   forecast_timestamp / forecast_value
--     → time_series_type / time_series_timestamp / time_series_data
-- ============================================================
SELECT
  store_id,
  item_name,
  time_series_type,                        -- 'history' or 'forecast'
  DATE(time_series_timestamp) AS sales_date,
  ROUND(time_series_data, 1)  AS qty,
  ROUND(prediction_interval_lower_bound, 1) AS lower_bound,
  ROUND(prediction_interval_upper_bound, 1) AS upper_bound
FROM AI.FORECAST(
  (
    SELECT date, store_id, item_name, sales_qty
    FROM `@PROJECT_ID@.@DATASET@.daily_sales`
    WHERE item_name = '@ITEM_NAME@'
  ),
  model                         => '@MODEL@',
  data_col                      => 'sales_qty',
  timestamp_col                 => 'date',
  id_cols                       => ['store_id', 'item_name'],
  horizon                       => @HORIZON@,
  confidence_level              => @CONFIDENCE_LEVEL@,
  output_historical_time_series => TRUE
)
-- 直近30日の実績と予測だけを表示（全期間を見たい場合はこの WHERE を外す）
WHERE DATE(time_series_timestamp) >= DATE_SUB(CURRENT_DATE('@TIMEZONE@'), INTERVAL 30 DAY)
ORDER BY store_id, sales_date;
