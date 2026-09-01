-- The entire change-capture mechanism. One function, defined once, parameterized
-- per table through TG_ARGV:
--
--   TG_ARGV[0]  comma-separated column names to exclude from the diff
--   TG_ARGV[1]  the Rails model name to record as record_type ("Order")
--   TG_ARGV[2]  comma-separated column names to record as `dimensions`, or
--               ABSENT entirely on a table that declared none (DESIGN §23)
--
-- Runs with the caller's privileges. `search_path` is pinned to pg_catalog and
-- the destination is written out in full, so the function cannot be hijacked by
-- an object shadowed into an earlier schema.
--
-- {{schema}} IS SUBSTITUTED AT INSTALL TIME with the schema the function is being
-- installed into, which for almost every application is `public`. It is not a
-- multi-tenancy feature; it is the absence of an assumption. A function pinned to
-- `public` writes to `public.audit_changes` no matter which schema its trigger
-- fired in -- so in an application whose search_path is not `public`, every row
-- lands in the wrong place and nothing says so. See AuditLog::Schema.
CREATE OR REPLACE FUNCTION {{schema}}.audit_row_change() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $fn$
DECLARE
  excluded text[] := string_to_array(coalesce(TG_ARGV[0], ''), ',');
  model    text   := TG_ARGV[1];
  delta    jsonb;
  dims     jsonb;   -- NULL unless TG_ARGV[2] is present; see the block below
  rowdata  jsonb;
  rec_id   bigint;
  rid      uuid;
  atype    text;
  aid      bigint;
  alabel   text;
BEGIN
  -- Explicit, self-logging bypass for bulk loads. See AuditLog::Bypass.
  IF coalesce(current_setting('audit.bypass', true), 'off') = 'on' THEN
    RETURN NULL;
  END IF;

  rid    := nullif(current_setting('audit.request_id',  true), '')::uuid;
  atype  := nullif(current_setting('audit.actor_type',  true), '');
  aid    := nullif(current_setting('audit.actor_id',    true), '')::bigint;
  alabel := left(nullif(current_setting('audit.actor_label', true), ''), 255);

  IF TG_OP = 'UPDATE' THEN
    SELECT jsonb_object_agg(n.key, jsonb_build_array(o.value, n.value))
      INTO delta
      FROM jsonb_each(to_jsonb(OLD)) o
      JOIN jsonb_each(to_jsonb(NEW)) n USING (key)
     WHERE o.value IS DISTINCT FROM n.value
       AND NOT (n.key = ANY (excluded));

    -- A save that changed nothing but updated_at writes nothing at all.
    IF delta IS NULL THEN RETURN NULL; END IF;
    rec_id := NEW.id;

  ELSIF TG_OP = 'INSERT' THEN
    SELECT jsonb_object_agg(key, jsonb_build_array(NULL, value))
      INTO delta
      FROM jsonb_each(to_jsonb(NEW))
     WHERE NOT (key = ANY (excluded));
    rec_id := NEW.id;

  ELSE  -- DELETE: snapshot the full final state, so the record survives its row.
    SELECT jsonb_object_agg(key, jsonb_build_array(value, NULL))
      INTO delta
      FROM jsonb_each(to_jsonb(OLD))
     WHERE NOT (key = ANY (excluded));
    rec_id := OLD.id;
  END IF;

  delta := coalesce(delta, '{}'::jsonb);

  -- HOST-DEFINED FACETS (DESIGN §23). A TABLE THAT DECLARES NONE PAYS NOTHING:
  -- one function serves every audited table in the schema, so the whole
  -- extraction sits behind this guard and nothing above it changed. Measured on
  -- 18.6 at 200k rows a leg, seven paired trials with the order alternated: the
  -- delta ranges -4.2% to +14.5% and CHANGES SIGN, mean +2.3%, minimum -1.8% --
  -- the guard is below this machine's noise floor.
  IF TG_ARGV[2] IS NOT NULL THEN
    -- OLD on a delete, because a deleted invoice's final department is exactly
    -- how somebody goes looking for it.
    rowdata := CASE WHEN TG_OP = 'DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;

    -- ->> gives TEXT, and text is the stored shape on purpose: {"customer_id": 5}
    -- and {"customer_id": "5"} do not match under @> and the symptom is an empty
    -- screen. AuditLog::Record.where_dimensions is the one normalisation point on
    -- the read side, so no caller can get it wrong, and a host writing SQL by hand
    -- still has `dimensions->>'customer_id' = '5'` working.
    --
    -- SCALAR, never an OLD-union-NEW array. Containment has array semantics so an
    -- array would work, and it would break the guessable query:
    -- `dimensions @> '{"department_id":"5"}'` returns NOTHING against an
    -- array-valued column, silently, in a feature whose whole premise is
    -- convenient ad-hoc querying. The cost is that a row is filed under the value
    -- it held AFTER the change, so departures are not captured -- and nothing is
    -- lost from the RECORD, because the move writes an ordinary change row whose
    -- `diff` holds [old, new] as a real jsonb array.
    --
    -- NULLS ARE SKIPPED, so jsonb_object_agg over no surviving key yields NULL
    -- rather than '{}' -- which is what the partial GIN index excludes on, and
    -- what keeps "never recorded" distinguishable from "recorded, empty".
    SELECT jsonb_object_agg(k, rowdata ->> k)
      INTO dims
      FROM unnest(string_to_array(TG_ARGV[2], ',')) AS t(k)
     WHERE rowdata ->> k IS NOT NULL;
  END IF;

  INSERT INTO {{schema}}.audit_changes
    (request_id, record_type, record_id, operation, diff, changed_columns,
     actor_type, actor_id, actor_label, dimensions)
  VALUES
    (rid, model, rec_id, left(TG_OP, 1), delta,
     ARRAY(SELECT jsonb_object_keys(delta)), atype, aid, alabel, dims);

  RETURN NULL;  -- AFTER trigger; the return value is ignored
END;
$fn$;
