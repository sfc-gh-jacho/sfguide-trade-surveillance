/*
================================================================================
 TRADE SURVEILLANCE AND MARKET ABUSE DETECTION - DEMO SCRIPT
 Detect suspicious trading patterns in SQL, where the order data already lives:
 - Wash trading (self-join on beneficial ownership)
 - Spoofing / layering (MATCH_RECOGNIZE sequence patterns)
 - Front-running (time-window joins)
 - Marking the close (window shares + QUALIFY)
 - A consolidated, explainable alert queue
 - A Dynamic Table that keeps alerts fresh as new orders arrive
 - Optional: masking trader and account IDs for reviewers (Enterprise)

 Scenario: one trading day at a fictional broker-dealer. ~200,000 normal
 orders, with a dozen planted abusive patterns for the rules to find.

 Thresholds and scores in this script are ILLUSTRATIVE. They are not
 production surveillance rules or regulatory guidance.

 This script creates its own objects (SURV_DEMO_DB, SURV_WH and two SURV_
 roles) and changes nothing that already exists. Step 13 removes everything.

 ALL DATA IN THIS SCRIPT IS SYNTHETIC. Tickers TKR01-TKR25 are fictional.
================================================================================
*/

-- [step:setup]
-- ============================================================================
-- STEP 1: SETUP
-- ============================================================================

-- Choose the role that runs the demo:
--   'ACCOUNTADMIN'    - simplest, for sandbox accounts
--   'SURV_DEMO_ROLE'  - least privilege; create it once with the block below
SET demo_role = 'ACCOUNTADMIN';

-- OPTIONAL: least-privilege demo role. An administrator runs this ONCE,
-- then set demo_role = 'SURV_DEMO_ROLE' above.
-- USE ROLE ACCOUNTADMIN;
-- CREATE ROLE IF NOT EXISTS SURV_DEMO_ROLE COMMENT = 'Runs the trade surveillance demo';
-- GRANT CREATE DATABASE  ON ACCOUNT TO ROLE SURV_DEMO_ROLE;  -- demo database (owned by this role)
-- GRANT CREATE WAREHOUSE ON ACCOUNT TO ROLE SURV_DEMO_ROLE;  -- XSMALL warehouse for queries + Dynamic Table
-- GRANT CREATE ROLE      ON ACCOUNT TO ROLE SURV_DEMO_ROLE;  -- Step 12 only (analyst/reviewer roles)
-- SET my_user = CURRENT_USER();
-- GRANT ROLE SURV_DEMO_ROLE TO USER IDENTIFIER($my_user);
-- Skipping Step 12? Leave out CREATE ROLE. To avoid CREATE WAREHOUSE, grant
-- USAGE on an existing warehouse and replace SURV_WH below with it.

USE ROLE IDENTIFIER($demo_role);

CREATE WAREHOUSE IF NOT EXISTS SURV_WH
    WAREHOUSE_SIZE = XSMALL AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE;
USE WAREHOUSE SURV_WH;

CREATE OR REPLACE DATABASE SURV_DEMO_DB;
CREATE SCHEMA IF NOT EXISTS SURV_DEMO_DB.SURVEILLANCE;
USE SCHEMA SURV_DEMO_DB.SURVEILLANCE;

-- [step:reference]
-- ============================================================================
-- STEP 2: REFERENCE DATA - Traders, Accounts and Instruments
-- ============================================================================

-- 40 traders across four desks
CREATE OR REPLACE TABLE SURV_TRADERS AS
SELECT
    'T' || LPAD(SEQ4() + 1, 3, '0')                                     AS trader_id,
    DECODE(MOD(SEQ4(), 4), 0, 'EQUITY_CASH', 1, 'PROGRAM', 2, 'HIGH_TOUCH', 'ETF') AS desk,
    DECODE(MOD(SEQ4(), 2), 0, 'AMERICAS', 'EMEA')                         AS region
FROM TABLE(GENERATOR(ROWCOUNT => 40));

-- Accounts: one PROP (firm) account per trader (A0001-A0040) and 80 CLIENT
-- accounts (A0041-A0120). Each normally has its own beneficial owner.
CREATE OR REPLACE TABLE SURV_ACCOUNTS AS
SELECT
    'A' || LPAD(n, 4, '0')                                               AS account_id,
    IFF(n <= 40, 'PROP', 'CLIENT')                                       AS account_type,
    'T' || LPAD(IFF(n <= 40, n, MOD(n - 41, 40) + 1), 3, '0')            AS trader_id,
    'BO_' || LPAD(n, 4, '0')                                             AS beneficial_owner
