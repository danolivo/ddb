/*
 * Initial data insertion
 */

BEGIN;

\set schema_name sales

SET LOCAL search_path TO :schema_name,public;

INSERT INTO product
SELECT i,
       'SKU-' || lpad(i::text, 6, '0'),
       'Product ' || i,
       (ARRAY['books','food','garden','home','sport','toys','tools','tech'])[1 + i % 8],
       round((1 + (i * 7919) % 50000) / 100.0, 2)
FROM generate_series(1, 10000) i;

INSERT INTO customer (customer_id, name, region, created_at)
SELECT i,
       'Customer ' || i,
       (ARRAY['north','south','east','west'])[1 + i % 4],
       '2026-01-01'::timestamptz
FROM generate_series(1, 100000) i;

ANALYZE product, customer;

END;
