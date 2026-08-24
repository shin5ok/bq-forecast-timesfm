-- ============================================================
-- 【本題】AI.FORECAST による「00納豆」の店舗別 需要予測
--
-- AI.FORECAST はテーブルだけでなく、カッコ () で囲んだサブクエリを
-- そのまま入力データとして受け取れる。
-- → 事前に中間テーブルや ML モデルを作らずに、対象商品だけに絞って予測できる。
--
-- TimesFM はゼロショットの基盤モデルなので CREATE MODEL は不要。
-- ============================================================
SELECT
  store_id,
  item_name,
  DATE(forecast_timestamp) AS sales_date,
  FORMAT_DATE('%a', DATE(forecast_timestamp)) AS dow,
  ROUND(forecast_value, 1) AS forecast_qty,
  ROUND(prediction_interval_lower_bound, 1) AS lower_bound,
  ROUND(prediction_interval_upper_bound, 1) AS upper_bound,
  confidence_level,
  ai_forecast_status
FROM AI.FORECAST(
  -- 1. 入力データ: '00納豆' の過去データのみを抽出して渡す
  (
    SELECT date, store_id, item_name, sales_qty
    FROM `@PROJECT_ID@.@DATASET@.daily_sales`
    WHERE item_name = '@ITEM_NAME@'
  ),
  model            => '@MODEL@',                 -- 推奨される最新のゼロショットモデル
  data_col         => 'sales_qty',               -- 予測したい数値（売上数）
  timestamp_col    => 'date',                    -- 時間軸（日付）
  id_cols          => ['store_id', 'item_name'], -- 店舗と商品をセットで1つの時系列として認識させる
  horizon          => @HORIZON@,                 -- 未来 @HORIZON@ 日分を予測
  confidence_level => @CONFIDENCE_LEVEL@         -- 予測区間の信頼度
)
ORDER BY store_id, sales_date;