FROM (SELECT SEQ4() + 1 AS n FROM TABLE(GENERATOR(ROWCOUNT => 120)));

-- Four extra client accounts that are secretly linked in pairs:
-- different account numbers, same beneficial owner
INSERT INTO SURV_ACCOUNTS VALUES
    ('A0121', 'CLIENT', 'T031', 'BO_SHELL_1'),
    ('A0122', 'CLIENT', 'T031', 'BO_SHELL_1'),
    ('A0123', 'CLIENT', 'T036', 'BO_SHELL_2'),
    ('A0124', 'CLIENT', 'T036', 'BO_SHELL_2');

-- 25 fictional instruments
CREATE OR REPLACE TABLE SURV_INSTRUMENTS AS
SELECT
    SEQ4() + 1                                                           AS instr_idx,
    'TKR' || LPAD(SEQ4() + 1, 2, '0')                                    AS ticker,
    DECODE(MOD(SEQ4(), 5), 0, 'TECH', 1, 'FINANCIALS', 2, 'ENERGY', 3, 'HEALTHCARE', 'INDUSTRIALS') AS sector,
    20 + (SEQ4() + 1) * 7.5                                              AS ref_price
FROM TABLE(GENERATOR(ROWCOUNT => 25));

SELECT account_type, COUNT(*) AS accounts FROM SURV_ACCOUNTS GROUP BY account_type;

-- [step:orders]
-- ============================================================================
-- STEP 3: ONE DAY OF ORDERS AND EXECUTIONS
-- ============================================================================
-- 200,000 normal orders between 09:30 and 16:00 on 2026-11-06, generated
-- deterministically. Normal flow: 100-2,000 shares, ~15% cancelled, and every
-- cancel happens at least 30 seconds after the order.

CREATE OR REPLACE TABLE SURV_ORDERS (
    ORDER_ID      NUMBER,
    ACCOUNT_ID    VARCHAR(10),
    TRADER_ID     VARCHAR(10),
    TICKER        VARCHAR(10),
    SIDE          VARCHAR(4),
    QTY           NUMBER,
    LIMIT_PRICE   NUMBER(12,2),
    ORDER_TS      TIMESTAMP_NTZ(3),
    STATUS        VARCHAR(10),       -- FILLED or CANCELLED
    CANCEL_TS     TIMESTAMP_NTZ(3)
);

INSERT INTO SURV_ORDERS
WITH g AS (
    SELECT
        SEQ4()                                                           AS n,
        'A' || LPAD(MOD(ABS(HASH(SEQ4(), 'acct')), 120) + 1, 4, '0')     AS account_id,
        MOD(ABS(HASH(SEQ4(), 'tkr')), 25) + 1                            AS instr_idx,
        DATEADD(MILLISECOND, MOD(ABS(HASH(SEQ4(), 'ts')), 23400000),
                '2026-11-06 09:30:00'::TIMESTAMP_NTZ)                    AS order_ts,
        MOD(ABS(HASH(SEQ4(), 'st')), 100) < 15                           AS is_cancel
    FROM TABLE(GENERATOR(ROWCOUNT => 200000))
)
SELECT
    g.n + 1,
    g.account_id,
    a.trader_id,
    i.ticker,
    IFF(MOD(ABS(HASH(g.n, 'side')), 2) = 0, 'BUY', 'SELL'),
    (MOD(ABS(HASH(g.n, 'qty')), 20) + 1) * 100,
    ROUND(i.ref_price * (1 + (MOD(ABS(HASH(g.n, 'px')), 101) - 50) / 10000), 2),
    g.order_ts,
    IFF(g.is_cancel, 'CANCELLED', 'FILLED'),
    IFF(g.is_cancel, DATEADD(SECOND, 30 + MOD(ABS(HASH(g.n, 'cxl')), 570), g.order_ts), NULL)
FROM g
JOIN SURV_ACCOUNTS    a ON a.account_id = g.account_id
JOIN SURV_INSTRUMENTS i ON i.instr_idx  = g.instr_idx;

CREATE OR REPLACE TABLE SURV_EXECUTIONS (
    EXEC_ID      NUMBER,
    ORDER_ID     NUMBER,
    EXEC_TS      TIMESTAMP_NTZ(3),
    EXEC_QTY     NUMBER,
    EXEC_PRICE   NUMBER(12,2)
);

-- [step:plant]
-- ============================================================================
-- STEP 4: PLANT THE ABUSIVE PATTERNS
-- ============================================================================
-- Twelve known cases hidden among 200,000 normal orders. In real life you
-- wouldn't know they're there; here they let you check that each rule works.

