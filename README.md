# sdc_agent — a queryable map of the Workato estate

## Overview

A read-only fact store over a snapshot of Workato recipes and data tables,
built so a person or an AI agent can investigate the estate by query instead
of by opening recipes one at a time.

    Workato Developer API → dump_recipes.py → snapshot folder
                          → derive.py       → facts.db (SQLite)
                          → corpus.py       → answers (JSON)

It answers questions such as: who calls this recipe and with which
parameters, who writes or filters on this table field, who reads a field
another recipe returns, which recipes act on Workflow Apps requests, what a
recipe declares it takes and returns, and where callers and callees disagree.

It never writes to Workato, and it reflects the snapshot it was built from,
not the live workspace.

## Getting started

On the dev VM (Git Bash, `python`):

    export PYTHONUTF8=1
    export WORKATO_API_TOKEN=...            # from the secrets tool, never a file here
    SNAP=dumps/snap_$(date -u +%Y%m%dT%H%M%SZ)

    python dump_recipes.py --folder <folder_id> --dest $SNAP

    # first time, and after any schema change: build an empty facts.db
    python -c "import sqlite3; c=sqlite3.connect('facts.db'); [c.executescript(open(f,encoding='utf-8').read()) for f in ('schema.sql','schema_catalog.sql')]"

    python derive.py --dumps $SNAP --manifest $SNAP/manifest.json --db facts.db --notes "$SNAP derive=r5"

    python corpus.py query "SELECT * FROM v_contract_issues"
    python corpus.py get-step <recipe_id> trigger

Each `derive.py` run adds a snapshot; queries read the latest one.

For Claude Code, add this to the project's `CLAUDE.md`:

    ## Workato estate tool
    Before answering questions about Workato recipes or data tables, read
    sdc_agent/BRIEF.md, then query the fact store:
      python sdc_agent/corpus.py --db sdc_agent/facts.db query "<SELECT ...>"
      python sdc_agent/corpus.py --db sdc_agent/facts.db get-step <recipe_id> <step_path>
    It is read-only and describes the snapshot named in `latest_snapshot`, not
    live Workato. Use it instead of opening files under dumps/.

## Authentication and connection

- Only `dump_recipes.py` connects to anything. It makes GET requests to the
  Workato Developer API with the bearer token in `WORKATO_API_TOKEN`.
- `WORKATO_API_BASE` selects the data center (default
  `https://www.workato.com`; EU is `https://app.eu.workato.com`).
- Behind Zscaler, if Python reports a certificate error, point
  `SSL_CERT_FILE` at the corporate CA bundle.
- `derive.py` and `corpus.py` need no credentials and no network.
- `corpus.py` opens `facts.db` read-only and accepts only SELECT and WITH.

## Prerequisites

- Python 3.9 or later; the four core scripts use the standard library only.
- SQLite 3.39 or later for `v_recipe_drift` (bundled with Python 3.12).
- A Workato API client whose token can read recipes and data tables in the
  target folder.
- `agent.py` and `app.py` (the Gemini loop and its Chainlit page) need
  `google-genai` and `chainlit`. Claude Code does not use them.

## Key actions

| Command | What it does |
|---|---|
| `dump_recipes.py --folder <id> --dest <dir>` | Writes one `.recipe.json` per recipe plus the data-table manifest. |
| `derive.py --dumps <dir> --manifest <dir>/manifest.json --db facts.db` | Adds a snapshot to `facts.db`. The only writer. |
| `corpus.py query "<sql>"` | Read-only SQL, capped at 200 rows, step inputs hidden. |
| `corpus.py get-step <recipe_id> <step_path>` | One step in full, including the trigger at `trigger`. |

| View | Question it answers |
|---|---|
| `v_calls`, `v_call_params` | Who calls whom, and which parameters each call passes. |
| `v_recipe_interface` | What a recipe declares it takes and returns. |
| `v_contract_issues` | Parameters passed but not declared, required ones not passed, result fields read but not declared. |
| `v_step_output_consumers` | Who reads a field produced by a step, a trigger, or a called recipe. |
| `v_table_use` | Who reads, writes, or is triggered by each table. |
| `v_field_writes`, `v_field_filters`, `v_datapill_consumers` | Who writes, filters on, or reads each table field. |
| `v_wfa_actions` | Which steps act on Workflow Apps requests, and whether they set a stage. |
| `v_recipe_drift` | Recipes added, removed or edited since the previous snapshot. |

`BRIEF.md` is the full guide to the tables and views, written for the agent.

## Error handling and telemetry

- `corpus.py` never raises to the caller: a bad query or a miss returns
  `{error, hint}`, and the exit code is 1.
- Every result carries `latest_snapshot`, `count` and `truncated`.
- `derive.py` commits once, at the end, so a failed run leaves nothing. Its
  report ends with counts of anything it could not resolve: call targets not
  in the snapshot, datapills not tied to a table field or to a step, and
  skipped files.
- `dump_recipes.py` records failures in `_manifest.json` and exits 1.
- `agent.py` writes one evidence file per question under `runs/`.

## Best practices

- Rebuild `facts.db` from scratch after any change to `schema.sql`; it is a
  pure derivation of the dumps.
- Tag each snapshot with the derive version (`derive=r5`) and compare only
  snapshots that share one.
- Prefer the catalog views to hand-written joins; when a join is written
  twice, add it to `schema_catalog.sql`.
- Take a snapshot before and after a change in the Workato editor, then read
  `v_recipe_drift` and `v_contract_issues` to confirm the change landed.
- Keep the token in the environment and keep `dumps/` and `facts.db` out of
  git; recipe exports can contain embedded credentials.

## Acknowledged risks and issues

- The files were recovered from chat transcripts and patched (see
  `RECOVERY_NOTES.md`); `dump_recipes.py` has not been run live since.
- All testing used a July 2026 dump of one folder. Current recipes may use
  shapes that dump did not contain.
- Data-table contents are not read, only structure and usage.
- Contract checks cover recipe-to-recipe calls. Callers outside Workato,
  such as Apps Script calling an API endpoint, are not in the snapshot.
- Workflow Apps coverage is limited to actions and stage-setting.
- `step_path` is positional, so inserting a step shifts its later siblings.
- One snapshot covers one folder in one workspace.
- Step inputs returned by `get_step` go to whichever model is asking. Check
  that is acceptable for recipes that hold customer or supplier details.
