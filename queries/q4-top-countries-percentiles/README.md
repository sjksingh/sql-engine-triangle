# Query 4 – Percentiles and Top Counties Analytics

## Purpose

This query benchmarks **multi-stage aggregation with joins and percentiles**:

- Aggregation on top N counties
- Use of `PERCENTILE_CONT` / `quantileTDigest`
- Multi-column grouping (`county × type`)
- Ordered output on grouped keys

This pattern is common in:

- Real estate analytics dashboards
- Top-N reporting
- Percentile-based price analysis

---

## Query intent (logical)

> For the top 10 counties by transaction count since 2020, compute transaction counts, average price, and percentile breakdowns by property type.

---

## What this query stresses

Compared to Queries 1–3, this query adds:

- **CTEs and multi-stage joins**
- Percentile calculation (analytic window aggregates)
- Larger intermediate row sets for top-N selection
- Sorting and memory management for aggregated results
- Row vs column engine differences in handling percentiles

This highlights **execution architecture differences**, not SQL expressiveness.

---

## PostgreSQL – Native HEAP

**Engine**
- PostgreSQL 18.1
- Heap storage
- B-tree indexes on `(county, type, date)`

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

Parallel index-only scan over top counties

Hash join for CTE → main table

GroupAggregate with percentile computation

External merge sort for final ordering

Heavy buffer usage and temp file writes

📄 Full plan: postgres-q4.plan.txt
⏱ Execution time: ~4.3 s

PostgreSQL HEAP handles correctness but pays for join, grouping, and percentile calculations at large scale.

## CedarDB 

**Engine**

- CedarDB v2025-12-19

- Row-based, modern MVCC

- Minimal indexing

### SQL

```sql
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
```
Observed plan highlights

Single table scan of filtered dataset

In-memory group-by

Integrated percentile operator

Minimal buffer overhead

📄 Full plan: cedar-q4.plan.txt
⏱ Execution time: ~0.9 s

CedarDB shows strong performance even for multi-stage percentile queries due to low executor and MVCC overhead.

PostgreSQL + pg_clickhouse (FDW Pushdown)

Engine

PostgreSQL 18

pg_clickhouse FDW

```sql
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
```

Observed plan highlights

Aggregation pushed to ClickHouse

PostgreSQL executes join + window functions

Significant FDW cost if result set is large

📄 Full plan: fdw-q4.plan.txt
⏱ Execution time: ~20.7 s

FDW demonstrates orchestration cost for multi-stage percentile queries with large intermediate sets.

ClickHouse

Engine

ClickHouse 25.12

MergeTree

Columnar + vectorized execution

```sql
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
ORDER BY p.county ASC, p.type ASC;
```

Observed pipeline highlights

Parallel MergeTree scan

Vectorized aggregation with TDigest for percentiles

Multi-stage join + sort pipeline

Fully pipelined execution

📄 Full pipeline: clickhouse-q4.plan.txt
⏱ Execution time: ~27 ms

ClickHouse excels at multi-stage percentile + top-N queries via columnar vectorized pipelines.


| Engine              | Strength in Query 4                        | Primary Cost Driver                 |
| ------------------- | ------------------------------------------ | ----------------------------------- |
| PostgreSQL HEAP     | Correct, full percentile computation       | HashJoin + temp sort + buffer usage |
| CedarDB             | In-memory percentile aggregation           | Scan only                           |
| pg_clickhouse (FDW) | Orchestrates ClickHouse pushdown           | Join + large intermediate set       |
| ClickHouse          | Columnar, vectorized percentile throughput | CPU-efficient pipeline              |



Key takeaway

Query 4 highlights architectural differences under multi-stage percentile and top-N workloads:

Row engines (PostgreSQL HEAP) pay for sorting, join, and percentile aggregation

CedarDB reduces executor/MVCC cost while keeping correctness

FDW pushdown shifts aggregation, but PostgreSQL overhead remains for joins

ClickHouse executes fully vectorized pipelines with minimal overhead

This query is the culmination of all previous patterns, demonstrating joins, percentiles, top-N selection, and pipeline efficiency.
