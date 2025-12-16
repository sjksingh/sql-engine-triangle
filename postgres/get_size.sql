-- Get the REAL size of partitioned table (including all child partitions)
SELECT 
    'uk_price_paid_pg_part (with all partitions)' AS table_name,
    pg_size_pretty(
        pg_total_relation_size('public.uk_price_paid_pg_part')
    ) AS total_size_with_partitions,
    pg_size_pretty(
        sum(pg_total_relation_size(schemaname||'.'||tablename))
    ) AS sum_of_all_partitions
FROM pg_tables
WHERE tablename LIKE 'uk_price_paid_pg_part_p%'
GROUP BY 1;

-- Compare both tables properly
SELECT 
    'Non-partitioned' AS table_type,
    count(*) AS row_count,
    pg_size_pretty(pg_total_relation_size('public.uk_price_paid_pg')) AS total_size,
    pg_size_pretty(pg_relation_size('public.uk_price_paid_pg')) AS table_size,
    pg_size_pretty(pg_indexes_size('public.uk_price_paid_pg')) AS index_size
FROM uk_price_paid_pg

UNION ALL

SELECT 
    'Partitioned' AS table_type,
    count(*) AS row_count,
    pg_size_pretty(pg_total_relation_size('public.uk_price_paid_pg_part')) AS total_size,
    pg_size_pretty(pg_relation_size('public.uk_price_paid_pg_part')) AS table_size,
    pg_size_pretty(pg_indexes_size('public.uk_price_paid_pg_part')) AS index_size
FROM uk_price_paid_pg_part;

-- Verify row counts match
SELECT 
    'Non-partitioned' as source,
    count(*) as row_count
FROM uk_price_paid_pg
UNION ALL
SELECT 
    'Partitioned' as source,
    count(*) as row_count
FROM uk_price_paid_pg_part
UNION ALL
SELECT 
    'ClickHouse FDW' as source,
    count(*) as row_count
FROM uk_price_paid;
