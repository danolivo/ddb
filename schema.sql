-- Sales/products schema for an N-node (N <= 32) active-active benchmark
-- on vanilla PostgreSQL logical replication.
--
-- Run the SAME script on every node. The only per-node difference is the
-- app.node_id setting (0..31), e.g.:
--     ALTER DATABASE bench SET app.node_id = 7;
--

BEGIN;

\set schema_name sales

CREATE SCHEMA :schema_name;

SET LOCAL search_path TO :schema_name,public;

-- ---------------------------------------------------------------------------
-- Global ID generator
-- ---------------------------------------------------------------------------

-- Casting to this domain rejects an out-of-range node id instead of
-- silently wrapping into another node's range.
CREATE DOMAIN node_id_t AS smallint CHECK (VALUE BETWEEN 0 AND 31);

-- Fails loudly ("unrecognized configuration parameter") if app.node_id
-- is not set, so a misconfigured node cannot generate colliding IDs.
--
-- SET search_path FROM CURRENT pins the path in effect right now (this
-- schema first), so node_id_t resolves whatever the caller's search_path is.
CREATE FUNCTION next_gid(seq regclass) RETURNS bigint
LANGUAGE sql VOLATILE PARALLEL UNSAFE
SET search_path FROM CURRENT AS $$
    SELECT (current_setting('app.node_id')::node_id_t)::bigint << 58
           | nextval(seq)
$$;

-- ---------------------------------------------------------------------------
-- Reference data: identical on every node and loaded locally by init.sql.
-- These tables ARE in sales_pub (it covers the whole schema), so:
--   * create subscriptions only after init.sql has run on every node, and
--     with copy_data = false, or the initial sync and the replicated
--     init.sql INSERTs hit duplicate keys;
--   * treat them as read-only during the run: any write here replicates
--     to every other node and can conflict there.
-- ---------------------------------------------------------------------------

CREATE TABLE product (
    product_id  integer       PRIMARY KEY,
    sku         text          NOT NULL UNIQUE,
    name        text          NOT NULL,
    category    text          NOT NULL,
    price       numeric(10,2) NOT NULL CHECK (price > 0)
);

CREATE TABLE customer (
    customer_id integer       PRIMARY KEY,
    name        text          NOT NULL,
    region      text          NOT NULL,
    created_at  timestamptz   NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Transactional data: inserted independently on each node, replicated.
-- ---------------------------------------------------------------------------

CREATE SEQUENCE sale_id_seq AS bigint MAXVALUE 288230376151711743; -- 2^58 - 1

CREATE TABLE sale (
    sale_id     bigint        PRIMARY KEY DEFAULT next_gid('sale_id_seq'),
    customer_id integer       NOT NULL REFERENCES customer,
    sold_at     timestamptz   NOT NULL DEFAULT now(),
    total       numeric(12,2) NOT NULL
);
ALTER SEQUENCE sale_id_seq OWNED BY sale.sale_id;

-- Composite key: no second generator needed, uniqueness follows from sale_id.
CREATE TABLE sale_item (
    sale_id     bigint        NOT NULL REFERENCES sale ON DELETE CASCADE,
    line_no     smallint      NOT NULL,
    product_id  integer       NOT NULL REFERENCES product,
    qty         integer       NOT NULL CHECK (qty > 0),
    unit_price  numeric(10,2) NOT NULL,
    PRIMARY KEY (sale_id, line_no)
);

-- Typical reporting indexes. Every extra index is extra apply work on
-- 31 subscribers: drop them if you benchmark raw replication throughput.
CREATE INDEX ON sale (sold_at);
CREATE INDEX ON sale (customer_id);
CREATE INDEX ON sale_item (product_id);

-- Publishes every table in the schema, including ones created later in this
-- script: product, customer, sale, sale_item and retention_horizon.
--
-- Only INSERT and UPDATE are published: DELETE and TRUNCATE on any node stay
-- local to that node. Purging relies on this (see below).
CREATE PUBLICATION sales_pub FOR TABLES IN SCHEMA sales
    WITH (publish = 'insert, update');


/*
 * Machinery to track the horizon of 'active' rows. Rows under the horizon
 * should not participate in SELECT queries. Treat them as moved to a cold
 * storage.
 *
 * retention_horizon is replicated. An UPDATE on one node reaches every node,
 * and the ALWAYS trigger purges there locally. The purge DELETEs themselves
 * are not published (publish = 'insert, update'), so each node does the
 * work once and nothing is sent across: one small UPDATE moves the horizon
 * cluster-wide.
 */
CREATE TABLE retention_horizon (
	id		integer PRIMARY KEY CHECK (id = 1),
    h       timestamptz NOT NULL DEFAULT '-infinity'
);
INSERT INTO retention_horizon VALUES (1, '-infinity');

-- SET search_path FROM CURRENT: see next_gid().
CREATE FUNCTION purge_below_horizon() RETURNS trigger LANGUAGE plpgsql
SET search_path FROM CURRENT AS $$
DECLARE hz timestamptz := (SELECT max(h) FROM retention_horizon);
BEGIN
  -- Delete lines explicitly: in an apply worker (session_replication_role =
  -- replica) the FK's ON DELETE CASCADE does not fire.
  --
  -- One statement, one snapshot. As two statements, another apply worker
  -- could commit an old-dated sale between them: the second DELETE would
  -- remove the sale, the first would have missed its lines, and the lines
  -- would stay orphaned for good (later purges find lines via their sale).
  WITH s AS (DELETE FROM sale WHERE sold_at < hz RETURNING sale_id)
  DELETE FROM sale_item i USING s WHERE i.sale_id = s.sale_id;
  RETURN NULL;
END $$;
CREATE TRIGGER purge AFTER UPDATE ON retention_horizon
  FOR EACH ROW EXECUTE FUNCTION purge_below_horizon();
ALTER TABLE retention_horizon ENABLE ALWAYS TRIGGER purge;

END;

/*
drop schema sales cascade;
drop publication sales_pub;
*/