INSERT INTO SURV_ORDERS VALUES
-- Wash trades: linked accounts trade with each other (same beneficial owner)
(900001, 'A0121', 'T031', 'TKR03', 'BUY',   8000,  42.50, '2026-11-06 10:15:00.000', 'FILLED', NULL),
(900002, 'A0122', 'T031', 'TKR03', 'SELL',  8000,  42.51, '2026-11-06 10:15:20.000', 'FILLED', NULL),
(900003, 'A0123', 'T036', 'TKR11', 'BUY',   6000, 102.50, '2026-11-06 11:42:10.000', 'FILLED', NULL),
(900004, 'A0124', 'T036', 'TKR11', 'SELL',  6000, 102.48, '2026-11-06 11:42:40.000', 'FILLED', NULL),
(900005, 'A0122', 'T031', 'TKR17', 'SELL',  9000, 147.50, '2026-11-06 13:05:00.000', 'FILLED', NULL),
(900006, 'A0121', 'T031', 'TKR17', 'BUY',   9000, 147.52, '2026-11-06 13:05:30.000', 'FILLED', NULL),
(900007, 'A0124', 'T036', 'TKR22', 'BUY',   7000, 185.00, '2026-11-06 14:20:00.000', 'FILLED', NULL),
(900008, 'A0123', 'T036', 'TKR22', 'SELL',  7000, 185.03, '2026-11-06 14:20:45.000', 'FILLED', NULL),

-- Spoofing: large orders placed and cancelled within seconds, then a real
-- order fills on the other side at the improved price
(900101, 'A0007', 'T007', 'TKR05', 'BUY',  15000,  57.45, '2026-11-06 10:48:00.000', 'CANCELLED', '2026-11-06 10:48:08.000'),
(900102, 'A0007', 'T007', 'TKR05', 'BUY',  15000,  57.44, '2026-11-06 10:48:02.000', 'CANCELLED', '2026-11-06 10:48:10.000'),
(900103, 'A0007', 'T007', 'TKR05', 'BUY',  20000,  57.43, '2026-11-06 10:48:04.000', 'CANCELLED', '2026-11-06 10:48:11.000'),
(900104, 'A0007', 'T007', 'TKR05', 'SELL',  3000,  57.55, '2026-11-06 10:48:13.000', 'FILLED',    NULL),

(900111, 'A0015', 'T015', 'TKR09', 'SELL', 12000,  87.60, '2026-11-06 12:31:10.000', 'CANCELLED', '2026-11-06 12:31:16.000'),
(900112, 'A0015', 'T015', 'TKR09', 'SELL', 12000,  87.61, '2026-11-06 12:31:11.500', 'CANCELLED', '2026-11-06 12:31:17.000'),
(900113, 'A0015', 'T015', 'TKR09', 'SELL', 12000,  87.62, '2026-11-06 12:31:13.000', 'CANCELLED', '2026-11-06 12:31:18.000'),
(900114, 'A0015', 'T015', 'TKR09', 'SELL', 12000,  87.63, '2026-11-06 12:31:14.500', 'CANCELLED', '2026-11-06 12:31:19.000'),
(900115, 'A0015', 'T015', 'TKR09', 'BUY',   2500,  87.40, '2026-11-06 12:31:21.000', 'FILLED',    NULL),

(900121, 'A0028', 'T028', 'TKR19', 'BUY',  18000, 162.40, '2026-11-06 14:02:30.000', 'CANCELLED', '2026-11-06 14:02:37.000'),
(900122, 'A0028', 'T028', 'TKR19', 'BUY',  18000, 162.39, '2026-11-06 14:02:31.000', 'CANCELLED', '2026-11-06 14:02:38.000'),
(900123, 'A0028', 'T028', 'TKR19', 'BUY',  18000, 162.38, '2026-11-06 14:02:32.000', 'CANCELLED', '2026-11-06 14:02:39.000'),
(900124, 'A0028', 'T028', 'TKR19', 'SELL',  4000, 162.70, '2026-11-06 14:02:45.000', 'FILLED',    NULL),

-- Front-running: the trader's PROP account trades just before a large CLIENT
-- order that the same trader is handling
(900201, 'A0012', 'T012', 'TKR02', 'BUY',   5000,  35.00, '2026-11-06 11:10:00.000', 'FILLED', NULL),
(900202, 'A0052', 'T012', 'TKR02', 'BUY',  25000,  35.05, '2026-11-06 11:11:00.000', 'FILLED', NULL),
(900211, 'A0024', 'T024', 'TKR14', 'SELL',  4000, 125.00, '2026-11-06 13:40:15.000', 'FILLED', NULL),
(900212, 'A0064', 'T024', 'TKR14', 'SELL', 30000, 124.90, '2026-11-06 13:41:30.000', 'FILLED', NULL),
(900221, 'A0033', 'T033', 'TKR24', 'BUY',   6000, 200.00, '2026-11-06 15:20:00.000', 'FILLED', NULL),
(900222, 'A0073', 'T033', 'TKR24', 'BUY',  22000, 200.10, '2026-11-06 15:21:40.000', 'FILLED', NULL);

