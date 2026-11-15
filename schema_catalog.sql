-- schema_catalog.sql — the agent's view catalog (D1 resolved: middle path).
--
-- Apply once to an existing database:   sqlite3 facts.db < schema_catalog.sql
-- Or fold into schema.sql so rebuilds carry it. Requires v_latest_snapshot.
--
-- Convention: catalog views are LATEST-SCOPED, so the recommended query path
-- can never point at a fossil snapshot. Base tables (and the snapshot-keyed
-- views v_call_graph / v_table_access) remain available for history and M2
-- diffing.
--
-- Promotion ritual: any join written twice — by you or by the agent — gets a
-- name here. The catalog is the record of which questions turned out to
-- matter.

-- Q1 promoted: who writes which field of which table, columns resolved.
CREATE VIEW IF NOT EXISTS v_field_writes AS
    SELECT r.name            AS recipe_name,
           e.src_recipe_id   AS recipe_id,
           e.src_step_path   AS step_path,
           t.name            AS table_name,
           tf.field_name,
           tf.field_key
      FROM edges e
      JOIN v_latest_snapshot ls ON ls.snapshot_id = e.snapshot_id
      JOIN recipes r  ON r.snapshot_id = e.snapshot_id
                     AND r.recipe_id  = e.src_recipe_id
      JOIN tables t   ON t.snapshot_id = e.snapshot_id
                     AND t.table_id   = e.dst_id
      JOIN json_each(e.detail_json, '$.columns') c
      JOIN table_fields tf ON tf.snapshot_id = e.snapshot_id
                          AND tf.table_id   = e.dst_id
                          AND tf.field_key  = c.value
     WHERE e.kind = 'table_write';

-- Q2 promoted: every consumer of a resolved data-table field.
-- (Unresolved pills stay queryable in the datapills base table.)
CREATE VIEW IF NOT EXISTS v_datapill_consumers AS
    SELECT r.name       AS recipe_name,
           d.recipe_id,
           d.step_path,
           s.provider   AS step_provider,
           t.name       AS table_name,
           d.field_name,
           d.pill_path
      FROM datapills d
      JOIN v_latest_snapshot ls ON ls.snapshot_id = d.snapshot_id
      JOIN recipes r ON r.snapshot_id = d.snapshot_id
                    AND r.recipe_id  = d.recipe_id
 LEFT JOIN steps s   ON s.snapshot_id = d.snapshot_id
                    AND s.recipe_id  = d.recipe_id
                    AND s.step_path  = d.step_path
 LEFT JOIN tables t  ON t.snapshot_id = d.snapshot_id
                    AND t.table_id   = d.table_id
     WHERE d.field_name IS NOT NULL;

