-- The entire change-capture mechanism. One function, defined once, parameterized
-- per table through TG_ARGV:
--
--   TG_ARGV[0]  comma-separated column names to exclude from the diff
--   TG_ARGV[1]  the Rails model name to record as record_type ("Order")
--
-- Runs with the caller's privileges. `search_path` is pinned regardless, so the
-- function cannot be hijacked by an object shadowed into an earlier schema.
CREATE OR REPLACE FUNCTION public.audit_row_change() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $fn$
DECLARE
  excluded text[] := string_to_array(coalesce(TG_ARGV[0], ''), ',');
  model    text   := TG_ARGV[1];
  delta    jsonb;
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

  INSERT INTO audit_changes
    (request_id, record_type, record_id, operation, diff, changed_columns,
     actor_type, actor_id, actor_label)
  VALUES
    (rid, model, rec_id, left(TG_OP, 1), delta,
     ARRAY(SELECT jsonb_object_keys(delta)), atype, aid, alabel);

  RETURN NULL;  -- AFTER trigger; the return value is ignored
END;
$fn$;