-- Marking the close: one trader dominates volume in the final five minutes
INSERT INTO SURV_ORDERS
SELECT 900301 + SEQ4(), 'A0020', 'T020', 'TKR07', 'BUY', 5000, 72.60,
       DATEADD(SECOND, SEQ4() * 15, '2026-11-06 15:56:00'::TIMESTAMP_NTZ), 'FILLED', NULL
FROM TABLE(GENERATOR(ROWCOUNT => 16));

INSERT INTO SURV_ORDERS
SELECT 900401 + SEQ4(), 'A0038', 'T038', 'TKR13', 'SELL', 6000, 117.40,
       DATEADD(SECOND, SEQ4() * 15, '2026-11-06 15:57:00'::TIMESTAMP_NTZ), 'FILLED', NULL
FROM TABLE(GENERATOR(ROWCOUNT => 12));

-- Every FILLED order gets one execution, 0.2-3.2 seconds after it was placed
INSERT INTO SURV_EXECUTIONS
SELECT ORDER_ID, ORDER_ID,
       DATEADD(MILLISECOND, 200 + MOD(ABS(HASH(ORDER_ID, 'fill')), 3000), ORDER_TS),
       QTY, LIMIT_PRICE
FROM SURV_ORDERS
WHERE STATUS = 'FILLED';

SELECT
    (SELECT COUNT(*) FROM SURV_ORDERS)                          AS orders,
    (SELECT COUNT(*) FROM SURV_ORDERS WHERE STATUS = 'CANCELLED') AS cancelled,
    (SELECT COUNT(*) FROM SURV_EXECUTIONS)                      AS executions;

-- What an analyst sees without surveillance: an ordinary-looking blotter.
-- A spoofing case is hidden in here. Can you spot it?
SELECT o.ORDER_ID, o.ORDER_TS, o.TRADER_ID, o.ACCOUNT_ID, o.TICKER, o.SIDE, o.QTY, o.LIMIT_PRICE, o.STATUS
FROM SURV_ORDERS o
WHERE o.TICKER = 'TKR05'
  AND o.ORDER_TS BETWEEN '2026-11-06 10:47:40' AND '2026-11-06 10:48:20'
ORDER BY o.ORDER_TS;

-- [step:wash]
-- ============================================================================
-- STEP 5: RULE A - WASH TRADING
-- ============================================================================
-- A buy and a sell of the same instrument, between DIFFERENT accounts with the
-- SAME beneficial owner, similar size (5%) and price (0.5%), within 60 seconds.
-- No real change in ownership, just fake volume.

CREATE OR REPLACE VIEW SURV_RULE_WASH AS
WITH linked AS (
    SELECT a1.ACCOUNT_ID AS buy_account, a2.ACCOUNT_ID AS sell_account, a1.BENEFICIAL_OWNER
    FROM SURV_ACCOUNTS a1
    JOIN SURV_ACCOUNTS a2
      ON a1.BENEFICIAL_OWNER = a2.BENEFICIAL_OWNER
     AND a1.ACCOUNT_ID      <> a2.ACCOUNT_ID
)
SELECT
    'WASH_TRADE'                                                     AS rule,
    b.TRADER_ID                                                      AS trader_id,
    b.ACCOUNT_ID || ' / ' || s.ACCOUNT_ID                            AS account_id,
    b.TICKER                                                         AS ticker,
    LEAST(eb.EXEC_TS, es.EXEC_TS)                                    AS window_start,
    GREATEST(eb.EXEC_TS, es.EXEC_TS)                                 AS window_end,
    LEAST(100, 70 + ROUND(eb.EXEC_QTY * eb.EXEC_PRICE / 100000))     AS severity,
    'Bought and sold ' || eb.EXEC_QTY || ' ' || b.TICKER || ' '
        || ABS(DATEDIFF('second', eb.EXEC_TS, es.EXEC_TS))
        || 's apart between accounts with the same beneficial owner ('
        || l.BENEFICIAL_OWNER || ')'                                 AS explanation
