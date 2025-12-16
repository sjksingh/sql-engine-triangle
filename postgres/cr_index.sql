-- ============================================================
-- INDEXES FOR NON-PARTITIONED TABLE
-- SET max_parallel_maintenance_workers = 8;
-- SET maintenance_work_mem = '8GB';  -- or as much as you safely can
-- ============================================================

-- Index 1: For simple type+price aggregations (Query 1)
CREATE INDEX idx_uk_price_paid_type_price ON uk_price_paid_pg (type, price);

-- Index 2: Composite index for filtered aggregations (Query 2)
-- Ordered by selectivity: postcode1 (most selective) -> town -> district -> type -> price
CREATE INDEX idx_uk_price_paid_location_agg ON uk_price_paid_pg 
    (postcode1, town, district, type, price);

-- Index 3: Alternative for queries filtering by town first
CREATE INDEX idx_uk_price_paid_town_district ON uk_price_paid_pg 
    (town, district, postcode1, type);

-- BRIN index for date range queries (small, efficient)
CREATE INDEX idx_uk_price_paid_date_brin ON uk_price_paid_pg 
    USING BRIN (date) WITH (pages_per_range = 128);


-- ============================================================
-- INDEXES FOR PARTITIONED TABLE
-- ============================================================

-- Same indexes will cascade to all child partitions
CREATE INDEX idx_uk_price_paid_part_type_price ON uk_price_paid_pg_part 
    (type, price);

CREATE INDEX idx_uk_price_paid_part_location_agg ON uk_price_paid_pg_part 
    (postcode1, town, district, type, price);

CREATE INDEX idx_uk_price_paid_part_town_district ON uk_price_paid_pg_part 
    (town, district, postcode1, type);

CREATE INDEX idx_uk_price_paid_part_date_brin ON uk_price_paid_pg_part 
    USING BRIN (date) WITH (pages_per_range = 128);


-- ============================================================
-- POST-INDEX MAINTENANCE
-- ============================================================

-- Update statistics for query planner
ANALYZE (VERBOSE) uk_price_paid_pg;
ANALYZE (VERBOSE) uk_price_paid_pg_part;

-- Verify indexes were created
SELECT 
    schemaname,
    tablename,
    indexname,
    pg_size_pretty(pg_relation_size(indexname::regclass)) AS index_size
FROM pg_indexes
WHERE tablename IN ('uk_price_paid_pg', 'uk_price_paid_pg_part')
ORDER BY tablename, indexname;
