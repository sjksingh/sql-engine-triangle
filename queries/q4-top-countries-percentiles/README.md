# SQL Engine Triangle – OLAP Benchmark

This repository benchmarks **ClickHouse, CedarDB, PostgreSQL HEAP, and PostgreSQL + pg_clickhouse FDW** using the **same dataset**, same cardinality, and same distributions.  
The goal is to compare **execution architectures** across:

1. Columnar (ClickHouse)
2. Row-based + modern MVCC (CedarDB)
3. PostgreSQL executor pushing down to ClickHouse (FDW)
4. PostgreSQL classic HEAP

We focus on four representative analytical queries.

---

## Query 1 – Aggregation by Property Type

### Purpose
Aggregate UK house prices by property type since 2020, ordered by average price.  
This tests **basic group aggregation** and **executor performance**.

### PostgreSQL – HEAP

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT 
    type,
    COUNT(*) AS transactions,
    ROUND(AVG(price)) AS avg_price,
    ROUND(MIN(price)) AS min_price,
    ROUND(MAX(price)) AS max_price
FROM uk_price_paid_pg
WHERE date >= '2020-01-01'
GROUP BY type
ORDER BY avg_price DESC;
Execution time: ~800 ms
📄 Full plan: postgres-q1.plan.txt

CedarDB
sql
Copy code
EXPLAIN (ANALYZE)
SELECT 
    type,
    COUNT(*) AS transactions,
    ROUND(AVG(price)) AS avg_price,
    ROUND(MIN(price)) AS min_price,
    ROUND(MAX(price)) AS max_price
FROM uk_price_paid_ingest
WHERE date >= '2020-01-01'
GROUP BY type
ORDER BY avg_price DESC;
Execution time: ~60 ms
📄 Full plan: cedar-q1.plan.txt

PostgreSQL + FDW
sql
Copy code
EXPLAIN (ANALYZE, BUFFERS)
SELECT 
    type,
    COUNT(*) AS transactions,
    ROUND(AVG(price)) AS avg_price,
    ROUND(MIN(price)) AS min_price,
    ROUND(MAX(price)) AS max_price
FROM uk_price_paid
WHERE date >= '2020-01-01'
GROUP BY type
ORDER BY avg_price DESC;
Execution time: ~50–60 ms
📄 Full plan: fdw-q1.plan.txt

ClickHouse
sql
Copy code
EXPLAIN PIPELINE
SELECT 
    type,
    COUNT(*) AS transactions,
    round(AVG(price)) AS avg_price,
    round(MIN(price)) AS min_price,
    round(MAX(price)) AS max_price
FROM uk_price_paid
WHERE date >= '2020-01-01'
GROUP BY type
ORDER BY avg_price DESC;
Execution time: ~15–20 ms
📄 Full pipeline: clickhouse-q1.plan.txt

Query 2 – Time-bucketed Aggregation by City
Purpose
Compute monthly transactions and average prices for a fixed set of cities since 2020.
This tests time bucketing, grouping, and sort.

PostgreSQL – HEAP
sql
Copy code
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    town,
    DATE_TRUNC('month', date) AS month,
    COUNT(*) AS transactions,
    ROUND(AVG(price)) AS avg_price
FROM uk_price_paid_pg
WHERE town IN ('LONDON','MANCHESTER','BRISTOL','BIRMINGHAM','NOTTINGHAM')
  AND date >= '2020-01-01'
GROUP BY town, DATE_TRUNC('month', date)
ORDER BY town, month;
Execution time: ~690 ms
📄 Full plan: postgres-q2.plan.txt

CedarDB
sql
Copy code
EXPLAIN (ANALYZE)
SELECT
    town,
    DATE_TRUNC('month', date) AS month,
    COUNT(*) AS transactions,
    ROUND(AVG(price)) AS avg_price
FROM uk_price_paid_ingest
WHERE town IN ('LONDON','MANCHESTER','BRISTOL','BIRMINGHAM','NOTTINGHAM')
  AND date >= '2020-01-01'
GROUP BY town, DATE_TRUNC('month', date)
ORDER BY town, month;
Execution time: ~30 ms
📄 Full plan: cedar-q2.plan.txt

PostgreSQL + FDW
sql
Copy code
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    town,
    DATE_TRUNC('month', date) AS month,
    COUNT(*) AS transactions,
    ROUND(AVG(price)) AS avg_price
FROM uk_price_paid
WHERE town IN ('LONDON','MANCHESTER','BRISTOL','BIRMINGHAM','NOTTINGHAM')
  AND date >= '2020-01-01'
GROUP BY town, DATE_TRUNC('month', date)
ORDER BY town, month;
Execution time: ~50 ms
📄 Full plan: fdw-q2.plan.txt

