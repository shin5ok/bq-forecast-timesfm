-- ============================================================
-- サンプルデータ生成: 日次売上実績テーブル
--   `@DATASET@.daily_sales`
--
-- 実運用では POS から連携される既存テーブルを使うため、
-- このファイルはデモ用の疑似データ生成にあたる。
--
-- 特徴:
--   - 3店舗 x 8商品 x @HISTORY_DAYS@ 日分の日次売上
--   - 「みんなの納豆」以外の商品も混在させ、WHERE で絞り込む前提を再現
--   - 商品ごとに異なる「曜日変動」と「年間の季節変動」を持たせている
--     （夏物 / 冬物 / 平日型 / ほぼフラット、の4パターン）
--   - 緩やかな増加トレンド
--   - FARM_FINGERPRINT を使った再現性のあるノイズ（実行しても結果が変わらない）
--
-- 需要の組み立て:
--   base_qty x 店舗規模 x 曜日変動 x 季節変動 x トレンド x ノイズ
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
  -- ------------------------------------------------------------
  -- 商品マスタ
  --   base_qty        : 平日ベースの需要（個/日）
  --   weekend_lift    : 土日の増減率。マイナスなら「土日に落ちる」平日型商品
  --   friday_lift     : 金曜だけの増加率（晩酌・週末の買い込み需要）
  --   season_amp      : 年間の季節変動の振幅。0.00 なら季節性なし。
  --                     0.55 ならピーク時 1.55 倍 / 半年後の底 0.45 倍
  --   season_peak_doy : 需要ピークの通日 (1-366)。1/20=20, 7/24=205, 8/1=213, 10/12=285
  --   noise_ratio     : 日々のばらつきの大きさ
  -- ------------------------------------------------------------
  items AS (
    SELECT * FROM UNNEST([
      -- 【予測対象の主役】週次周期性のみ。
      -- README に載せている実行例の数値と一致させるため、季節性は意図的に付けていない。
      STRUCT('みんなの納豆' AS item_name, 110 AS base_qty,
             0.18 AS weekend_lift, 0.00 AS friday_lift,
             0.00 AS season_amp, 1 AS season_peak_doy, 0.10 AS noise_ratio),

      -- 夏の冷奴需要でゆるやかに伸びる
      STRUCT('絹ごし豆腐' AS item_name, 90 AS base_qty,
             0.12 AS weekend_lift, 0.00 AS friday_lift,
             0.15 AS season_amp, 213 AS season_peak_doy, 0.12 AS noise_ratio),

      -- 日配の定番。曜日差も季節差も小さい
      STRUCT('成分無調整牛乳' AS item_name, 140 AS base_qty,
             0.08 AS weekend_lift, 0.00 AS friday_lift,
             0.07 AS season_amp, 213 AS season_peak_doy, 0.09 AS noise_ratio),

      -- 【夏物】季節変動が最も大きい。真夏はピーク、真冬は底
      STRUCT('アイスクリーム' AS item_name, 100 AS base_qty,
             0.25 AS weekend_lift, 0.00 AS friday_lift,
             0.55 AS season_amp, 213 AS season_peak_doy, 0.15 AS noise_ratio),

      -- 【冬物】アイスクリームとほぼ逆位相。夏場はほとんど動かない
      STRUCT('鍋つゆ' AS item_name, 70 AS base_qty,
             0.30 AS weekend_lift, 0.05 AS friday_lift,
             0.70 AS season_amp, 20 AS season_peak_doy, 0.18 AS noise_ratio),

      -- 【季節性 + 強い曜日性】夏に伸び、さらに金土に大きく跳ねる
      STRUCT('缶ビール350ml' AS item_name, 130 AS base_qty,
             0.35 AS weekend_lift, 0.20 AS friday_lift,
             0.35 AS season_amp, 205 AS season_peak_doy, 0.12 AS noise_ratio),

      -- 【平日型】オフィス需要のため土日に落ちる。weekend_lift がマイナス
      STRUCT('おにぎり' AS item_name, 200 AS base_qty,
             -0.25 AS weekend_lift, 0.00 AS friday_lift,
             0.05 AS season_amp, 285 AS season_peak_doy, 0.08 AS noise_ratio),

      -- 【ベースライン】曜日差・季節差・ノイズすべて小さい。予測が最も当たる商品
      STRUCT('食パン' AS item_name, 160 AS base_qty,
             0.04 AS weekend_lift, 0.00 AS friday_lift,
             0.05 AS season_amp, 30 AS season_peak_doy, 0.06 AS noise_ratio)
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
      -- 曜日変動: DAYOFWEEK は 1=日曜, 6=金曜, 7=土曜
      --   weekend_lift がマイナスの商品（おにぎり）はここで土日に落ちる
      * (1 + i.weekend_lift * IF(EXTRACT(DAYOFWEEK FROM c.date) IN (1, 7), 1, 0)
           + i.friday_lift  * IF(EXTRACT(DAYOFWEEK FROM c.date) = 6, 1, 0))
      -- 年間の季節変動: season_peak_doy を頂点とするコサイン波
      --   ACOS(-1) は円周率。ピーク日で COS(0)=1 → (1 + season_amp) 倍、
      --   その半年後に COS(π)=-1 → (1 - season_amp) 倍になる
      * (1 + i.season_amp
             * COS(2 * ACOS(-1) * (EXTRACT(DAYOFYEAR FROM c.date) - i.season_peak_doy) / 365.0))
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