-- Q3's edge set: the call graph, latest snapshot only. Traversal itself is
-- query-authored (see the recursive-CTE pattern in corpus.py's docstring) —
-- that flexibility is the point of the middle path.
CREATE VIEW IF NOT EXISTS v_calls AS
    SELECT g.kind,
           g.src_recipe_id,
           g.src_recipe_name,
           g.src_step_path,
           g.dst_recipe_id,
           g.dst_recipe_name,
           g.resolved          -- 0 = target not in this snapshot: a finding
      FROM v_call_graph g
      JOIN v_latest_snapshot ls ON ls.snapshot_id = g.snapshot_id;

-- Latest table-access projection, same convention.
CREATE VIEW IF NOT EXISTS v_table_use AS
    SELECT a.kind,
           a.table_name,
           a.prefix_class,
           a.src_recipe_id AS recipe_id,
           a.recipe_name,
           a.src_step_path AS step_path
      FROM v_table_access a
      JOIN v_latest_snapshot ls ON ls.snapshot_id = a.snapshot_id;

-- Drift: recipes changed between the latest two snapshots. Only meaningful
-- when both snapshots share a derive version (check snapshots.notes).
CREATE VIEW IF NOT EXISTS v_recipe_drift AS
WITH latest AS (SELECT MAX(snapshot_id) AS s FROM snapshots),
     prev   AS (SELECT MAX(snapshot_id) AS s FROM snapshots
                 WHERE snapshot_id < (SELECT s FROM latest)),
     a AS (SELECT * FROM recipes WHERE snapshot_id=(SELECT s FROM prev)),
     b AS (SELECT * FROM recipes WHERE snapshot_id=(SELECT s FROM latest))
SELECT COALESCE(b.name, a.name) AS recipe,
       COALESCE(b.recipe_id, a.recipe_id) AS recipe_id,
       CASE WHEN a.recipe_id IS NULL THEN 'added'
            WHEN b.recipe_id IS NULL THEN 'removed'
            ELSE 'edited' END AS status
  FROM a FULL OUTER JOIN b ON a.recipe_id = b.recipe_id
 WHERE a.recipe_id IS NULL OR b.recipe_id IS NULL
    OR a.fingerprint <> b.fingerprint;

-- r4: every read of a step's output, tied to the step that produced it.
-- producer_step = 'trigger' means the recipe's own trigger (for a recipe
-- function: its declared parameters; for an API endpoint: the request).
-- When the producer is a call step, callee_id / callee_name say which recipe
-- was called, so "who reads <field> from calls to <recipe>" is one WHERE.
CREATE VIEW IF NOT EXISTS v_step_output_consumers AS
    SELECT r.name          AS recipe_name,
           d.recipe_id,
           d.step_path,
           d.src_step_path AS producer_step,
           CASE WHEN d.src_step_path = 'trigger' THEN r.trigger_provider
                ELSE p.provider END AS producer_provider,
           CASE WHEN d.src_step_path = 'trigger' THEN r.trigger_name
                ELSE p.name END     AS producer_action,
           c.dst_id        AS callee_id,
           c.dst_name      AS callee_name,
           d.pill_path
      FROM datapills d
      JOIN v_latest_snapshot ls ON ls.snapshot_id = d.snapshot_id
      JOIN recipes r ON r.snapshot_id = d.snapshot_id
                    AND r.recipe_id  = d.recipe_id
 LEFT JOIN steps p   ON p.snapshot_id = d.snapshot_id
                    AND p.recipe_id  = d.recipe_id
                    AND p.step_path  = d.src_step_path
 LEFT JOIN edges c   ON c.snapshot_id   = d.snapshot_id
                    AND c.src_recipe_id = d.recipe_id
                    AND c.src_step_path = d.src_step_path
                    AND c.kind IN ('call_sync', 'call_async')
     WHERE d.src_step_path IS NOT NULL;

-- r5: which fields a data-table read filters on.
CREATE VIEW IF NOT EXISTS v_field_filters AS
    SELECT r.name            AS recipe_name,
           e.src_recipe_id   AS recipe_id,
           e.src_step_path   AS step_path,
           t.name            AS table_name,
           tf.field_name,
           tf.field_key
      FROM edges e
      JOIN v_latest_snapshot ls ON ls.snapshot_id = e.snapshot_id
      JOIN recipes r  ON r.snapshot_id = e.snapshot_id
                     AND r.recipe_id  = e.src_recipe_id
      JOIN tables t   ON t.snapshot_id = e.snapshot_id
                     AND t.table_id   = e.dst_id
      JOIN json_each(e.detail_json, '$.filters') c
      JOIN table_fields tf ON tf.snapshot_id = e.snapshot_id
                          AND tf.table_id   = e.dst_id
                          AND tf.field_key  = c.value
     WHERE e.kind = 'table_read';

-- r5: Workflow Apps actions (create a request, change stage, complete a
-- task, share...). sets_stage = 1 when the step carries a stage; stage is
-- the literal stage id when it is not a datapill.
CREATE VIEW IF NOT EXISTS v_wfa_actions AS
    SELECT r.name          AS recipe_name,
           e.src_recipe_id AS recipe_id,
           e.src_step_path AS step_path,
           e.dst_name      AS action,
           json_extract(e.detail_json, '$.sets_stage') AS sets_stage,
           json_extract(e.detail_json, '$.stage')      AS stage
      FROM edges e
      JOIN v_latest_snapshot ls ON ls.snapshot_id = e.snapshot_id
      JOIN recipes r ON r.snapshot_id = e.snapshot_id
                    AND r.recipe_id  = e.src_recipe_id
     WHERE e.kind = 'wfa_action';