FROM linked l
JOIN SURV_ORDERS     b  ON b.ACCOUNT_ID = l.buy_account  AND b.SIDE = 'BUY'
JOIN SURV_EXECUTIONS eb ON eb.ORDER_ID  = b.ORDER_ID
JOIN SURV_ORDERS     s  ON s.ACCOUNT_ID = l.sell_account AND s.SIDE = 'SELL' AND s.TICKER = b.TICKER
JOIN SURV_EXECUTIONS es ON es.ORDER_ID  = s.ORDER_ID
WHERE ABS(DATEDIFF('second', eb.EXEC_TS, es.EXEC_TS)) <= 60
  AND ABS(eb.EXEC_QTY   - es.EXEC_QTY)   <= 0.05  * eb.EXEC_QTY
  AND ABS(eb.EXEC_PRICE - es.EXEC_PRICE) <= 0.005 * eb.EXEC_PRICE;

SELECT * FROM SURV_RULE_WASH ORDER BY window_start;

-- [step:spoof]
-- ============================================================================
-- STEP 6: RULE B - SPOOFING / LAYERING (MATCH_RECOGNIZE)
-- ============================================================================
-- Per account and instrument, in time order, look for:
--   3 or more LARGE orders (10,000+) on one side, each cancelled within 10s
--   followed by a FILLED order on the OPPOSITE side within 30s.
-- The large orders create a false impression of demand; the real order
-- benefits from the moved price.

CREATE OR REPLACE VIEW SURV_RULE_SPOOF AS
SELECT
    'SPOOFING'                                                       AS rule,
    trader_id,
    account_id,
    ticker,
    window_start,
    window_end,
    LEAST(100, 80 + spoof_orders * 4)                                AS severity,
    spoof_orders || ' ' || spoof_side || ' orders totalling ' || spoof_qty
        || ' shares cancelled within seconds, then a ' || real_qty
        || '-share ' || real_side || ' filled '
        || DATEDIFF('second', window_start, window_end) || 's after the first order' AS explanation
FROM SURV_ORDERS
MATCH_RECOGNIZE (
    PARTITION BY account_id, ticker
    ORDER BY order_ts
    MEASURES
        FIRST(trader_id)                AS trader_id,
        FIRST(order_ts)                 AS window_start,
        LAST(order_ts)                  AS window_end,
        COUNT(*) - 1                    AS spoof_orders,
        SUM(qty) - LAST(qty)            AS spoof_qty,
        FIRST(side)                     AS spoof_side,
        LAST(qty)                       AS real_qty,
        LAST(side)                      AS real_side
    ONE ROW PER MATCH
    AFTER MATCH SKIP PAST LAST ROW
    -- three or more large cancelled BUYs then a filled SELL, or the reverse
    PATTERN ( spoof_buy{3,} fill_sell | spoof_sell{3,} fill_buy )
    DEFINE
        spoof_buy  AS side = 'BUY'  AND qty >= 10000 AND status = 'CANCELLED'
                  AND DATEDIFF('second', order_ts, cancel_ts) <= 10,
        spoof_sell AS side = 'SELL' AND qty >= 10000 AND status = 'CANCELLED'
                  AND DATEDIFF('second', order_ts, cancel_ts) <= 10,
        fill_sell  AS side = 'SELL' AND status = 'FILLED'
                  AND DATEDIFF('second', LAG(order_ts), order_ts) <= 30,
        fill_buy   AS side = 'BUY'  AND status = 'FILLED'
                  AND DATEDIFF('second', LAG(order_ts), order_ts) <= 30
);

SELECT * FROM SURV_RULE_SPOOF ORDER BY window_start;

-- [step:frontrun]
-- ============================================================================
-- STEP 7: RULE C - FRONT-RUNNING
-- ============================================================================
-- A large CLIENT order (20,000+) where the SAME trader's PROP account traded
-- the same instrument, in the same direction, in the 2 minutes before it.

