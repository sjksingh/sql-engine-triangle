# Query 1 – Aggregation by Property Type

## Purpose

This query benchmarks **basic analytical aggregation** across four execution engines using the **same dataset**, **same filters**, and **same grouping logic**.

It intentionally avoids:

* Joins
* Subqueries
* Engine-specific hints
* Pre-aggregation

The goal is to highlight **execution model differences**, not SQL feature differences.

---

## Query intent (logical)

> Aggregate UK house prices by property type since 2020, ordered by average price.

---

## What this query stresses

* Scan efficiency
* Aggregate state management
* Group-by strategy
* Sorting on derived aggregates
* Executor vs pushdown behavior

This pattern is representative of:

* BI dashboards
* KPI rollups
* Exploratory analytics

---

## PostgreSQL – Native HEAP

**Engine**

* PostgreSQL 18.1
* Native heap storage
* B-tree indexes (see main README)

### SQL

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
```

### Observed plan highlights

* Parallel index-only scan
* Partial + Final GroupAggregate
* Full visibility checks handled by MVCC
* Sort on derived aggregate

📄 Full plan: `postgres.plan.txt`

⏱ **Execution time:** ~800 ms

---

## CedarDB

**Engine**

* CedarDB v2025-12-19 (PostgreSQL 16 compatible)
* Row-based, modern MVCC
* Minimal indexing

### SQL

```sql
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
```

### Observed plan highlights

* Single table scan
* In-memory group-by
* No buffer management overhead
* Compact aggregation pipeline

📄 Full plan: `cedar.plan.txt`

⏱ **Execution time:** ~60 ms

---

## PostgreSQL + pg_clickhouse (FDW Pushdown)

**Engine**

* PostgreSQL 18
* pg_clickhouse FDW
* Aggregation pushed to ClickHouse

### SQL

```sql
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
```

### Observed plan highlights

* Full aggregation pushed down
* PostgreSQL executor bypassed
* Minimal FDW coordination cost

📄 Full plan: `fdw.plan.txt`

⏱ **Execution time:** ~50–60 ms

---

## ClickHouse

**Engine**

* ClickHouse 25.12
* MergeTree
* Columnar + vectorized execution

### SQL

```sql
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
```

### Observed pipeline highlights

* Parallel columnar scan
* Vectorized aggregation
* Multi-stage merge + sort
* Fully pipelined execution

📄 Full pipeline: `clickhouse.plan.txt`

⏱ **Execution time:** ~15–20 ms

---

## Summary (qualitative)

| Engine              | Execution Model        | Key Cost Driver                |
| ------------------- | ---------------------- | ------------------------------ |
| PostgreSQL HEAP     | Row-based + MVCC       | Visibility checks + executor   |
| CedarDB             | Row-based, modern MVCC | Memory-local aggregation       |
| pg_clickhouse (FDW) | Pushdown               | Network + coordination         |
| ClickHouse          | Columnar, vectorized   | CPU-efficient batch processing |

---

## Key takeaway

This query demonstrates that **performance differences come from execution architecture**, not SQL expressiveness:

* PostgreSQL excels at correctness and concurrency
* CedarDB reduces executor and MVCC overhead
* FDW pushdown removes PostgreSQL execution cost entirely
* ClickHouse maximizes throughput via columnar pipelines

The same pattern becomes more pronounced in later queries involving:

* Time bucketing
* Window functions
* Percentiles
* Multi-stage aggregation