ClickHouse
sql
Copy code
EXPLAIN PIPELINE
SELECT
    town,
    DATE_TRUNC('month', date) AS month,
    COUNT(*) AS transactions,
    ROUND(AVG(price)) AS avg_price
FROM uk_price_paid
WHERE town IN ('LONDON','MANCHESTER','BRISTOL','BIRMINGHAM','NOTTINGHAM')
  AND date >= '2020-01-01'
GROUP BY town, DATE_TRUNC('month', date)
ORDER BY town, month;
Execution time: ~13 ms
📄 Full pipeline: clickhouse-q2.plan.txt

Query 3 – Year-over-Year Analytics with Window Functions
Purpose
Compute yearly average prices per type since 2015, with YoY change and percentage.
This tests window function performance over large aggregations.

PostgreSQL – HEAP
sql
Copy code
EXPLAIN (ANALYZE, BUFFERS)
WITH yearly_avg AS (
    SELECT
        EXTRACT(YEAR FROM date) AS year,
        type,
        AVG(price) AS avg_price,
        COUNT(*) AS transactions
    FROM uk_price_paid_pg
    WHERE date >= '2015-01-01'
    GROUP BY EXTRACT(YEAR FROM date), type
)
SELECT
    year,
    type,
    ROUND(avg_price) AS avg_price,
    transactions,
    ROUND(avg_price - LAG(avg_price) OVER (PARTITION BY type ORDER BY year)) AS yoy_change,
    ROUND(100.0 * (avg_price - LAG(avg_price) OVER (PARTITION BY type ORDER BY year)) /
          LAG(avg_price) OVER (PARTITION BY type ORDER BY year), 2) AS yoy_pct
FROM yearly_avg
ORDER BY type, year;
Execution time: ~2.5 s
📄 Full plan: postgres-q3.plan.txt

CedarDB
sql
Copy code
EXPLAIN (ANALYZE)
WITH yearly_avg AS (
    SELECT
        EXTRACT(YEAR FROM date) AS year,
        type,
        AVG(price) AS avg_price,
        COUNT(*) AS transactions
    FROM uk_price_paid_ingest
    WHERE date >= '2015-01-01'
    GROUP BY EXTRACT(YEAR FROM date), type
)
SELECT
    year,
    type,
    ROUND(avg_price) AS avg_price,
    transactions,
    ROUND(avg_price - LAG(avg_price) OVER (PARTITION BY type ORDER BY year)) AS yoy_change,
    ROUND(100.0 * (avg_price - LAG(avg_price) OVER (PARTITION BY type ORDER BY year)) /
          LAG(avg_price) OVER (PARTITION BY type ORDER BY year), 2) AS yoy_pct
FROM yearly_avg
ORDER BY type, year;
Execution time: ~110 ms
📄 Full plan: cedar-q3.plan.txt

PostgreSQL + FDW
sql
Copy code
EXPLAIN (ANALYZE, BUFFERS)
WITH yearly_avg AS (
    SELECT
        EXTRACT(YEAR FROM date) AS year,
        type,
        AVG(price) AS avg_price,
        COUNT(*) AS transactions
    FROM uk_price_paid
    WHERE date >= '2015-01-01'
    GROUP BY EXTRACT(YEAR FROM date), type
)
SELECT
    year,
    type,
    ROUND(avg_price) AS avg_price,
    transactions,
    ROUND(avg_price - LAG(avg_price) OVER (PARTITION BY type ORDER BY year)) AS yoy_change,
    ROUND(100.0 * (avg_price - LAG(avg_price) OVER (PARTITION BY type ORDER BY year)) /
          LAG(avg_price) OVER (PARTITION BY type ORDER BY year), 2) AS yoy_pct
FROM yearly_avg
ORDER BY type, year;
Execution time: ~100 ms
📄 Full plan: fdw-q3.plan.txt

ClickHouse
sql
Copy code
EXPLAIN PIPELINE
WITH yearly_avg AS (
    SELECT
        toYear(date) AS year,
        type,
        AVG(price) AS avg_price,
        COUNT(*) AS transactions
    FROM uk_price_paid
    WHERE date >= '2015-01-01'
    GROUP BY toYear(date), type
)
SELECT
    year,
    type,
    ROUND(avg_price) AS avg_price,
    transactions,
    ROUND(avg_price - LAG(avg_price) OVER (PARTITION BY type ORDER BY year)) AS yoy_change,
    ROUND(100.0 * (avg_price - LAG(avg_price) OVER (PARTITION BY type ORDER BY year)) /
          LAG(avg_price) OVER (PARTITION BY type ORDER BY year), 2) AS yoy_pct