CREATE OR REPLACE VIEW SURV_RULE_FRONTRUN AS
WITH client_orders AS (
    SELECT o.*
    FROM SURV_ORDERS o
    JOIN SURV_ACCOUNTS a ON a.ACCOUNT_ID = o.ACCOUNT_ID AND a.ACCOUNT_TYPE = 'CLIENT'
    WHERE o.QTY >= 20000
),
prop_fills AS (
    SELECT o.TRADER_ID, o.ACCOUNT_ID, o.TICKER, o.SIDE, e.EXEC_TS, e.EXEC_QTY
    FROM SURV_ORDERS o
    JOIN SURV_EXECUTIONS e ON e.ORDER_ID   = o.ORDER_ID
    JOIN SURV_ACCOUNTS   a ON a.ACCOUNT_ID = o.ACCOUNT_ID AND a.ACCOUNT_TYPE = 'PROP'
)
SELECT
    'FRONT_RUNNING'                                                  AS rule,
    c.TRADER_ID                                                      AS trader_id,
    MIN(p.ACCOUNT_ID) || ' ahead of ' || c.ACCOUNT_ID                AS account_id,
    c.TICKER                                                         AS ticker,
    MIN(p.EXEC_TS)                                                   AS window_start,
    c.ORDER_TS                                                       AS window_end,
    LEAST(100, 85 + ROUND(c.QTY / 5000))                             AS severity,
    'Prop account ' || LOWER(c.SIDE) || 's ' || SUM(p.EXEC_QTY) || ' ' || c.TICKER || ' '
        || DATEDIFF('second', MIN(p.EXEC_TS), c.ORDER_TS)
        || 's before a ' || c.QTY || '-share client ' || c.SIDE
        || ' order handled by the same trader'                       AS explanation
FROM client_orders c
JOIN prop_fills p
  ON p.TRADER_ID = c.TRADER_ID
 AND p.TICKER    = c.TICKER
 AND p.SIDE      = c.SIDE
 AND p.EXEC_TS   <  c.ORDER_TS
 AND p.EXEC_TS   >= DATEADD('second', -120, c.ORDER_TS)
GROUP BY c.TRADER_ID, c.ACCOUNT_ID, c.TICKER, c.SIDE, c.QTY, c.ORDER_TS;

SELECT * FROM SURV_RULE_FRONTRUN ORDER BY window_start;

-- [step:close]
-- ============================================================================
-- STEP 8: RULE D - MARKING THE CLOSE (Window functions + QUALIFY)
-- ============================================================================
-- In the final 5 minutes before the 16:00 close, flag any trader who executed
-- 20,000+ shares AND 30%+ of all volume in an instrument. Concentrated
-- end-of-day trading can push the closing price that valuations rely on.

CREATE OR REPLACE VIEW SURV_RULE_CLOSE AS
SELECT
    'MARKING_THE_CLOSE'                                              AS rule,
    o.TRADER_ID                                                      AS trader_id,
    MIN(o.ACCOUNT_ID)                                                AS account_id,
    o.TICKER                                                         AS ticker,
    MIN(e.EXEC_TS)                                                   AS window_start,
    MAX(e.EXEC_TS)                                                   AS window_end,
    LEAST(100, 60 + ROUND(SUM(e.EXEC_QTY)
          / SUM(SUM(e.EXEC_QTY)) OVER (PARTITION BY o.TICKER) * 40)) AS severity,
    'Executed ' || SUM(e.EXEC_QTY) || ' ' || o.TICKER || ' in the last 5 minutes = '
        || ROUND(SUM(e.EXEC_QTY) / SUM(SUM(e.EXEC_QTY)) OVER (PARTITION BY o.TICKER) * 100, 1)
        || '% of closing volume'                                     AS explanation
FROM SURV_EXECUTIONS e
JOIN SURV_ORDERS o ON o.ORDER_ID = e.ORDER_ID
WHERE e.EXEC_TS >= '2026-11-06 15:55:00'
  AND e.EXEC_TS <  '2026-11-06 16:00:00'
GROUP BY o.TRADER_ID, o.TICKER
QUALIFY SUM(e.EXEC_QTY) >= 20000
    AND SUM(e.EXEC_QTY) / SUM(SUM(e.EXEC_QTY)) OVER (PARTITION BY o.TICKER) >= 0.30;

SELECT * FROM SURV_RULE_CLOSE ORDER BY window_start;

-- [step:alerts]
-- ============================================================================
-- STEP 9: THE CONSOLIDATED ALERT QUEUE
-- ============================================================================

CREATE OR REPLACE VIEW SURV_ALERTS AS
WITH all_alerts AS (
    SELECT * FROM SURV_RULE_WASH
    UNION ALL SELECT * FROM SURV_RULE_SPOOF
    UNION ALL SELECT * FROM SURV_RULE_FRONTRUN
    UNION ALL SELECT * FROM SURV_RULE_CLOSE
)
SELECT
    DECODE(rule, 'WASH_TRADE', 'WSH', 'SPOOFING', 'SPF', 'FRONT_RUNNING', 'FRN', 'MTC')
        || '-' || LPAD(ROW_NUMBER() OVER (PARTITION BY rule ORDER BY window_start), 3, '0') AS alert_id,
    rule, severity, trader_id, account_id, ticker, window_start, window_end, explanation
FROM all_alerts;

-- The queue an analyst works from, highest severity first
SELECT alert_id, rule, severity, trader_id, ticker, window_start, explanation
FROM SURV_ALERTS
ORDER BY severity DESC, window_start;

