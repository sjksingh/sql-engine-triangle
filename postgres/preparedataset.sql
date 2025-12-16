-- =====================================================================
-- OPTIMIZED PostgreSQL DDLs for UK Price Paid Data
-- Dataset: 30.7M rows, 1995-2025, ~1.8GB text data
-- =====================================================================

-- ---------------------------------------------------------------------
-- OPTION 1: NON-PARTITIONED TABLE (Baseline)
-- ---------------------------------------------------------------------
CREATE TABLE uk_price_paid_pg (
    price INTEGER NOT NULL,
    date DATE NOT NULL,
    postcode1 VARCHAR(10) NOT NULL,
    postcode2 VARCHAR(10) NOT NULL,
    type VARCHAR(20) NOT NULL,
    is_new SMALLINT NOT NULL,
    duration VARCHAR(20) NOT NULL,
    addr1 TEXT NOT NULL,
    addr2 TEXT NOT NULL,
    street VARCHAR(100) NOT NULL,
    locality VARCHAR(100) NOT NULL,
    town VARCHAR(100) NOT NULL,
    district VARCHAR(100) NOT NULL,
    county VARCHAR(100) NOT NULL
) WITH (
    fillfactor = 90,  -- Leave room for HOT updates
    autovacuum_vacuum_scale_factor = 0.05,
    autovacuum_analyze_scale_factor = 0.02
);

-- Primary composite index matching ClickHouse ORDER BY
CREATE INDEX idx_uk_price_paid_composite ON uk_price_paid_pg 
    (postcode1, postcode2, addr1, addr2);

-- BRIN index for date (efficient for time-series, ~1000x smaller than B-tree)
CREATE INDEX idx_uk_price_paid_date_brin ON uk_price_paid_pg 
    USING BRIN (date) WITH (pages_per_range = 128);

-- B-tree indexes for common filters
CREATE INDEX idx_uk_price_paid_type ON uk_price_paid_pg (type);
CREATE INDEX idx_uk_price_paid_town ON uk_price_paid_pg (town);
CREATE INDEX idx_uk_price_paid_county ON uk_price_paid_pg (county);

-- Composite index for common query patterns (date + location)
CREATE INDEX idx_uk_price_paid_date_town ON uk_price_paid_pg (date, town);

-- Analyze after load
ANALYZE uk_price_paid_pg;

COMMENT ON TABLE uk_price_paid_pg IS 'UK Land Registry Price Paid Data - Non-partitioned version for performance baseline';


-- ---------------------------------------------------------------------
-- OPTION 2: PARTITIONED TABLE (Using pg_partman)
-- ---------------------------------------------------------------------
CREATE TABLE uk_price_paid_pg_part (
    price INTEGER NOT NULL,
    date DATE NOT NULL,
    postcode1 VARCHAR(10) NOT NULL,
    postcode2 VARCHAR(10) NOT NULL,
    type VARCHAR(20) NOT NULL,
    is_new SMALLINT NOT NULL,
    duration VARCHAR(20) NOT NULL,
    addr1 TEXT NOT NULL,
    addr2 TEXT NOT NULL,
    street VARCHAR(100) NOT NULL,
    locality VARCHAR(100) NOT NULL,
    town VARCHAR(100) NOT NULL,
    district VARCHAR(100) NOT NULL,
    county VARCHAR(100) NOT NULL
) PARTITION BY RANGE (date);

-- Create initial partitions using pg_partman (creates 2021-2029 by default)
SELECT public.create_parent(
    'public.uk_price_paid_pg_part',
    'date',
    '1 year',
    'range'
);

-- Update pg_partman configuration for automatic maintenance
UPDATE public.part_config 
SET 
    retention = NULL,  -- Keep all partitions (don't auto-drop old data)
    retention_keep_table = true,
    infinite_time_partitions = true,
    premake = 5
WHERE parent_table = 'public.uk_price_paid_pg_part';

-- Run maintenance to create future partitions
CALL public.run_maintenance_proc();

-- Create historical partitions (1995-2020) manually
DO $
DECLARE
    year_val INTEGER;
BEGIN
    FOR year_val IN 1995..2020 LOOP
        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS public.uk_price_paid_pg_part_p%s0101 
             PARTITION OF public.uk_price_paid_pg_part 
             FOR VALUES FROM (%L) TO (%L)',
            year_val,
            year_val || '-01-01',
            (year_val + 1) || '-01-01'
        );
    END LOOP;
END $;

-- Verify all partitions exist (should show 1995-2031)
SELECT tablename 
FROM pg_tables 
WHERE schemaname = 'public' 
  AND tablename LIKE 'uk_price_paid_pg_part_p%'
ORDER BY tablename;

-- Create indexes on parent (will cascade to all child partitions)
CREATE INDEX idx_uk_price_paid_part_composite ON uk_price_paid_pg_part 
    (postcode1, postcode2, addr1, addr2);

