SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: audit_row_change(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.audit_row_change() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public'
    AS $$
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
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: audit_changes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_changes (
    id bigint NOT NULL,
    occurred_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    request_id uuid,
    record_type text NOT NULL,
    record_id bigint NOT NULL,
    operation character(1) NOT NULL,
    diff jsonb NOT NULL,
    changed_columns text[] NOT NULL,
    actor_type text,
    actor_id bigint,
    actor_label text,
    CONSTRAINT audit_changes_operation_check CHECK ((operation = ANY (ARRAY['I'::bpchar, 'U'::bpchar, 'D'::bpchar])))
)
PARTITION BY RANGE (occurred_at);


--
-- Name: audit_changes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.audit_changes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: audit_changes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.audit_changes_id_seq OWNED BY public.audit_changes.id;


--
-- Name: audit_changes_2026_07; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_changes_2026_07 (
    id bigint DEFAULT nextval('public.audit_changes_id_seq'::regclass) CONSTRAINT audit_changes_id_not_null NOT NULL,
    occurred_at timestamp with time zone DEFAULT clock_timestamp() CONSTRAINT audit_changes_occurred_at_not_null NOT NULL,
    request_id uuid,
    record_type text CONSTRAINT audit_changes_record_type_not_null NOT NULL,
    record_id bigint CONSTRAINT audit_changes_record_id_not_null NOT NULL,
    operation character(1) CONSTRAINT audit_changes_operation_not_null NOT NULL,
    diff jsonb CONSTRAINT audit_changes_diff_not_null NOT NULL,
    changed_columns text[] CONSTRAINT audit_changes_changed_columns_not_null NOT NULL,
    actor_type text,
    actor_id bigint,
    actor_label text,
    CONSTRAINT audit_changes_operation_check CHECK ((operation = ANY (ARRAY['I'::bpchar, 'U'::bpchar, 'D'::bpchar])))
);


--
-- Name: audit_changes_2026_08; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_changes_2026_08 (
    id bigint DEFAULT nextval('public.audit_changes_id_seq'::regclass) CONSTRAINT audit_changes_id_not_null NOT NULL,
    occurred_at timestamp with time zone DEFAULT clock_timestamp() CONSTRAINT audit_changes_occurred_at_not_null NOT NULL,
    request_id uuid,
    record_type text CONSTRAINT audit_changes_record_type_not_null NOT NULL,
    record_id bigint CONSTRAINT audit_changes_record_id_not_null NOT NULL,
    operation character(1) CONSTRAINT audit_changes_operation_not_null NOT NULL,
    diff jsonb CONSTRAINT audit_changes_diff_not_null NOT NULL,
    changed_columns text[] CONSTRAINT audit_changes_changed_columns_not_null NOT NULL,
    actor_type text,
    actor_id bigint,
    actor_label text,
    CONSTRAINT audit_changes_operation_check CHECK ((operation = ANY (ARRAY['I'::bpchar, 'U'::bpchar, 'D'::bpchar])))
);


--
-- Name: audit_changes_2026_09; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_changes_2026_09 (
    id bigint DEFAULT nextval('public.audit_changes_id_seq'::regclass) CONSTRAINT audit_changes_id_not_null NOT NULL,
    occurred_at timestamp with time zone DEFAULT clock_timestamp() CONSTRAINT audit_changes_occurred_at_not_null NOT NULL,
    request_id uuid,
    record_type text CONSTRAINT audit_changes_record_type_not_null NOT NULL,
    record_id bigint CONSTRAINT audit_changes_record_id_not_null NOT NULL,
    operation character(1) CONSTRAINT audit_changes_operation_not_null NOT NULL,
    diff jsonb CONSTRAINT audit_changes_diff_not_null NOT NULL,
    changed_columns text[] CONSTRAINT audit_changes_changed_columns_not_null NOT NULL,
    actor_type text,
    actor_id bigint,
    actor_label text,
    CONSTRAINT audit_changes_operation_check CHECK ((operation = ANY (ARRAY['I'::bpchar, 'U'::bpchar, 'D'::bpchar])))
);


--
-- Name: audit_changes_2026_10; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_changes_2026_10 (
    id bigint DEFAULT nextval('public.audit_changes_id_seq'::regclass) CONSTRAINT audit_changes_id_not_null NOT NULL,
    occurred_at timestamp with time zone DEFAULT clock_timestamp() CONSTRAINT audit_changes_occurred_at_not_null NOT NULL,
    request_id uuid,
    record_type text CONSTRAINT audit_changes_record_type_not_null NOT NULL,
    record_id bigint CONSTRAINT audit_changes_record_id_not_null NOT NULL,
    operation character(1) CONSTRAINT audit_changes_operation_not_null NOT NULL,
    diff jsonb CONSTRAINT audit_changes_diff_not_null NOT NULL,
    changed_columns text[] CONSTRAINT audit_changes_changed_columns_not_null NOT NULL,
    actor_type text,
    actor_id bigint,
    actor_label text,
    CONSTRAINT audit_changes_operation_check CHECK ((operation = ANY (ARRAY['I'::bpchar, 'U'::bpchar, 'D'::bpchar])))
);


--
-- Name: audit_changes_2026_11; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_changes_2026_11 (
    id bigint DEFAULT nextval('public.audit_changes_id_seq'::regclass) CONSTRAINT audit_changes_id_not_null NOT NULL,
    occurred_at timestamp with time zone DEFAULT clock_timestamp() CONSTRAINT audit_changes_occurred_at_not_null NOT NULL,
    request_id uuid,
    record_type text CONSTRAINT audit_changes_record_type_not_null NOT NULL,
    record_id bigint CONSTRAINT audit_changes_record_id_not_null NOT NULL,
    operation character(1) CONSTRAINT audit_changes_operation_not_null NOT NULL,
    diff jsonb CONSTRAINT audit_changes_diff_not_null NOT NULL,
    changed_columns text[] CONSTRAINT audit_changes_changed_columns_not_null NOT NULL,
    actor_type text,
    actor_id bigint,
    actor_label text,
    CONSTRAINT audit_changes_operation_check CHECK ((operation = ANY (ARRAY['I'::bpchar, 'U'::bpchar, 'D'::bpchar])))
);


--
-- Name: audit_changes_default; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_changes_default (
    id bigint DEFAULT nextval('public.audit_changes_id_seq'::regclass) CONSTRAINT audit_changes_id_not_null NOT NULL,
    occurred_at timestamp with time zone DEFAULT clock_timestamp() CONSTRAINT audit_changes_occurred_at_not_null NOT NULL,
    request_id uuid,
    record_type text CONSTRAINT audit_changes_record_type_not_null NOT NULL,
    record_id bigint CONSTRAINT audit_changes_record_id_not_null NOT NULL,
    operation character(1) CONSTRAINT audit_changes_operation_not_null NOT NULL,
    diff jsonb CONSTRAINT audit_changes_diff_not_null NOT NULL,
    changed_columns text[] CONSTRAINT audit_changes_changed_columns_not_null NOT NULL,
    actor_type text,
    actor_id bigint,
    actor_label text,
    CONSTRAINT audit_changes_operation_check CHECK ((operation = ANY (ARRAY['I'::bpchar, 'U'::bpchar, 'D'::bpchar])))
);


--
-- Name: audit_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_events (
    id bigint NOT NULL,
    occurred_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    request_id uuid NOT NULL,
    action text NOT NULL,
    actor_type text,
    actor_id bigint,
    actor_label text,
    subject_type text,
    subject_id bigint,
    caused_by_request_id uuid,
    source text NOT NULL,
    ip inet,
    user_agent text,
    summary text NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL
)
PARTITION BY RANGE (occurred_at);


--
-- Name: audit_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.audit_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: audit_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.audit_events_id_seq OWNED BY public.audit_events.id;


--
-- Name: audit_events_2026_07; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_events_2026_07 (
    id bigint DEFAULT nextval('public.audit_events_id_seq'::regclass) CONSTRAINT audit_events_id_not_null NOT NULL,
    occurred_at timestamp with time zone DEFAULT clock_timestamp() CONSTRAINT audit_events_occurred_at_not_null NOT NULL,
    request_id uuid CONSTRAINT audit_events_request_id_not_null NOT NULL,
    action text CONSTRAINT audit_events_action_not_null NOT NULL,
    actor_type text,
    actor_id bigint,
    actor_label text,
    subject_type text,
    subject_id bigint,
    caused_by_request_id uuid,
    source text CONSTRAINT audit_events_source_not_null NOT NULL,
    ip inet,
    user_agent text,
    summary text CONSTRAINT audit_events_summary_not_null NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb CONSTRAINT audit_events_metadata_not_null NOT NULL
);


--
-- Name: audit_events_2026_08; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_events_2026_08 (
    id bigint DEFAULT nextval('public.audit_events_id_seq'::regclass) CONSTRAINT audit_events_id_not_null NOT NULL,
    occurred_at timestamp with time zone DEFAULT clock_timestamp() CONSTRAINT audit_events_occurred_at_not_null NOT NULL,
    request_id uuid CONSTRAINT audit_events_request_id_not_null NOT NULL,
    action text CONSTRAINT audit_events_action_not_null NOT NULL,
    actor_type text,
    actor_id bigint,
    actor_label text,
    subject_type text,
    subject_id bigint,
    caused_by_request_id uuid,
    source text CONSTRAINT audit_events_source_not_null NOT NULL,
    ip inet,
    user_agent text,
    summary text CONSTRAINT audit_events_summary_not_null NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb CONSTRAINT audit_events_metadata_not_null NOT NULL
);


--
-- Name: audit_events_2026_09; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_events_2026_09 (
    id bigint DEFAULT nextval('public.audit_events_id_seq'::regclass) CONSTRAINT audit_events_id_not_null NOT NULL,
    occurred_at timestamp with time zone DEFAULT clock_timestamp() CONSTRAINT audit_events_occurred_at_not_null NOT NULL,
    request_id uuid CONSTRAINT audit_events_request_id_not_null NOT NULL,
    action text CONSTRAINT audit_events_action_not_null NOT NULL,
    actor_type text,
    actor_id bigint,
    actor_label text,
    subject_type text,
    subject_id bigint,
    caused_by_request_id uuid,
    source text CONSTRAINT audit_events_source_not_null NOT NULL,
    ip inet,
    user_agent text,
    summary text CONSTRAINT audit_events_summary_not_null NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb CONSTRAINT audit_events_metadata_not_null NOT NULL
);


--
-- Name: audit_events_2026_10; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_events_2026_10 (
    id bigint DEFAULT nextval('public.audit_events_id_seq'::regclass) CONSTRAINT audit_events_id_not_null NOT NULL,
    occurred_at timestamp with time zone DEFAULT clock_timestamp() CONSTRAINT audit_events_occurred_at_not_null NOT NULL,
    request_id uuid CONSTRAINT audit_events_request_id_not_null NOT NULL,
    action text CONSTRAINT audit_events_action_not_null NOT NULL,
    actor_type text,
    actor_id bigint,
    actor_label text,
    subject_type text,
    subject_id bigint,
    caused_by_request_id uuid,
    source text CONSTRAINT audit_events_source_not_null NOT NULL,
    ip inet,
    user_agent text,
    summary text CONSTRAINT audit_events_summary_not_null NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb CONSTRAINT audit_events_metadata_not_null NOT NULL
);


--
-- Name: audit_events_2026_11; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_events_2026_11 (
    id bigint DEFAULT nextval('public.audit_events_id_seq'::regclass) CONSTRAINT audit_events_id_not_null NOT NULL,
    occurred_at timestamp with time zone DEFAULT clock_timestamp() CONSTRAINT audit_events_occurred_at_not_null NOT NULL,
    request_id uuid CONSTRAINT audit_events_request_id_not_null NOT NULL,
    action text CONSTRAINT audit_events_action_not_null NOT NULL,
    actor_type text,
    actor_id bigint,
    actor_label text,
    subject_type text,
    subject_id bigint,
    caused_by_request_id uuid,
    source text CONSTRAINT audit_events_source_not_null NOT NULL,
    ip inet,
    user_agent text,
    summary text CONSTRAINT audit_events_summary_not_null NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb CONSTRAINT audit_events_metadata_not_null NOT NULL
);


--
-- Name: audit_events_default; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_events_default (
    id bigint DEFAULT nextval('public.audit_events_id_seq'::regclass) CONSTRAINT audit_events_id_not_null NOT NULL,
    occurred_at timestamp with time zone DEFAULT clock_timestamp() CONSTRAINT audit_events_occurred_at_not_null NOT NULL,
    request_id uuid CONSTRAINT audit_events_request_id_not_null NOT NULL,
    action text CONSTRAINT audit_events_action_not_null NOT NULL,
    actor_type text,
    actor_id bigint,
    actor_label text,
    subject_type text,
    subject_id bigint,
    caused_by_request_id uuid,
    source text CONSTRAINT audit_events_source_not_null NOT NULL,
    ip inet,
    user_agent text,
    summary text CONSTRAINT audit_events_summary_not_null NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb CONSTRAINT audit_events_metadata_not_null NOT NULL
);


--
-- Name: customers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.customers (
    id bigint NOT NULL,
    name character varying NOT NULL,
    email character varying,
    phone character varying,
    status character varying DEFAULT 'active'::character varying NOT NULL,
    notes text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: customers_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.customers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: customers_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.customers_id_seq OWNED BY public.customers.id;


--
-- Name: line_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.line_items (
    id bigint NOT NULL,
    order_id bigint NOT NULL,
    product_id bigint NOT NULL,
    quantity integer DEFAULT 1 NOT NULL,
    unit_price_cents integer DEFAULT 0 NOT NULL,
    description character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: line_items_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.line_items_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: line_items_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.line_items_id_seq OWNED BY public.line_items.id;


--
-- Name: orders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.orders (
    id bigint NOT NULL,
    customer_id bigint NOT NULL,
    created_by_id bigint,
    reference character varying NOT NULL,
    status character varying DEFAULT 'draft'::character varying NOT NULL,
    total_cents integer DEFAULT 0 NOT NULL,
    notes text,
    submitted_at timestamp(6) without time zone,
    approved_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: orders_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.orders_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: orders_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.orders_id_seq OWNED BY public.orders.id;


--
-- Name: products; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.products (
    id bigint NOT NULL,
    sku character varying NOT NULL,
    name character varying NOT NULL,
    description text,
    price_cents integer DEFAULT 0 NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: products_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.products_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: products_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.products_id_seq OWNED BY public.products.id;


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: shipments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shipments (
    id bigint NOT NULL,
    order_id bigint NOT NULL,
    carrier character varying,
    tracking_number character varying,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    shipped_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: shipments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.shipments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: shipments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.shipments_id_seq OWNED BY public.shipments.id;


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id bigint NOT NULL,
    name character varying NOT NULL,
    email character varying NOT NULL,
    role character varying DEFAULT 'staff'::character varying NOT NULL,
    encrypted_password character varying,
    reset_password_token character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: users_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.users_id_seq OWNED BY public.users.id;


--
-- Name: audit_changes_2026_07; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_changes ATTACH PARTITION public.audit_changes_2026_07 FOR VALUES FROM ('2026-07-01 00:00:00+00') TO ('2026-08-01 00:00:00+00');


--
-- Name: audit_changes_2026_08; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_changes ATTACH PARTITION public.audit_changes_2026_08 FOR VALUES FROM ('2026-08-01 00:00:00+00') TO ('2026-09-01 00:00:00+00');


--
-- Name: audit_changes_2026_09; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_changes ATTACH PARTITION public.audit_changes_2026_09 FOR VALUES FROM ('2026-09-01 00:00:00+00') TO ('2026-10-01 00:00:00+00');


--
-- Name: audit_changes_2026_10; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_changes ATTACH PARTITION public.audit_changes_2026_10 FOR VALUES FROM ('2026-10-01 00:00:00+00') TO ('2026-11-01 00:00:00+00');


--
-- Name: audit_changes_2026_11; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_changes ATTACH PARTITION public.audit_changes_2026_11 FOR VALUES FROM ('2026-11-01 00:00:00+00') TO ('2026-12-01 00:00:00+00');


--
-- Name: audit_changes_default; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_changes ATTACH PARTITION public.audit_changes_default DEFAULT;


--
-- Name: audit_events_2026_07; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events ATTACH PARTITION public.audit_events_2026_07 FOR VALUES FROM ('2026-07-01 00:00:00+00') TO ('2026-08-01 00:00:00+00');


--
-- Name: audit_events_2026_08; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events ATTACH PARTITION public.audit_events_2026_08 FOR VALUES FROM ('2026-08-01 00:00:00+00') TO ('2026-09-01 00:00:00+00');


--
-- Name: audit_events_2026_09; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events ATTACH PARTITION public.audit_events_2026_09 FOR VALUES FROM ('2026-09-01 00:00:00+00') TO ('2026-10-01 00:00:00+00');


--
-- Name: audit_events_2026_10; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events ATTACH PARTITION public.audit_events_2026_10 FOR VALUES FROM ('2026-10-01 00:00:00+00') TO ('2026-11-01 00:00:00+00');


--
-- Name: audit_events_2026_11; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events ATTACH PARTITION public.audit_events_2026_11 FOR VALUES FROM ('2026-11-01 00:00:00+00') TO ('2026-12-01 00:00:00+00');


--
-- Name: audit_events_default; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events ATTACH PARTITION public.audit_events_default DEFAULT;


--
-- Name: audit_changes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_changes ALTER COLUMN id SET DEFAULT nextval('public.audit_changes_id_seq'::regclass);


--
-- Name: audit_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events ALTER COLUMN id SET DEFAULT nextval('public.audit_events_id_seq'::regclass);


--
-- Name: customers id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customers ALTER COLUMN id SET DEFAULT nextval('public.customers_id_seq'::regclass);


--
-- Name: line_items id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.line_items ALTER COLUMN id SET DEFAULT nextval('public.line_items_id_seq'::regclass);


--
-- Name: orders id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders ALTER COLUMN id SET DEFAULT nextval('public.orders_id_seq'::regclass);


--
-- Name: products id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products ALTER COLUMN id SET DEFAULT nextval('public.products_id_seq'::regclass);


--
-- Name: shipments id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shipments ALTER COLUMN id SET DEFAULT nextval('public.shipments_id_seq'::regclass);


--
-- Name: users id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users ALTER COLUMN id SET DEFAULT nextval('public.users_id_seq'::regclass);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: audit_changes audit_changes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_changes
    ADD CONSTRAINT audit_changes_pkey PRIMARY KEY (id, occurred_at);


--
-- Name: audit_changes_2026_07 audit_changes_2026_07_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_changes_2026_07
    ADD CONSTRAINT audit_changes_2026_07_pkey PRIMARY KEY (id, occurred_at);


--
-- Name: audit_changes_2026_08 audit_changes_2026_08_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_changes_2026_08
    ADD CONSTRAINT audit_changes_2026_08_pkey PRIMARY KEY (id, occurred_at);


--
-- Name: audit_changes_2026_09 audit_changes_2026_09_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_changes_2026_09
    ADD CONSTRAINT audit_changes_2026_09_pkey PRIMARY KEY (id, occurred_at);


--
-- Name: audit_changes_2026_10 audit_changes_2026_10_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_changes_2026_10
    ADD CONSTRAINT audit_changes_2026_10_pkey PRIMARY KEY (id, occurred_at);


--
-- Name: audit_changes_2026_11 audit_changes_2026_11_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_changes_2026_11
    ADD CONSTRAINT audit_changes_2026_11_pkey PRIMARY KEY (id, occurred_at);


--
-- Name: audit_changes_default audit_changes_default_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_changes_default
    ADD CONSTRAINT audit_changes_default_pkey PRIMARY KEY (id, occurred_at);


--
-- Name: audit_events audit_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT audit_events_pkey PRIMARY KEY (id, occurred_at);


--
-- Name: audit_events_2026_07 audit_events_2026_07_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events_2026_07
    ADD CONSTRAINT audit_events_2026_07_pkey PRIMARY KEY (id, occurred_at);


--
-- Name: audit_events_2026_08 audit_events_2026_08_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events_2026_08
    ADD CONSTRAINT audit_events_2026_08_pkey PRIMARY KEY (id, occurred_at);


--
-- Name: audit_events_2026_09 audit_events_2026_09_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events_2026_09
    ADD CONSTRAINT audit_events_2026_09_pkey PRIMARY KEY (id, occurred_at);


--
-- Name: audit_events_2026_10 audit_events_2026_10_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events_2026_10
    ADD CONSTRAINT audit_events_2026_10_pkey PRIMARY KEY (id, occurred_at);


--
-- Name: audit_events_2026_11 audit_events_2026_11_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events_2026_11
    ADD CONSTRAINT audit_events_2026_11_pkey PRIMARY KEY (id, occurred_at);


--
-- Name: audit_events_default audit_events_default_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events_default
    ADD CONSTRAINT audit_events_default_pkey PRIMARY KEY (id, occurred_at);


--
-- Name: customers customers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_pkey PRIMARY KEY (id);


--
-- Name: line_items line_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.line_items
    ADD CONSTRAINT line_items_pkey PRIMARY KEY (id);


--
-- Name: orders orders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_pkey PRIMARY KEY (id);


--
-- Name: products products_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: shipments shipments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shipments
    ADD CONSTRAINT shipments_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: audit_changes_actor_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_changes_actor_idx ON ONLY public.audit_changes USING btree (actor_type, actor_id, occurred_at DESC);


--
-- Name: audit_changes_2026_07_actor_type_actor_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_changes_2026_07_actor_type_actor_id_occurred_at_idx ON public.audit_changes_2026_07 USING btree (actor_type, actor_id, occurred_at DESC);


--
-- Name: audit_changes_changed_columns_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_changes_changed_columns_idx ON ONLY public.audit_changes USING gin (changed_columns);


--
-- Name: audit_changes_2026_07_changed_columns_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_changes_2026_07_changed_columns_idx ON public.audit_changes_2026_07 USING gin (changed_columns);


--
-- Name: audit_changes_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_changes_occurred_at_idx ON ONLY public.audit_changes USING btree (occurred_at DESC);


--
-- Name: audit_changes_2026_07_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_changes_2026_07_occurred_at_idx ON public.audit_changes_2026_07 USING btree (occurred_at DESC);


--
-- Name: audit_changes_record_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_changes_record_type_idx ON ONLY public.audit_changes USING btree (record_type, occurred_at DESC);


--
-- Name: audit_changes_2026_07_record_type_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_changes_2026_07_record_type_occurred_at_idx ON public.audit_changes_2026_07 USING btree (record_type, occurred_at DESC);


--
-- Name: audit_changes_record_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_changes_record_idx ON ONLY public.audit_changes USING btree (record_type, record_id, occurred_at DESC);


--
-- Name: audit_changes_2026_07_record_type_record_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_changes_2026_07_record_type_record_id_occurred_at_idx ON public.audit_changes_2026_07 USING btree (record_type, record_id, occurred_at DESC);


--
-- Name: audit_changes_request_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_changes_request_id_idx ON ONLY public.audit_changes USING btree (request_id);


--
-- Name: audit_changes_2026_07_request_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_changes_2026_07_request_id_idx ON public.audit_changes_2026_07 USING btree (request_id);


--
-- Name: audit_changes_2026_08_actor_type_actor_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_changes_2026_08_actor_type_actor_id_occurred_at_idx ON public.audit_changes_2026_08 USING btree (actor_type, actor_id, occurred_at DESC);


--
-- Name: audit_changes_2026_08_changed_columns_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_changes_2026_08_changed_columns_idx ON public.audit_changes_2026_08 USING gin (changed_columns);


--
-- Name: audit_changes_2026_08_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_changes_2026_08_occurred_at_idx ON public.audit_changes_2026_08 USING btree (occurred_at DESC);


--
-- Name: audit_changes_2026_08_record_type_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_changes_2026_08_record_type_occurred_at_idx ON public.audit_changes_2026_08 USING btree (record_type, occurred_at DESC);


--
-- Name: audit_changes_2026_08_record_type_record_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_changes_2026_08_record_type_record_id_occurred_at_idx ON public.audit_changes_2026_08 USING btree (record_type, record_id, occurred_at DESC);


--
-- Name: audit_changes_2026_08_request_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_changes_2026_08_request_id_idx ON public.audit_changes_2026_08 USING btree (request_id);


--
-- Name: audit_changes_2026_09_actor_type_actor_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_changes_2026_09_actor_type_actor_id_occurred_at_idx ON public.audit_changes_2026_09 USING btree (actor_type, actor_id, occurred_at DESC);


--
-- Name: audit_changes_2026_09_changed_columns_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_changes_2026_09_changed_columns_idx ON public.audit_changes_2026_09 USING gin (changed_columns);


--
-- Name: audit_changes_2026_09_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_changes_2026_09_occurred_at_idx ON public.audit_changes_2026_09 USING btree (occurred_at DESC);


--
-- Name: audit_changes_2026_09_record_type_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_changes_2026_09_record_type_occurred_at_idx ON public.audit_changes_2026_09 USING btree (record_type, occurred_at DESC);


--
-- Name: audit_changes_2026_09_record_type_record_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_changes_2026_09_record_type_record_id_occurred_at_idx ON public.audit_changes_2026_09 USING btree (record_type, record_id, occurred_at DESC);


--
-- Name: audit_changes_2026_09_request_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_changes_2026_09_request_id_idx ON public.audit_changes_2026_09 USING btree (request_id);


--
-- Name: audit_changes_2026_10_actor_type_actor_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_changes_2026_10_actor_type_actor_id_occurred_at_idx ON public.audit_changes_2026_10 USING btree (actor_type, actor_id, occurred_at DESC);


--
-- Name: audit_changes_2026_10_changed_columns_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_changes_2026_10_changed_columns_idx ON public.audit_changes_2026_10 USING gin (changed_columns);


--
-- Name: audit_changes_2026_10_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_changes_2026_10_occurred_at_idx ON public.audit_changes_2026_10 USING btree (occurred_at DESC);


--
-- Name: audit_changes_2026_10_record_type_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_changes_2026_10_record_type_occurred_at_idx ON public.audit_changes_2026_10 USING btree (record_type, occurred_at DESC);


--
-- Name: audit_changes_2026_10_record_type_record_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_changes_2026_10_record_type_record_id_occurred_at_idx ON public.audit_changes_2026_10 USING btree (record_type, record_id, occurred_at DESC);


--
-- Name: audit_changes_2026_10_request_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_changes_2026_10_request_id_idx ON public.audit_changes_2026_10 USING btree (request_id);


--
-- Name: audit_changes_2026_11_actor_type_actor_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_changes_2026_11_actor_type_actor_id_occurred_at_idx ON public.audit_changes_2026_11 USING btree (actor_type, actor_id, occurred_at DESC);


--
-- Name: audit_changes_2026_11_changed_columns_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_changes_2026_11_changed_columns_idx ON public.audit_changes_2026_11 USING gin (changed_columns);


--
-- Name: audit_changes_2026_11_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_changes_2026_11_occurred_at_idx ON public.audit_changes_2026_11 USING btree (occurred_at DESC);


--
-- Name: audit_changes_2026_11_record_type_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_changes_2026_11_record_type_occurred_at_idx ON public.audit_changes_2026_11 USING btree (record_type, occurred_at DESC);


--
-- Name: audit_changes_2026_11_record_type_record_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_changes_2026_11_record_type_record_id_occurred_at_idx ON public.audit_changes_2026_11 USING btree (record_type, record_id, occurred_at DESC);


--
-- Name: audit_changes_2026_11_request_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_changes_2026_11_request_id_idx ON public.audit_changes_2026_11 USING btree (request_id);


--
-- Name: audit_changes_default_actor_type_actor_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_changes_default_actor_type_actor_id_occurred_at_idx ON public.audit_changes_default USING btree (actor_type, actor_id, occurred_at DESC);


--
-- Name: audit_changes_default_changed_columns_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_changes_default_changed_columns_idx ON public.audit_changes_default USING gin (changed_columns);


--
-- Name: audit_changes_default_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_changes_default_occurred_at_idx ON public.audit_changes_default USING btree (occurred_at DESC);


--
-- Name: audit_changes_default_record_type_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_changes_default_record_type_occurred_at_idx ON public.audit_changes_default USING btree (record_type, occurred_at DESC);


--
-- Name: audit_changes_default_record_type_record_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_changes_default_record_type_record_id_occurred_at_idx ON public.audit_changes_default USING btree (record_type, record_id, occurred_at DESC);


--
-- Name: audit_changes_default_request_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_changes_default_request_id_idx ON public.audit_changes_default USING btree (request_id);


--
-- Name: audit_events_action_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_action_idx ON ONLY public.audit_events USING btree (action, occurred_at DESC);


--
-- Name: audit_events_2026_07_action_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_2026_07_action_occurred_at_idx ON public.audit_events_2026_07 USING btree (action, occurred_at DESC);


--
-- Name: audit_events_actor_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_actor_idx ON ONLY public.audit_events USING btree (actor_type, actor_id, occurred_at DESC);


--
-- Name: audit_events_2026_07_actor_type_actor_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_2026_07_actor_type_actor_id_occurred_at_idx ON public.audit_events_2026_07 USING btree (actor_type, actor_id, occurred_at DESC);


--
-- Name: audit_events_caused_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_caused_by_idx ON ONLY public.audit_events USING btree (caused_by_request_id, occurred_at DESC) WHERE (caused_by_request_id IS NOT NULL);


--
-- Name: audit_events_2026_07_caused_by_request_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_2026_07_caused_by_request_id_occurred_at_idx ON public.audit_events_2026_07 USING btree (caused_by_request_id, occurred_at DESC) WHERE (caused_by_request_id IS NOT NULL);


--
-- Name: audit_events_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_occurred_at_idx ON ONLY public.audit_events USING btree (occurred_at DESC);


--
-- Name: audit_events_2026_07_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_2026_07_occurred_at_idx ON public.audit_events_2026_07 USING btree (occurred_at DESC);


--
-- Name: audit_events_request_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_request_id_idx ON ONLY public.audit_events USING btree (request_id);


--
-- Name: audit_events_2026_07_request_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_2026_07_request_id_idx ON public.audit_events_2026_07 USING btree (request_id);


--
-- Name: audit_events_subject_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_subject_idx ON ONLY public.audit_events USING btree (subject_type, subject_id, occurred_at DESC);


--
-- Name: audit_events_2026_07_subject_type_subject_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_2026_07_subject_type_subject_id_occurred_at_idx ON public.audit_events_2026_07 USING btree (subject_type, subject_id, occurred_at DESC);


--
-- Name: audit_events_2026_08_action_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_2026_08_action_occurred_at_idx ON public.audit_events_2026_08 USING btree (action, occurred_at DESC);


--
-- Name: audit_events_2026_08_actor_type_actor_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_2026_08_actor_type_actor_id_occurred_at_idx ON public.audit_events_2026_08 USING btree (actor_type, actor_id, occurred_at DESC);


--
-- Name: audit_events_2026_08_caused_by_request_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_2026_08_caused_by_request_id_occurred_at_idx ON public.audit_events_2026_08 USING btree (caused_by_request_id, occurred_at DESC) WHERE (caused_by_request_id IS NOT NULL);


--
-- Name: audit_events_2026_08_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_2026_08_occurred_at_idx ON public.audit_events_2026_08 USING btree (occurred_at DESC);


--
-- Name: audit_events_2026_08_request_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_2026_08_request_id_idx ON public.audit_events_2026_08 USING btree (request_id);


--
-- Name: audit_events_2026_08_subject_type_subject_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_2026_08_subject_type_subject_id_occurred_at_idx ON public.audit_events_2026_08 USING btree (subject_type, subject_id, occurred_at DESC);


--
-- Name: audit_events_2026_09_action_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_2026_09_action_occurred_at_idx ON public.audit_events_2026_09 USING btree (action, occurred_at DESC);


--
-- Name: audit_events_2026_09_actor_type_actor_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_2026_09_actor_type_actor_id_occurred_at_idx ON public.audit_events_2026_09 USING btree (actor_type, actor_id, occurred_at DESC);


--
-- Name: audit_events_2026_09_caused_by_request_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_2026_09_caused_by_request_id_occurred_at_idx ON public.audit_events_2026_09 USING btree (caused_by_request_id, occurred_at DESC) WHERE (caused_by_request_id IS NOT NULL);


--
-- Name: audit_events_2026_09_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_2026_09_occurred_at_idx ON public.audit_events_2026_09 USING btree (occurred_at DESC);


--
-- Name: audit_events_2026_09_request_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_2026_09_request_id_idx ON public.audit_events_2026_09 USING btree (request_id);


--
-- Name: audit_events_2026_09_subject_type_subject_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_2026_09_subject_type_subject_id_occurred_at_idx ON public.audit_events_2026_09 USING btree (subject_type, subject_id, occurred_at DESC);


--
-- Name: audit_events_2026_10_action_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_2026_10_action_occurred_at_idx ON public.audit_events_2026_10 USING btree (action, occurred_at DESC);


--
-- Name: audit_events_2026_10_actor_type_actor_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_2026_10_actor_type_actor_id_occurred_at_idx ON public.audit_events_2026_10 USING btree (actor_type, actor_id, occurred_at DESC);


--
-- Name: audit_events_2026_10_caused_by_request_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_2026_10_caused_by_request_id_occurred_at_idx ON public.audit_events_2026_10 USING btree (caused_by_request_id, occurred_at DESC) WHERE (caused_by_request_id IS NOT NULL);


--
-- Name: audit_events_2026_10_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_2026_10_occurred_at_idx ON public.audit_events_2026_10 USING btree (occurred_at DESC);


--
-- Name: audit_events_2026_10_request_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_2026_10_request_id_idx ON public.audit_events_2026_10 USING btree (request_id);


--
-- Name: audit_events_2026_10_subject_type_subject_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_2026_10_subject_type_subject_id_occurred_at_idx ON public.audit_events_2026_10 USING btree (subject_type, subject_id, occurred_at DESC);


--
-- Name: audit_events_2026_11_action_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_2026_11_action_occurred_at_idx ON public.audit_events_2026_11 USING btree (action, occurred_at DESC);


--
-- Name: audit_events_2026_11_actor_type_actor_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_2026_11_actor_type_actor_id_occurred_at_idx ON public.audit_events_2026_11 USING btree (actor_type, actor_id, occurred_at DESC);


--
-- Name: audit_events_2026_11_caused_by_request_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_2026_11_caused_by_request_id_occurred_at_idx ON public.audit_events_2026_11 USING btree (caused_by_request_id, occurred_at DESC) WHERE (caused_by_request_id IS NOT NULL);


--
-- Name: audit_events_2026_11_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_2026_11_occurred_at_idx ON public.audit_events_2026_11 USING btree (occurred_at DESC);


--
-- Name: audit_events_2026_11_request_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_2026_11_request_id_idx ON public.audit_events_2026_11 USING btree (request_id);


--
-- Name: audit_events_2026_11_subject_type_subject_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_2026_11_subject_type_subject_id_occurred_at_idx ON public.audit_events_2026_11 USING btree (subject_type, subject_id, occurred_at DESC);


--
-- Name: audit_events_default_action_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_default_action_occurred_at_idx ON public.audit_events_default USING btree (action, occurred_at DESC);


--
-- Name: audit_events_default_actor_type_actor_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_default_actor_type_actor_id_occurred_at_idx ON public.audit_events_default USING btree (actor_type, actor_id, occurred_at DESC);


--
-- Name: audit_events_default_caused_by_request_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_default_caused_by_request_id_occurred_at_idx ON public.audit_events_default USING btree (caused_by_request_id, occurred_at DESC) WHERE (caused_by_request_id IS NOT NULL);


--
-- Name: audit_events_default_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_default_occurred_at_idx ON public.audit_events_default USING btree (occurred_at DESC);


--
-- Name: audit_events_default_request_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_default_request_id_idx ON public.audit_events_default USING btree (request_id);


--
-- Name: audit_events_default_subject_type_subject_id_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_default_subject_type_subject_id_occurred_at_idx ON public.audit_events_default USING btree (subject_type, subject_id, occurred_at DESC);


--
-- Name: index_customers_on_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_customers_on_name ON public.customers USING btree (name);


--
-- Name: index_line_items_on_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_line_items_on_order_id ON public.line_items USING btree (order_id);


--
-- Name: index_line_items_on_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_line_items_on_product_id ON public.line_items USING btree (product_id);


--
-- Name: index_orders_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_orders_on_created_by_id ON public.orders USING btree (created_by_id);


--
-- Name: index_orders_on_customer_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_orders_on_customer_id ON public.orders USING btree (customer_id);


--
-- Name: index_orders_on_reference; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_orders_on_reference ON public.orders USING btree (reference);


--
-- Name: index_orders_on_status_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_orders_on_status_and_created_at ON public.orders USING btree (status, created_at);


--
-- Name: index_products_on_sku; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_products_on_sku ON public.products USING btree (sku);


--
-- Name: index_shipments_on_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_shipments_on_order_id ON public.shipments USING btree (order_id);


--
-- Name: index_users_on_email; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_email ON public.users USING btree (email);


--
-- Name: audit_changes_2026_07_actor_type_actor_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_changes_actor_idx ATTACH PARTITION public.audit_changes_2026_07_actor_type_actor_id_occurred_at_idx;


--
-- Name: audit_changes_2026_07_changed_columns_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_changes_changed_columns_idx ATTACH PARTITION public.audit_changes_2026_07_changed_columns_idx;


--
-- Name: audit_changes_2026_07_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_changes_occurred_at_idx ATTACH PARTITION public.audit_changes_2026_07_occurred_at_idx;


--
-- Name: audit_changes_2026_07_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_changes_pkey ATTACH PARTITION public.audit_changes_2026_07_pkey;


--
-- Name: audit_changes_2026_07_record_type_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_changes_record_type_idx ATTACH PARTITION public.audit_changes_2026_07_record_type_occurred_at_idx;


--
-- Name: audit_changes_2026_07_record_type_record_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_changes_record_idx ATTACH PARTITION public.audit_changes_2026_07_record_type_record_id_occurred_at_idx;


--
-- Name: audit_changes_2026_07_request_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_changes_request_id_idx ATTACH PARTITION public.audit_changes_2026_07_request_id_idx;


--
-- Name: audit_changes_2026_08_actor_type_actor_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_changes_actor_idx ATTACH PARTITION public.audit_changes_2026_08_actor_type_actor_id_occurred_at_idx;


--
-- Name: audit_changes_2026_08_changed_columns_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_changes_changed_columns_idx ATTACH PARTITION public.audit_changes_2026_08_changed_columns_idx;


--
-- Name: audit_changes_2026_08_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_changes_occurred_at_idx ATTACH PARTITION public.audit_changes_2026_08_occurred_at_idx;


--
-- Name: audit_changes_2026_08_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_changes_pkey ATTACH PARTITION public.audit_changes_2026_08_pkey;


--
-- Name: audit_changes_2026_08_record_type_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_changes_record_type_idx ATTACH PARTITION public.audit_changes_2026_08_record_type_occurred_at_idx;


--
-- Name: audit_changes_2026_08_record_type_record_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_changes_record_idx ATTACH PARTITION public.audit_changes_2026_08_record_type_record_id_occurred_at_idx;


--
-- Name: audit_changes_2026_08_request_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_changes_request_id_idx ATTACH PARTITION public.audit_changes_2026_08_request_id_idx;


--
-- Name: audit_changes_2026_09_actor_type_actor_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_changes_actor_idx ATTACH PARTITION public.audit_changes_2026_09_actor_type_actor_id_occurred_at_idx;


--
-- Name: audit_changes_2026_09_changed_columns_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_changes_changed_columns_idx ATTACH PARTITION public.audit_changes_2026_09_changed_columns_idx;


--
-- Name: audit_changes_2026_09_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_changes_occurred_at_idx ATTACH PARTITION public.audit_changes_2026_09_occurred_at_idx;


--
-- Name: audit_changes_2026_09_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_changes_pkey ATTACH PARTITION public.audit_changes_2026_09_pkey;


--
-- Name: audit_changes_2026_09_record_type_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_changes_record_type_idx ATTACH PARTITION public.audit_changes_2026_09_record_type_occurred_at_idx;


--
-- Name: audit_changes_2026_09_record_type_record_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_changes_record_idx ATTACH PARTITION public.audit_changes_2026_09_record_type_record_id_occurred_at_idx;


--
-- Name: audit_changes_2026_09_request_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_changes_request_id_idx ATTACH PARTITION public.audit_changes_2026_09_request_id_idx;


--
-- Name: audit_changes_2026_10_actor_type_actor_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_changes_actor_idx ATTACH PARTITION public.audit_changes_2026_10_actor_type_actor_id_occurred_at_idx;


--
-- Name: audit_changes_2026_10_changed_columns_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_changes_changed_columns_idx ATTACH PARTITION public.audit_changes_2026_10_changed_columns_idx;


--
-- Name: audit_changes_2026_10_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_changes_occurred_at_idx ATTACH PARTITION public.audit_changes_2026_10_occurred_at_idx;


--
-- Name: audit_changes_2026_10_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_changes_pkey ATTACH PARTITION public.audit_changes_2026_10_pkey;


--
-- Name: audit_changes_2026_10_record_type_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_changes_record_type_idx ATTACH PARTITION public.audit_changes_2026_10_record_type_occurred_at_idx;


--
-- Name: audit_changes_2026_10_record_type_record_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_changes_record_idx ATTACH PARTITION public.audit_changes_2026_10_record_type_record_id_occurred_at_idx;


--
-- Name: audit_changes_2026_10_request_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_changes_request_id_idx ATTACH PARTITION public.audit_changes_2026_10_request_id_idx;


--
-- Name: audit_changes_2026_11_actor_type_actor_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_changes_actor_idx ATTACH PARTITION public.audit_changes_2026_11_actor_type_actor_id_occurred_at_idx;


--
-- Name: audit_changes_2026_11_changed_columns_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_changes_changed_columns_idx ATTACH PARTITION public.audit_changes_2026_11_changed_columns_idx;


--
-- Name: audit_changes_2026_11_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_changes_occurred_at_idx ATTACH PARTITION public.audit_changes_2026_11_occurred_at_idx;


--
-- Name: audit_changes_2026_11_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_changes_pkey ATTACH PARTITION public.audit_changes_2026_11_pkey;


--
-- Name: audit_changes_2026_11_record_type_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_changes_record_type_idx ATTACH PARTITION public.audit_changes_2026_11_record_type_occurred_at_idx;


--
-- Name: audit_changes_2026_11_record_type_record_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_changes_record_idx ATTACH PARTITION public.audit_changes_2026_11_record_type_record_id_occurred_at_idx;


--
-- Name: audit_changes_2026_11_request_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_changes_request_id_idx ATTACH PARTITION public.audit_changes_2026_11_request_id_idx;


--
-- Name: audit_changes_default_actor_type_actor_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_changes_actor_idx ATTACH PARTITION public.audit_changes_default_actor_type_actor_id_occurred_at_idx;


--
-- Name: audit_changes_default_changed_columns_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_changes_changed_columns_idx ATTACH PARTITION public.audit_changes_default_changed_columns_idx;


--
-- Name: audit_changes_default_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_changes_occurred_at_idx ATTACH PARTITION public.audit_changes_default_occurred_at_idx;


--
-- Name: audit_changes_default_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_changes_pkey ATTACH PARTITION public.audit_changes_default_pkey;


--
-- Name: audit_changes_default_record_type_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_changes_record_type_idx ATTACH PARTITION public.audit_changes_default_record_type_occurred_at_idx;


--
-- Name: audit_changes_default_record_type_record_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_changes_record_idx ATTACH PARTITION public.audit_changes_default_record_type_record_id_occurred_at_idx;


--
-- Name: audit_changes_default_request_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_changes_request_id_idx ATTACH PARTITION public.audit_changes_default_request_id_idx;


--
-- Name: audit_events_2026_07_action_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_events_action_idx ATTACH PARTITION public.audit_events_2026_07_action_occurred_at_idx;


--
-- Name: audit_events_2026_07_actor_type_actor_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_events_actor_idx ATTACH PARTITION public.audit_events_2026_07_actor_type_actor_id_occurred_at_idx;


--
-- Name: audit_events_2026_07_caused_by_request_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_events_caused_by_idx ATTACH PARTITION public.audit_events_2026_07_caused_by_request_id_occurred_at_idx;


--
-- Name: audit_events_2026_07_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_events_occurred_at_idx ATTACH PARTITION public.audit_events_2026_07_occurred_at_idx;


--
-- Name: audit_events_2026_07_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_events_pkey ATTACH PARTITION public.audit_events_2026_07_pkey;


--
-- Name: audit_events_2026_07_request_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_events_request_id_idx ATTACH PARTITION public.audit_events_2026_07_request_id_idx;


--
-- Name: audit_events_2026_07_subject_type_subject_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_events_subject_idx ATTACH PARTITION public.audit_events_2026_07_subject_type_subject_id_occurred_at_idx;


--
-- Name: audit_events_2026_08_action_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_events_action_idx ATTACH PARTITION public.audit_events_2026_08_action_occurred_at_idx;


--
-- Name: audit_events_2026_08_actor_type_actor_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_events_actor_idx ATTACH PARTITION public.audit_events_2026_08_actor_type_actor_id_occurred_at_idx;


--
-- Name: audit_events_2026_08_caused_by_request_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_events_caused_by_idx ATTACH PARTITION public.audit_events_2026_08_caused_by_request_id_occurred_at_idx;


--
-- Name: audit_events_2026_08_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_events_occurred_at_idx ATTACH PARTITION public.audit_events_2026_08_occurred_at_idx;


--
-- Name: audit_events_2026_08_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_events_pkey ATTACH PARTITION public.audit_events_2026_08_pkey;


--
-- Name: audit_events_2026_08_request_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_events_request_id_idx ATTACH PARTITION public.audit_events_2026_08_request_id_idx;


--
-- Name: audit_events_2026_08_subject_type_subject_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_events_subject_idx ATTACH PARTITION public.audit_events_2026_08_subject_type_subject_id_occurred_at_idx;


--
-- Name: audit_events_2026_09_action_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_events_action_idx ATTACH PARTITION public.audit_events_2026_09_action_occurred_at_idx;


--
-- Name: audit_events_2026_09_actor_type_actor_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_events_actor_idx ATTACH PARTITION public.audit_events_2026_09_actor_type_actor_id_occurred_at_idx;


--
-- Name: audit_events_2026_09_caused_by_request_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_events_caused_by_idx ATTACH PARTITION public.audit_events_2026_09_caused_by_request_id_occurred_at_idx;


--
-- Name: audit_events_2026_09_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_events_occurred_at_idx ATTACH PARTITION public.audit_events_2026_09_occurred_at_idx;


--
-- Name: audit_events_2026_09_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_events_pkey ATTACH PARTITION public.audit_events_2026_09_pkey;


--
-- Name: audit_events_2026_09_request_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_events_request_id_idx ATTACH PARTITION public.audit_events_2026_09_request_id_idx;


--
-- Name: audit_events_2026_09_subject_type_subject_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_events_subject_idx ATTACH PARTITION public.audit_events_2026_09_subject_type_subject_id_occurred_at_idx;


--
-- Name: audit_events_2026_10_action_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_events_action_idx ATTACH PARTITION public.audit_events_2026_10_action_occurred_at_idx;


--
-- Name: audit_events_2026_10_actor_type_actor_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_events_actor_idx ATTACH PARTITION public.audit_events_2026_10_actor_type_actor_id_occurred_at_idx;


--
-- Name: audit_events_2026_10_caused_by_request_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_events_caused_by_idx ATTACH PARTITION public.audit_events_2026_10_caused_by_request_id_occurred_at_idx;


--
-- Name: audit_events_2026_10_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_events_occurred_at_idx ATTACH PARTITION public.audit_events_2026_10_occurred_at_idx;


--
-- Name: audit_events_2026_10_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_events_pkey ATTACH PARTITION public.audit_events_2026_10_pkey;


--
-- Name: audit_events_2026_10_request_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_events_request_id_idx ATTACH PARTITION public.audit_events_2026_10_request_id_idx;


--
-- Name: audit_events_2026_10_subject_type_subject_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_events_subject_idx ATTACH PARTITION public.audit_events_2026_10_subject_type_subject_id_occurred_at_idx;


--
-- Name: audit_events_2026_11_action_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_events_action_idx ATTACH PARTITION public.audit_events_2026_11_action_occurred_at_idx;


--
-- Name: audit_events_2026_11_actor_type_actor_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_events_actor_idx ATTACH PARTITION public.audit_events_2026_11_actor_type_actor_id_occurred_at_idx;


--
-- Name: audit_events_2026_11_caused_by_request_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_events_caused_by_idx ATTACH PARTITION public.audit_events_2026_11_caused_by_request_id_occurred_at_idx;


--
-- Name: audit_events_2026_11_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_events_occurred_at_idx ATTACH PARTITION public.audit_events_2026_11_occurred_at_idx;


--
-- Name: audit_events_2026_11_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_events_pkey ATTACH PARTITION public.audit_events_2026_11_pkey;


--
-- Name: audit_events_2026_11_request_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_events_request_id_idx ATTACH PARTITION public.audit_events_2026_11_request_id_idx;


--
-- Name: audit_events_2026_11_subject_type_subject_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_events_subject_idx ATTACH PARTITION public.audit_events_2026_11_subject_type_subject_id_occurred_at_idx;


--
-- Name: audit_events_default_action_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_events_action_idx ATTACH PARTITION public.audit_events_default_action_occurred_at_idx;


--
-- Name: audit_events_default_actor_type_actor_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_events_actor_idx ATTACH PARTITION public.audit_events_default_actor_type_actor_id_occurred_at_idx;


--
-- Name: audit_events_default_caused_by_request_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_events_caused_by_idx ATTACH PARTITION public.audit_events_default_caused_by_request_id_occurred_at_idx;


--
-- Name: audit_events_default_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_events_occurred_at_idx ATTACH PARTITION public.audit_events_default_occurred_at_idx;


--
-- Name: audit_events_default_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_events_pkey ATTACH PARTITION public.audit_events_default_pkey;


--
-- Name: audit_events_default_request_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_events_request_id_idx ATTACH PARTITION public.audit_events_default_request_id_idx;


--
-- Name: audit_events_default_subject_type_subject_id_occurred_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.audit_events_subject_idx ATTACH PARTITION public.audit_events_default_subject_type_subject_id_occurred_at_idx;


--
-- Name: customers customers_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER customers_audit AFTER INSERT OR DELETE OR UPDATE ON public.customers FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('created_at,updated_at,lock_version,password_digest,encrypted_password,remember_created_at,reset_password_token,reset_password_sent_at', 'Customer');


--
-- Name: line_items line_items_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER line_items_audit AFTER INSERT OR DELETE OR UPDATE ON public.line_items FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('created_at,updated_at,lock_version,password_digest,encrypted_password,remember_created_at,reset_password_token,reset_password_sent_at', 'LineItem');


--
-- Name: orders orders_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER orders_audit AFTER INSERT OR DELETE OR UPDATE ON public.orders FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('created_at,updated_at,lock_version,password_digest,encrypted_password,remember_created_at,reset_password_token,reset_password_sent_at', 'Order');


--
-- Name: products products_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER products_audit AFTER INSERT OR DELETE OR UPDATE ON public.products FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('created_at,updated_at,lock_version,password_digest,encrypted_password,remember_created_at,reset_password_token,reset_password_sent_at', 'Product');


--
-- Name: shipments shipments_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER shipments_audit AFTER INSERT OR DELETE OR UPDATE ON public.shipments FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('created_at,updated_at,lock_version,password_digest,encrypted_password,remember_created_at,reset_password_token,reset_password_sent_at', 'Shipment');


--
-- Name: users users_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER users_audit AFTER INSERT OR DELETE OR UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('created_at,updated_at,lock_version,password_digest,encrypted_password,remember_created_at,reset_password_token,reset_password_sent_at', 'User');


--
-- Name: line_items fk_rails_11e15d5c6b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.line_items
    ADD CONSTRAINT fk_rails_11e15d5c6b FOREIGN KEY (product_id) REFERENCES public.products(id);


--
-- Name: line_items fk_rails_2dc2e5c22c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.line_items
    ADD CONSTRAINT fk_rails_2dc2e5c22c FOREIGN KEY (order_id) REFERENCES public.orders(id);


--
-- Name: orders fk_rails_3dad120da9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT fk_rails_3dad120da9 FOREIGN KEY (customer_id) REFERENCES public.customers(id);


--
-- Name: shipments fk_rails_9892d6a938; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shipments
    ADD CONSTRAINT fk_rails_9892d6a938 FOREIGN KEY (order_id) REFERENCES public.orders(id);


--
-- Name: orders fk_rails_9ac523da23; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT fk_rails_9ac523da23 FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20260101000002'),
('20260101000001');