-- r5: what each recipe declares it takes and returns.
CREATE VIEW IF NOT EXISTS v_recipe_interface AS
    SELECT r.name AS recipe_name,
           io.recipe_id,
           io.direction,
           io.path,
           io.type,
           io.optional
      FROM recipe_io io
      JOIN v_latest_snapshot ls ON ls.snapshot_id = io.snapshot_id
      JOIN recipes r ON r.snapshot_id = io.snapshot_id
                    AND r.recipe_id  = io.recipe_id;

-- r5: one row per parameter a call site passes.
CREATE VIEW IF NOT EXISTS v_call_params AS
    SELECT rs.name         AS caller_name,
           e.src_recipe_id AS caller_id,
           e.src_step_path AS step_path,
           e.kind,
           e.dst_id        AS callee_id,
           COALESCE(rd.name, e.dst_name) AS callee_name,
           p.value         AS param
      FROM edges e
      JOIN v_latest_snapshot ls ON ls.snapshot_id = e.snapshot_id
      JOIN recipes rs ON rs.snapshot_id = e.snapshot_id
                     AND rs.recipe_id  = e.src_recipe_id
 LEFT JOIN recipes rd ON rd.snapshot_id = e.snapshot_id
                     AND rd.recipe_id  = e.dst_id
      JOIN json_each(e.detail_json, '$.params') p
     WHERE e.kind IN ('call_sync', 'call_async');

-- r5: where a caller and its callee disagree about the interface. Judged
-- only when the callee is in this snapshot. A read deeper than a declared
-- leaf is left alone (unknowable from the declaration).
CREATE VIEW IF NOT EXISTS v_contract_issues AS
    SELECT 'param_not_declared' AS issue,
           cp.caller_name, cp.caller_id, cp.step_path,
           cp.callee_name, cp.callee_id, cp.param AS field
      FROM v_call_params cp
     WHERE EXISTS (SELECT 1 FROM recipes r, v_latest_snapshot ls
                    WHERE r.snapshot_id = ls.snapshot_id
                      AND r.recipe_id = cp.callee_id)
       AND NOT EXISTS (SELECT 1 FROM v_recipe_interface i
                        WHERE i.recipe_id = cp.callee_id
                          AND i.direction = 'parameter'
                          AND i.path = cp.param)
    UNION ALL
    SELECT 'required_param_not_passed',
           rs.name, e.src_recipe_id, e.src_step_path,
           i.recipe_name, i.recipe_id, i.path
      FROM edges e
      JOIN v_latest_snapshot ls ON ls.snapshot_id = e.snapshot_id
      JOIN recipes rs ON rs.snapshot_id = e.snapshot_id
                     AND rs.recipe_id  = e.src_recipe_id
      JOIN v_recipe_interface i ON i.recipe_id = e.dst_id
                               AND i.direction = 'parameter'
                               AND i.optional = 0
                               AND instr(i.path, '.') = 0
     WHERE e.kind IN ('call_sync', 'call_async')
       AND NOT EXISTS (SELECT 1 FROM json_each(e.detail_json, '$.params') p
                        WHERE p.value = i.path)
    UNION ALL
    SELECT 'result_not_declared',
           c.recipe_name, c.recipe_id, c.step_path,
           c.callee_name, c.callee_id,
           replace(substr(c.pill_path, 8), '.[current_item]', '')
      FROM v_step_output_consumers c
     WHERE c.callee_id IS NOT NULL
       AND c.pill_path LIKE 'result.%'
       AND EXISTS (SELECT 1 FROM recipes r, v_latest_snapshot ls
                    WHERE r.snapshot_id = ls.snapshot_id
                      AND r.recipe_id = c.callee_id)
       AND NOT EXISTS (
             SELECT 1 FROM v_recipe_interface i
              WHERE i.recipe_id = c.callee_id
                AND i.direction = 'result'
                AND (   i.path = replace(substr(c.pill_path, 8), '.[current_item]', '')
                     OR i.path LIKE replace(substr(c.pill_path, 8), '.[current_item]', '') || '.%'
                     OR replace(substr(c.pill_path, 8), '.[current_item]', '') LIKE i.path || '.%'));