CREATE INDEX idx_uk_price_paid_part_date ON uk_price_paid_pg_part (date);

CREATE INDEX idx_uk_price_paid_part_type ON uk_price_paid_pg_part (type);

CREATE INDEX idx_uk_price_paid_part_town ON uk_price_paid_pg_part (town);

CREATE INDEX idx_uk_price_paid_part_county ON uk_price_paid_pg_part (county);

CREATE INDEX idx_uk_price_paid_part_date_town ON uk_price_paid_pg_part (date, town);

COMMENT ON TABLE uk_price_paid_pg_part IS 'UK Land Registry Price Paid Data - Partitioned by year using pg_partman';


-- ---------------------------------------------------------------------
-- DATA LOADING COMMANDS
-- ---------------------------------------------------------------------

-- Load non-partitioned table from ClickHouse foreign table
INSERT INTO uk_price_paid_pg 
SELECT * FROM uk_price_paid;

-- Load partitioned table from ClickHouse foreign table
INSERT INTO uk_price_paid_pg_part 
SELECT * FROM uk_price_paid;

-- Post-load maintenance
ANALYZE uk_price_paid_pg;
ANALYZE uk_price_paid_pg_part;


-- ---------------------------------------------------------------------
-- VERIFICATION QUERIES
-- ---------------------------------------------------------------------

-- Check row counts
SELECT 'Non-partitioned' as table_type, count(*) FROM uk_price_paid_pg
UNION ALL
SELECT 'Partitioned' as table_type, count(*) FROM uk_price_paid_pg_part
UNION ALL
SELECT 'ClickHouse FDW' as table_type, count(*) FROM uk_price_paid;

-- Check partition information
SELECT 
    parent.relname AS parent_table,
    child.relname AS partition_name,
    pg_get_expr(child.relpartbound, child.oid) AS partition_expression,
    pg_size_pretty(pg_total_relation_size(child.oid)) AS partition_size
FROM pg_inherits
JOIN pg_class parent ON pg_inherits.inhparent = parent.oid
JOIN pg_class child ON pg_inherits.inhrelid = child.oid
WHERE parent.relname = 'uk_price_paid_pg_part'
ORDER BY child.relname;

-- Check table sizes
SELECT 
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS total_size,
    pg_size_pretty(pg_relation_size(schemaname||'.'||tablename)) AS table_size,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename) - 
                   pg_relation_size(schemaname||'.'||tablename)) AS index_size
FROM pg_tables
WHERE tablename IN ('uk_price_paid_pg', 'uk_price_paid_pg_part')
ORDER BY tablename;


-- ---------------------------------------------------------------------
-- SAMPLE BENCHMARK QUERIES
-- ---------------------------------------------------------------------

-- Query 1: Average price by year and type
EXPLAIN (ANALYZE, BUFFERS, TIMING)
SELECT 
    EXTRACT(YEAR FROM date) as year,
    type,
    COUNT(*) as transactions,
    ROUND(AVG(price)) as avg_price,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY price)) as median_price
FROM uk_price_paid_pg
GROUP BY EXTRACT(YEAR FROM date), type
ORDER BY year, type;

-- Query 2: Recent sales in specific town
EXPLAIN (ANALYZE, BUFFERS, TIMING)
SELECT 
    date,
    postcode1,
    postcode2,
    street,
    type,
    price
FROM uk_price_paid_pg
WHERE town = 'LONDON'
  AND date >= '2024-01-01'
ORDER BY date DESC, price DESC
LIMIT 100;

-- Query 3: Price trends by county (aggregation)
EXPLAIN (ANALYZE, BUFFERS, TIMING)
SELECT 
    county,
    EXTRACT(YEAR FROM date) as year,
    COUNT(*) as sales_count,
    ROUND(AVG(price)) as avg_price,
    MIN(price) as min_price,
    MAX(price) as max_price
FROM uk_price_paid_pg
WHERE date BETWEEN '2020-01-01' AND '2024-12-31'
GROUP BY county, EXTRACT(YEAR FROM date)
ORDER BY county, year;

-- Query 4: Postcode analysis
EXPLAIN (ANALYZE, BUFFERS, TIMING)
SELECT 
    postcode1,
    COUNT(*) as transaction_count,
    ROUND(AVG(price)) as avg_price
FROM uk_price_paid_pg
WHERE date >= '2023-01-01'
GROUP BY postcode1
HAVING COUNT(*) > 100
ORDER BY avg_price DESC
LIMIT 50;


-- ---------------------------------------------------------------------
-- pg_partman MAINTENANCE (Schedule with pg_cron)
-- ---------------------------------------------------------------------

-- Run partition maintenance daily at 3 AM
SELECT cron.schedule(
    'partman-maintenance',
    '0 3 * * *',
    $CALL public.run_maintenance_proc()$
);

-- Verify scheduled job
SELECT * FROM cron.job WHERE jobname = 'partman-maintenance';
