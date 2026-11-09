-- USAGE:
--   psql -v retention='2026-11-09 10:00+01' -f purge.sql bench
--
-- Parameters (all optional, psql -v name=value):
--   retention   purge sales with sold_at older than this     default: now() - 1 hour
--   op_timeout  lock_timeout and statement_timeout of the     default: 30min
--               purge itself (the local DELETE can take
--               minutes on a big window)
--   wal_wait    how long to wait for every peer to confirm    default: 10min
--               the horizon WAL before giving up
--   wal_poll    polling interval of that wait, in seconds     default: 1
--
-- Needs max_prepared_transactions > 0 on every node (see ddb.conf).
--
-- Only one purge runs per node at a time: a second one finds the advisory
-- lock taken and exits without doing anything. A purge interrupted between
-- PREPARE and COMMIT/ROLLBACK leaves a prepared transaction that holds the
-- retention_horizon row; later purges wait op_timeout on it and fail. Find it
-- in pg_prepared_xacts (gid 'purge_<xid>') and ROLLBACK PREPARED it.
--
-- PURPOSE: keep the database bounded in size. This is housekeeping, not a
-- consistency mechanism. The horizon is the logical boundary: every other
-- query must filter on sold_at >= retention_horizon.h and must not rely on
-- rows below it being gone.
--
-- Below the horizon the nodes may differ for a while. A sale created before
-- the horizon but still in flight (replication lag, a node cut off longer
-- than the retention age) reaches some nodes after they have purged and
-- stays there. The next purge with a later horizon removes it. Choose a
-- retention age well above the worst expected lag or outage.
--

\if :{?retention}
\else
  \set retention ''
\endif
\if :{?op_timeout}
\else
  \set op_timeout 30min
\endif
\if :{?wal_wait}
\else
  \set wal_wait 10min
\endif
\if :{?wal_poll}
\else
  \set wal_poll 1
\endif

\set ON_ERROR_STOP on

SELECT coalesce(nullif(:'retention', '')::timestamptz,
                now() - interval '1 hour') AS retention,
       ceil(extract(epoch FROM :'wal_wait'::interval) / :wal_poll)::int AS wal_polls,
       pg_try_advisory_lock(hashtext('sales.purge')) AS got_lock \gset
\if :got_lock
\else
  \echo 'purge skipped: another purge is running on this node'
  \quit
\endif
\echo 'purging sales older than' :retention

SET lock_timeout = :'op_timeout';
SET statement_timeout = :'op_timeout';

BEGIN;
UPDATE sales.retention_horizon SET h = greatest(h, :'retention'::timestamptz);
SELECT 'purge_' || txid_current() AS gid \gset
PREPARE TRANSACTION :'gid';

SELECT pg_current_wal_insert_lsn() AS lsn,
       (SELECT count(*) FROM pg_subscription s JOIN pg_database d ON d.oid = s.subdbid
         WHERE d.datname = current_database()) AS peers \gset

-- poll every wal_poll seconds for up to wal_wait; stops as soon as every peer
-- has confirmed the horizon WAL
SELECT 1 FROM pg_replication_slots
 WHERE database = current_database() AND slot_type = 'logical'
HAVING NOT (count(*) = :peers AND bool_and(confirmed_flush_lsn >= :'lsn'))
\watch interval=:wal_poll count=:wal_polls min_rows=1

SELECT count(*) = :peers
       AND coalesce(bool_and(confirmed_flush_lsn >= :'lsn'), true) AS ok
  FROM pg_replication_slots
 WHERE database = current_database() AND slot_type = 'logical' \gset
\if :ok
  COMMIT PREPARED :'gid';
\else
  ROLLBACK PREPARED :'gid';
  \echo 'purge rolled back: not all peers confirmed within wal_wait =' :wal_wait
  \echo 'run it again'
\endif
