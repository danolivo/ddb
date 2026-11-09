-- pgbench script: create one new sale with 1..max_lines line items.
--
--     pgbench -n -f new_sale.sql -c 16 -j 4 -T 300 bench
--
-- Runs unchanged on every node. Active-active safety comes from three facts:
--   * it only INSERTs into replicated tables, never UPDATEs a shared row;
--   * sale_id comes from next_gid(), so keys never collide across nodes;
--   * header and lines are written by ONE statement, i.e. one transaction,
--     so a subscriber never sees a sale without its items (or vice versa).
--
-- Keep these in sync with init.sql.
\set n_customers 100000
\set n_products  10000
\set max_lines   5

\set customer_id random(1, :n_customers)
\set n_lines     random(1, :max_lines)

WITH picks AS MATERIALIZED (
    -- Volatile random() forces materialisation: 'lines' is read twice below
    -- and both readers must see the same rows, or total <> sum(items).
    SELECT g::smallint                                 AS line_no,
           1 + floor(random() * :n_products)::integer  AS product_id,
           1 + floor(random() * 3)::integer            AS qty
    FROM generate_series(1, :n_lines) AS g
),
lines AS (
    SELECT k.line_no, k.product_id, k.qty, p.price AS unit_price
    FROM picks k
    JOIN sales.product p USING (product_id)
),
new_sale AS (
    INSERT INTO sales.sale (customer_id, total)
    SELECT :customer_id, sum(qty * unit_price) FROM lines
    RETURNING sale_id
)
INSERT INTO sales.sale_item (sale_id, line_no, product_id, qty, unit_price)
SELECT s.sale_id, l.line_no, l.product_id, l.qty, l.unit_price
FROM new_sale s CROSS JOIN lines l;