-- Signal vs. noise: how much activity each rule reduces to a handful of alerts
SELECT
    r.rule,
    (SELECT COUNT(*) FROM SURV_ORDERS)                               AS orders_scanned,
    COUNT(a.alert_id)                                                AS alerts
FROM (SELECT column1 AS rule FROM VALUES ('WASH_TRADE'), ('SPOOFING'), ('FRONT_RUNNING'), ('MARKING_THE_CLOSE')) r
LEFT JOIN SURV_ALERTS a ON a.rule = r.rule
GROUP BY r.rule
ORDER BY alerts DESC;

-- [step:investigate]
-- ============================================================================
-- STEP 10: INVESTIGATE ONE CASE
-- ============================================================================
-- Drill from the highest-severity spoofing alert to the exact sequence of
-- orders, cancels and fills behind it.

SET (case_account, case_ticker, case_start, case_end) = (
    SELECT account_id, ticker, window_start, window_end
    FROM SURV_ALERTS WHERE rule = 'SPOOFING'
    ORDER BY severity DESC, window_start LIMIT 1
);

SELECT event_ts, event, side, qty, price, order_id
FROM (
    SELECT ORDER_TS AS event_ts, 'ORDER PLACED' AS event, SIDE, QTY, LIMIT_PRICE AS price, ORDER_ID
    FROM SURV_ORDERS
    WHERE ACCOUNT_ID = $case_account AND TICKER = $case_ticker
    UNION ALL
    SELECT CANCEL_TS, 'CANCELLED', SIDE, QTY, LIMIT_PRICE, ORDER_ID
    FROM SURV_ORDERS
    WHERE ACCOUNT_ID = $case_account AND TICKER = $case_ticker AND STATUS = 'CANCELLED'
    UNION ALL
    SELECT e.EXEC_TS, 'FILLED', o.SIDE, e.EXEC_QTY, e.EXEC_PRICE, o.ORDER_ID
    FROM SURV_EXECUTIONS e JOIN SURV_ORDERS o ON o.ORDER_ID = e.ORDER_ID
    WHERE o.ACCOUNT_ID = $case_account AND o.TICKER = $case_ticker
)
WHERE event_ts BETWEEN DATEADD('second', -5, $case_start::TIMESTAMP_NTZ)
                   AND DATEADD('second',  5, $case_end::TIMESTAMP_NTZ)
ORDER BY event_ts;

-- [step:dynamic]
-- ============================================================================
-- STEP 11: KEEP ALERTS FRESH WITH A DYNAMIC TABLE
-- ============================================================================
-- A Dynamic Table materializes alerts and refreshes them automatically within
-- TARGET_LAG of new orders arriving. No scheduler or task needed.
-- NOTE: Dynamic Tables don't support MATCH_RECOGNIZE, so this live table
-- covers the wash, front-running and marking-the-close rules. Spoofing stays
-- in the on-demand SURV_ALERTS view (or can be run by a scheduled task).

CREATE OR REPLACE DYNAMIC TABLE SURV_ALERTS_LIVE
    TARGET_LAG = '1 minute'
    WAREHOUSE  = SURV_WH
AS
SELECT rule, severity, trader_id, account_id, ticker, window_start, window_end, explanation FROM SURV_RULE_WASH
UNION ALL
SELECT rule, severity, trader_id, account_id, ticker, window_start, window_end, explanation FROM SURV_RULE_FRONTRUN
UNION ALL
SELECT rule, severity, trader_id, account_id, ticker, window_start, window_end, explanation FROM SURV_RULE_CLOSE;

SELECT rule, COUNT(*) AS alerts FROM SURV_ALERTS_LIVE GROUP BY rule ORDER BY rule;

-- New orders arrive: another wash trade between the linked accounts
INSERT INTO SURV_ORDERS VALUES
(900501, 'A0123', 'T036', 'TKR06', 'BUY',  5000, 65.00, '2026-11-06 15:30:00.000', 'FILLED', NULL),
(900502, 'A0124', 'T036', 'TKR06', 'SELL', 5000, 65.01, '2026-11-06 15:30:25.000', 'FILLED', NULL);
INSERT INTO SURV_EXECUTIONS VALUES
(900501, 900501, '2026-11-06 15:30:01.000', 5000, 65.00),
(900502, 900502, '2026-11-06 15:30:26.000', 5000, 65.01);

-- Within a minute the table refreshes on its own. To see it immediately:
ALTER DYNAMIC TABLE SURV_ALERTS_LIVE REFRESH;

