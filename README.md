# Trade Surveillance and Market Abuse Detection

A customer-facing, step-by-step guide that detects suspicious trading in SQL, where the order data already lives:

- **Wash trading**: a self-join on beneficial ownership
- **Spoofing / layering**: sequence detection with `MATCH_RECOGNIZE`
- **Front-running**: time-window joins between prop and client flow
- **Marking the close**: window shares with `QUALIFY`
- **An explainable alert queue** with severity and a plain-English reason for every alert
- **A Dynamic Table** that refreshes alerts automatically as new orders arrive
- **Optional (Enterprise)**: pseudonymized trader and account IDs for second-line reviewers

**Live guide:** https://sfc-gh-jacho.github.io/sfguide-trade-surveillance/

The site is fully static and doesn't connect to any Snowflake account. Its result tables come from a real end-to-end run of the script on synthetic data.

## Prerequisites

- **Any edition** for Steps 1–11. **Enterprise Edition** for the optional masking step (12).
- **ACCOUNTADMIN**, or a role with `CREATE DATABASE`, `CREATE WAREHOUSE` and `CREATE ROLE` on the account.

## Run the demo in Snowsight

1. Download [`sql/trade_surveillance.sql`](sql/trade_surveillance.sql).
2. In Snowsight, open **Projects → Worksheets** and create a new SQL worksheet.
3. Paste the script and run it top to bottom in the same worksheet. Step 10 uses session variables. No find-and-replace is needed.
4. Step 11 suspends the Dynamic Table at the end. Leave it suspended, or drop it, when you're not demoing.
5. When you're done, uncomment and run Step 13 (Cleanup).

A full run takes a few minutes on an XSMALL warehouse and uses a fraction of a credit.

## What the run produces

- About 200,000 synthetic orders for one trading day, with 12 planted abusive patterns
- **12 alerts and no false positives**: 4 wash trades, 3 spoofing, 3 front-running, 2 marking the close
- The background flow is generated so it can't trip any rule. Orders are 100–2,000 shares, cancels happen 30 seconds or more after the order, and every account has its own beneficial owner.

## Known limitation

Dynamic Tables don't support `MATCH_RECOGNIZE`. The live `SURV_ALERTS_LIVE` table therefore covers the wash, front-running and marking-the-close rules. Spoofing is evaluated on demand in the `SURV_ALERTS` view, or it could run on a scheduled task.

## What gets created

| Object | Name |
|---|---|
| Database | `SURV_DEMO_DB` (schema `SURVEILLANCE`) |
| Warehouse | `SURV_WH` (XSMALL, 60 s auto-suspend) |
| Tables | `SURV_TRADERS`, `SURV_ACCOUNTS`, `SURV_INSTRUMENTS`, `SURV_ORDERS`, `SURV_EXECUTIONS` |
| Rule views | `SURV_RULE_WASH`, `SURV_RULE_SPOOF`, `SURV_RULE_FRONTRUN`, `SURV_RULE_CLOSE`, `SURV_ALERTS`, `SURV_ALERT_QUEUE` |
| Dynamic Table | `SURV_ALERTS_LIVE` (1-minute target lag; suspended at the end of Step 11) |
| Masking policy and roles (optional) | `surv_mask_id`, `SURV_ANALYST`, `SURV_REVIEWER` |

## Repository layout

```
index.html                    Single-page guide
styles.css                    Styling (Snowflake palette)
script.js                     Loads SQL steps, Prism highlighting, copy buttons, results tables
sql/trade_surveillance.sql    Full demo script (split into steps by "-- [step:<id>]" markers)
data/sample_results.json      Results captured from a real run
```

To preview locally: `python3 -m http.server 8000`

## Disclaimer

All traders, accounts, tickers (`TKR01`–`TKR25`) and trades are synthetic. The detection rules, thresholds and severity scores are illustrative. They are not production surveillance logic or regulatory guidance. The repository contains no credentials, account identifiers or connection details.