FROM yearly_avg
ORDER BY type, year;
Execution time: ~25 ms
📄 Full pipeline: clickhouse-q3.plan.txt

Query 4 – Top-K Counties with Percentiles
Purpose
For the top 10 counties by transaction volume, compute per-type transactions, average, and percentiles.
This stresses top-K joins + percentile computation.

PostgreSQL – HEAP
sql
Copy code
EXPLAIN (ANALYZE, BUFFERS)
WITH top_counties AS (
    SELECT county, COUNT(*) AS cnt
    FROM uk_price_paid_pg
    WHERE county IS NOT NULL AND date >= '2020-01-01'
    GROUP BY county
    ORDER BY cnt DESC
    LIMIT 10
)
SELECT
    p.county,
    p.type,
    COUNT(*) AS transactions,
    ROUND(AVG(p.price)) AS avg_price,
    ROUND(PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY p.price)) AS p25,
    ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY p.price)) AS median,
    ROUND(PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY p.price)) AS p75,
    ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY p.price)) AS p95
FROM uk_price_paid_pg p
INNER JOIN top_counties tc ON p.county = tc.county
WHERE p.date >= '2020-01-01'
GROUP BY p.county, p.type
ORDER BY p.county, p.type;
Execution time: ~4.3 s
📄 Full plan: postgres-q4.plan.txt

CedarDB
sql
Copy code
EXPLAIN (ANALYZE)
WITH filtered AS (
    SELECT *
    FROM uk_price_paid_ingest
    WHERE county IS NOT NULL AND date >= '2020-01-01'
),
top_counties AS (
    SELECT county
    FROM filtered
    GROUP BY county
    ORDER BY COUNT(*) DESC
    LIMIT 10
)
SELECT
    p.county,
    p.type,
    COUNT(*) AS transactions,
    ROUND(AVG(p.price)) AS avg_price,
    ROUND(PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY p.price)) AS p25,
    ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY p.price)) AS median,
    ROUND(PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY p.price)) AS p75,
    ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY p.price)) AS p95
FROM filtered p
JOIN top_counties tc USING (county)
GROUP BY p.county, p.type
ORDER BY p.county, p.type;
Execution time: ~913 ms
📄 Full plan: cedar-q4.plan.txt

PostgreSQL + FDW
sql
Copy code
EXPLAIN (ANALYZE, BUFFERS)
WITH filtered AS (
    SELECT *
    FROM uk_price_paid
    WHERE county IS NOT NULL AND date >= '2020-01-01'
),
top_counties AS (
    SELECT county
    FROM filtered
    GROUP BY county
    ORDER BY COUNT(*) DESC
    LIMIT 10
)
SELECT
    p.county,
    p.type,
    COUNT(*) AS transactions,
    ROUND(AVG(p.price)) AS avg_price,
    ROUND(PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY p.price)) AS p25,
    ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY p.price)) AS median,
    ROUND(PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY p.price)) AS p75,
    ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY p.price)) AS p95
FROM filtered p
JOIN top_counties tc USING (county)
GROUP BY p.county, p.type
ORDER BY p.county, p.type;
Execution time: ~20.7 s
📄 Full plan: fdw-q4.plan.txt

ClickHouse
sql
Copy code
EXPLAIN PIPELINE
WITH top_counties AS (
    SELECT county
    FROM uk_price_paid
    WHERE county IS NOT NULL AND date >= '2020-01-01'
    GROUP BY county
    ORDER BY COUNT(*) DESC
    LIMIT 10
)
SELECT
    p.county,
    p.type,
    COUNT(*) AS transactions,
    round(avg(p.price)) AS avg_price,
    round(quantileTDigest(0.25)(p.price)) AS p25,
    round(quantileTDigest(0.50)(p.price)) AS median,
    round(quantileTDigest(0.75)(p.price)) AS p75,
    round(quantileTDigest(0.95)(p.price)) AS p95
FROM uk_price_paid AS p
INNER JOIN top_counties AS tc ON p.county = tc.county
WHERE p.date >= '2020-01-01'
GROUP BY p.county, p.type
ORDER BY p.county, p.type;
Execution time: ~27 ms
📄 Full pipeline: clickhouse-q4.plan.txt

Key Takeaways Across All Queries
PostgreSQL HEAP is correct and flexible but suffers with multi-stage analytics and high cardinality.

CedarDB minimizes executor overhead and provides very fast row-based analytics.

FDW pushdown leverages ClickHouse execution but can be slower when temp materialization occurs.

ClickHouse excels in columnar, pipelined, vectorized analytics and approximate percentile computations.