SELECT rule, COUNT(*) AS alerts FROM SURV_ALERTS_LIVE GROUP BY rule ORDER BY rule;

-- Refresh history: when it ran and whether it was incremental or full
SELECT name, state, refresh_action, refresh_trigger, data_timestamp
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(NAME => 'SURV_DEMO_DB.SURVEILLANCE.SURV_ALERTS_LIVE'))
ORDER BY data_timestamp DESC
LIMIT 5;

-- Suspend it when you're done demoing, so it stops checking for changes
ALTER DYNAMIC TABLE SURV_ALERTS_LIVE SUSPEND;

-- [step:masking]
-- ============================================================================
-- STEP 12: (OPTIONAL, ENTERPRISE) PSEUDONYMIZED IDS FOR REVIEWERS
-- ============================================================================
-- Analysts see real trader and account IDs. A second-line reviewer sees
-- consistent pseudonyms: they can still group and compare alerts, but can't
-- identify the individual until the case is escalated.

CREATE ROLE IF NOT EXISTS SURV_ANALYST;
CREATE ROLE IF NOT EXISTS SURV_REVIEWER;
GRANT ROLE SURV_ANALYST  TO ROLE IDENTIFIER($demo_role);
GRANT ROLE SURV_REVIEWER TO ROLE IDENTIFIER($demo_role);

CREATE OR REPLACE MASKING POLICY surv_mask_id AS (val STRING) RETURNS STRING ->
    CASE
        WHEN CURRENT_ROLE() IN ('ACCOUNTADMIN', 'SURV_DEMO_ROLE', 'SURV_ANALYST') THEN val
        ELSE 'ID_' || UPPER(LEFT(SHA2(val), 8))
    END;

-- The full alert queue (all four rules) that both teams query
CREATE OR REPLACE VIEW SURV_ALERT_QUEUE AS
SELECT alert_id, rule, severity, trader_id, account_id, ticker, window_start, explanation
FROM SURV_ALERTS;

ALTER VIEW SURV_ALERT_QUEUE MODIFY COLUMN trader_id  SET MASKING POLICY surv_mask_id;
ALTER VIEW SURV_ALERT_QUEUE MODIFY COLUMN account_id SET MASKING POLICY surv_mask_id;

GRANT USAGE ON WAREHOUSE SURV_WH TO ROLE SURV_ANALYST;
GRANT USAGE ON WAREHOUSE SURV_WH TO ROLE SURV_REVIEWER;
GRANT USAGE ON DATABASE SURV_DEMO_DB TO ROLE SURV_ANALYST;
GRANT USAGE ON DATABASE SURV_DEMO_DB TO ROLE SURV_REVIEWER;
GRANT USAGE ON SCHEMA SURV_DEMO_DB.SURVEILLANCE TO ROLE SURV_ANALYST;
GRANT USAGE ON SCHEMA SURV_DEMO_DB.SURVEILLANCE TO ROLE SURV_REVIEWER;
GRANT SELECT ON VIEW SURV_DEMO_DB.SURVEILLANCE.SURV_ALERT_QUEUE TO ROLE SURV_ANALYST;
GRANT SELECT ON VIEW SURV_DEMO_DB.SURVEILLANCE.SURV_ALERT_QUEUE TO ROLE SURV_REVIEWER;

USE ROLE SURV_ANALYST;
SELECT alert_id, rule, trader_id, account_id, ticker
FROM SURV_DEMO_DB.SURVEILLANCE.SURV_ALERT_QUEUE ORDER BY alert_id LIMIT 5;

USE ROLE SURV_REVIEWER;
SELECT alert_id, rule, trader_id, account_id, ticker
FROM SURV_DEMO_DB.SURVEILLANCE.SURV_ALERT_QUEUE ORDER BY alert_id LIMIT 5;

USE ROLE IDENTIFIER($demo_role);

-- [step:cleanup]
-- ============================================================================
-- STEP 13: CLEANUP (Optional - uncomment to remove demo objects)
-- ============================================================================

-- USE ROLE IDENTIFIER($demo_role);
-- DROP DATABASE IF EXISTS SURV_DEMO_DB;     -- tables, views, Dynamic Table, policy
-- DROP WAREHOUSE IF EXISTS SURV_WH;
-- DROP ROLE IF EXISTS SURV_ANALYST;
-- DROP ROLE IF EXISTS SURV_REVIEWER;
-- UNSET (case_account, case_ticker, case_start, case_end, demo_role);
-- If you created the least-privilege role, an administrator removes it:
-- USE ROLE ACCOUNTADMIN;
-- DROP ROLE IF EXISTS SURV_DEMO_ROLE;
