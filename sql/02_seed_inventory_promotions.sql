-- ============================================================
-- サンプルデータ生成: 発注計算に使うマスタ2種
--   `@DATASET@.current_inventory` … 各店舗の現在庫（発注量から差し引く）
--   `@DATASET@.promotions`        … 特売カレンダー（欠品を避けたい日）
--
-- 実運用では在庫管理システム / 販促計画システムから連携される想定。
--
-- daily_sales の全8商品ぶんを用意してあるので、
-- `make order-plan ITEM_NAME=アイスクリーム` のように対象を変えても動く。
-- ============================================================

-- ------------------------------------------------------------
-- 現在庫: 発注のタイミングで店頭 + バックヤードに残っている数
--   おおよそ「その店の1日の販売数の 1/3 程度」。
--   おにぎりのような日配品は繰り越しが少ないため薄めにしてある。
-- ------------------------------------------------------------
CREATE OR REPLACE TABLE `@PROJECT_ID@.@DATASET@.current_inventory` AS
SELECT * FROM UNNEST([
  STRUCT('S01' AS store_id, '00納豆' AS item_name, 40 AS stock_qty),
  STRUCT('S02',             '00納豆',              25),
  STRUCT('S03',             '00納豆',              12),

  STRUCT('S01',             '絹ごし豆腐',          30),
  STRUCT('S02',             '絹ごし豆腐',          22),
  STRUCT('S03',             '絹ごし豆腐',          26),

  STRUCT('S01',             '成分無調整牛乳',      45),
  STRUCT('S02',             '成分無調整牛乳',      32),
  STRUCT('S03',             '成分無調整牛乳',      40),

  STRUCT('S01',             'アイスクリーム',      35),
  STRUCT('S02',             'アイスクリーム',      25),
  STRUCT('S03',             'アイスクリーム',      30),

  STRUCT('S01',             '鍋つゆ',              24),
  STRUCT('S02',             '鍋つゆ',              18),
  STRUCT('S03',             '鍋つゆ',              20),

  STRUCT('S01',             '缶ビール350ml',       45),
  STRUCT('S02',             '缶ビール350ml',       32),
  STRUCT('S03',             '缶ビール350ml',       38),

  STRUCT('S01',             'おにぎり',            20),
  STRUCT('S02',             'おにぎり',            15),
  STRUCT('S03',             'おにぎり',            18),

  STRUCT('S01',             '食パン',              50),
  STRUCT('S02',             '食パン',              36),
  STRUCT('S03',             '食パン',              44)
]);

-- ------------------------------------------------------------
-- 特売カレンダー: この日は prediction_interval_upper_bound を基準に
-- 多めに発注し、欠品による機会損失を防ぐ
--
-- 注意: 予測期間は CURRENT_DATE 〜 CURRENT_DATE + @HORIZON@ - 1 日。
--       ここのオフセットが @HORIZON@ 以上になると特売日が予測期間から外れ、
--       order-plan の特売分岐が動かなくなる（最大オフセットは 5）。
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
         '週末朝市'),

  -- 納豆以外の商品にも特売を用意しておく
  STRUCT('S02',             'おにぎり',
         DATE_ADD(CURRENT_DATE('@TIMEZONE@'), INTERVAL 1 DAY),
         'おにぎり100円セール'),
  STRUCT('S01',             'アイスクリーム',
         DATE_ADD(CURRENT_DATE('@TIMEZONE@'), INTERVAL 3 DAY),
         'アイス3個パック特売'),
  STRUCT('S02',             'アイスクリーム',
         DATE_ADD(CURRENT_DATE('@TIMEZONE@'), INTERVAL 3 DAY),
         'アイス3個パック特売'),
  STRUCT('S01',             '缶ビール350ml',
         DATE_ADD(CURRENT_DATE('@TIMEZONE@'), INTERVAL 4 DAY),
         'ビール6缶パック特売')
]);
