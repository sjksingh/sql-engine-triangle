# Query 4 – Top-K Counties with Percentiles

## Purpose

This query benchmarks **complex analytics** combining:

- Top-K subqueries (`LIMIT 10`)
- Join between derived set and large fact table
- Percentile computation (`PERCENTILE_CONT` / `quantileTDigest`)
- Multi-column group-by and ordered results

This pattern is common in:

- Regional analytics dashboards
- Advanced BI reports
- Statistical summaries with percentiles
- Performance comparison of OLAP engines

---

## Query intent (logical)

> For the top 10 counties by transaction volume since 2020, compute **per property type**:

- Total transactions
- Average price
- Percentiles (25%, 50%, 75%, 95%)

---

## What this query stresses

- Materialization of derived sets (top-K)
- Join performance with large fact table
- Windowed percentile aggregation
- Executor and buffer management under high cardinality
- Differences between exact vs approximate percentile calculation

This query is intentionally **high-stress**, exposing the real differences between execution architectures.

---

## PostgreSQL – Native HEAP

**Engine**

- PostgreSQL 18.1
- B-tree indexes: `(county, type, date)`
- Full MVCC visibility checks

### SQL

```sql
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
Observed plan highlights
Hash join between top-K CTE and main table

External merge sort on (county, type) → temp spill ~77 MB

Heavy buffer usage (~4.2M reads)

Parallel partial + final aggregates

JIT compilation for aggregate expressions

📄 Full plan: postgres-q4.plan.txt
⏱ Execution time: ~4.3 s

Correct, robust, but heavy on executor and temp I/O.

CedarDB
Engine

CedarDB v2025-12-19

Row-based, modern MVCC

Minimal indexing

SQL
sql
Copy code
EXPLAIN (ANALYZE)
WITH filtered AS (
    SELECT *
    FROM uk_price_paid_ingest
    WHERE county IS NOT NULL
      AND date >= '2020-01-01'
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
Observed plan highlights
Single scan of the fact table

In-memory group-by

Hash join

Percentile computation integrated in memory

Minimal IO and no spill

📄 Full plan: cedar-q4.plan.txt
⏱ Execution time: ~913 ms

CedarDB handles multi-stage analytics efficiently without executor drag.

PostgreSQL + pg_clickhouse (FDW Pushdown)
Engine

PostgreSQL 18 + pg_clickhouse FDW

SQL
sql
Copy code
EXPLAIN (ANALYZE, BUFFERS)
WITH filtered AS (
    SELECT *
    FROM uk_price_paid
    WHERE county IS NOT NULL
      AND date >= '2020-01-01'
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
Observed plan highlights
Filtered CTE materialized in PostgreSQL

Join + percentile done in PostgreSQL

FDW pushdown handles raw table scan

Significant temp I/O (~83 MB) and disk usage

📄 Full plan: fdw-q4.plan.txt
⏱ Execution time: ~20.7 s

Demonstrates FDW limits on multi-stage analytics with percentiles.

ClickHouse
Engine

ClickHouse 25.12

MergeTree

Columnar + vectorized + pipeline execution

SQL
sql
Copy code
EXPLAIN PIPELINE
WITH top_counties AS (
    SELECT county
    FROM uk_price_paid
    WHERE county IS NOT NULL
      AND date >= '2020-01-01'
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
GROUP BY
    p.county,
    p.type
ORDER BY
    p.county ASC,
    p.type ASC;
Observed pipeline highlights
Full pipeline aggregation + join

Vectorized percentile computation with TDigest

Minimal memory overhead

Fast multi-stage processing

📄 Full pipeline: clickhouse-q4.plan.txt
⏱ Execution time: ~27 ms

Columnar pipeline and approximate TDigest aggregation make ClickHouse extremely fast.

Summary (qualitative)
Engine	Strength shown in Query 4	Main cost driver
PostgreSQL HEAP	Full SQL, exact percentiles	Executor + temp I/O + window overhead
CedarDB	Fast in-memory analytics	Scan + hash join
pg_clickhouse (FDW)	Full SQL via pushdown, limited aggregation	Temp spill + CTE materialization
ClickHouse	High-throughput percentiles + top-K	CPU-efficient columnar + TDigest pipelines

Key takeaway
Query 4 clearly illustrates:

Top-K and percentile analytics are expensive in row-based systems

CedarDB minimizes executor overhead, producing fast analytics

FDW pushdown can be slower than native execution due to temp materialization

ClickHouse columnar engine achieves extreme throughput with pipelined, approximate aggregates

This is the climax of the benchmark suite, showing the largest architectural differences between engines.
