# Trade Surveillance and Market Abuse Detection

**Owner:** Janet Cho · **Last reviewed:** November 2026 · **License:** [Apache 2.0](LICENSE)

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
- **A role to run it.** ACCOUNTADMIN is simplest in a sandbox. For regulated environments, use the least-privilege option below.

### Least-privilege option (no ACCOUNTADMIN)

The script starts with `SET demo_role = 'ACCOUNTADMIN';`. To run without ACCOUNTADMIN, an administrator runs the commented block at the top of Step 1 once:

```sql
USE ROLE ACCOUNTADMIN;
CREATE ROLE IF NOT EXISTS SURV_DEMO_ROLE;
GRANT CREATE DATABASE  ON ACCOUNT TO ROLE SURV_DEMO_ROLE;
GRANT CREATE WAREHOUSE ON ACCOUNT TO ROLE SURV_DEMO_ROLE;  -- or USAGE on an existing warehouse
GRANT CREATE ROLE      ON ACCOUNT TO ROLE SURV_DEMO_ROLE;  -- Step 12 (reviewer masking) only
GRANT ROLE SURV_DEMO_ROLE TO USER <YOUR_USER>;
```

Then change the first line to `SET demo_role = 'SURV_DEMO_ROLE';`. The analyst and reviewer roles from Step 12 are granted to the demo role instead of ACCOUNTADMIN. This path was tested end to end and produced identical results.

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

> **This is not a performance claim.** The 12 alerts are the 12 cases deliberately planted in synthetic data. The background flow is generated so it can't trip any rule: orders are 100–2,000 shares, cancels happen 30 seconds or more after the order, and every account has its own beneficial owner. On real order flow these rules will produce false positives and need tuning, backtesting and model validation like any surveillance logic.

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
LICENSE                       Apache License 2.0
vendor/prism/                 Prism.js (MIT), served locally
index.html                    Single-page guide
styles.css                    Styling (Snowflake palette)
script.js                     Loads SQL steps, Prism highlighting, copy buttons, results tables
sql/trade_surveillance.sql    Full demo script (split into steps by "-- [step:<id>]" markers)
data/sample_results.json      Results captured from a real run
```

To preview locally: `python3 -m http.server 8000`

## Customize with Cortex Code

[Cortex Code](https://docs.snowflake.com/en/user-guide/cortex-code/cortex-code) can adapt this guide to your own data. Open the repo folder in Cortex Code and try prompts like:

- "Adjust the spoofing and wash-trade thresholds for my order volumes and explain the trade-offs."
- "Map my orders and executions tables to SURV_ORDERS and SURV_EXECUTIONS, run the rules on one trading day, and summarize the alerts before creating anything permanent."
- "Add a layering rule that requires orders at three or more price levels, then show which planted spoofing cases it still catches."

Ask it to review the plan with you before it creates or changes any objects in your account.

## License

Licensed under the [Apache License, Version 2.0](LICENSE). Prism.js, used for syntax highlighting, is bundled in `vendor/prism/` under its own MIT license, so the pages make no third-party requests.

## Disclaimer

All traders, accounts, tickers (`TKR01`–`TKR25`) and trades are synthetic. The detection rules, thresholds and severity scores are illustrative. They are not production surveillance logic or regulatory guidance. The repository contains no credentials, account identifiers or connection details.
