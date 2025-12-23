# Query 3 – Year-over-Year Analytics with Window Functions

## Purpose

This query benchmarks **multi-stage analytical processing** involving:

* Large-scale aggregation
* Time-based grouping
* Window functions (`LAG`)
* Ordered partitions
* Derived metrics (YoY change and percentage)

This pattern is extremely common in:

* Financial analytics
* Trend analysis dashboards
* Executive reporting
* Data science feature generation

---

## Query intent (logical)

> For each property type, compute yearly average prices and transaction counts since 2015, then calculate **year-over-year price change and growth percentage**.

---

## What this query stresses

Compared to Queries 1 & 2, this adds:

* A **two-phase execution model**

  1. Aggregate phase (year × type)
  2. Window phase (LAG over ordered partitions)
* Larger intermediate result sets
* Sorting inside window partitions
* Executor memory management
* Cross-stage materialization costs

This query is intentionally **not trivial**:

* It cannot be solved with a single aggregate
* It forces engines to expose their **analytic execution model**

---

## PostgreSQL – Native HEAP

**Engine**

* PostgreSQL 18.1
* Heap storage
* Index-only scan on `(type, date, price)`

### SQL

```sql
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
    ROUND(
        100.0 * (avg_price - LAG(avg_price) OVER (PARTITION BY type ORDER BY year)) /
        LAG(avg_price) OVER (PARTITION BY type ORDER BY year),
        2
    ) AS yoy_pct
FROM yearly_avg
ORDER BY type, year;
```

### Observed plan highlights

* Parallel index-only scan over ~10M+ rows
* Partial + Final HashAggregate
* Sort on `(type, year)`
* WindowAgg with in-memory storage
* Heavy buffer usage and MVCC visibility checks
* Noticeable executor and JIT overhead

📄 Full plan: `postgres-q3.plan.txt`
⏱ **Execution time:** ~2.5 s

> PostgreSQL handles correctness, concurrency, and flexibility well, but pays a significant cost for large scans + window execution.

---

## CedarDB

**Engine**

* CedarDB v2025-12-19
* Row-based, modern MVCC
* Minimal indexing

### SQL

```sql
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
    ROUND(
        100.0 * (avg_price - LAG(avg_price) OVER (PARTITION BY type ORDER BY year)) /
        LAG(avg_price) OVER (PARTITION BY type ORDER BY year),
        2
    ) AS yoy_pct
FROM yearly_avg
ORDER BY type, year;
```

### Observed plan highlights

* Single table scan
* In-memory group-by
* Integrated window operator
* No buffer or visibility overhead
* Very compact intermediate states

📄 Full plan: `cedar-q3.plan.txt`
⏱ **Execution time:** ~110 ms

> CedarDB shows its strength here: **analytical SQL without executor drag**.

---

## PostgreSQL + pg_clickhouse (FDW Pushdown)

**Engine**

* PostgreSQL 18
* pg_clickhouse FDW

### SQL

```sql
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
    ROUND(
        100.0 * (avg_price - LAG(avg_price) OVER (PARTITION BY type ORDER BY year)) /
        LAG(avg_price) OVER (PARTITION BY type ORDER BY year),
        2
    ) AS yoy_pct
FROM yearly_avg
ORDER BY type, year;
```

### Observed plan highlights

* Aggregation fully pushed to ClickHouse
* Window function executed in PostgreSQL
* Small intermediate result set (~55 rows)
* Minimal FDW overhead

📄 Full plan: `fdw-q3.plan.txt`
⏱ **Execution time:** ~100 ms

> This is a great example of **hybrid execution**: heavy lifting in ClickHouse, lightweight analytics in PostgreSQL.

---

## ClickHouse

**Engine**

* ClickHouse 25.12
* MergeTree
* Vectorized + pipeline execution

### SQL

```sql
EXPLAIN PIPELINE
WITH yearly_avg AS (
    SELECT
        toYear(date) AS year,
        type,
        AVG(price) AS avg_price,
        COUNT(*) AS transactions
    FROM uk_price_paid
    WHERE date >= '2015-01-01'
    GROUP BY
        toYear(date),
        type
)
SELECT
    year,
    type,
    ROUND(avg_price) AS avg_price,
    transactions,
    ROUND(avg_price - LAG(avg_price) OVER (PARTITION BY type ORDER BY year)) AS yoy_change,
    ROUND(
        100. * (avg_price - LAG(avg_price) OVER (PARTITION BY type ORDER BY year)) /
        LAG(avg_price) OVER (PARTITION BY type ORDER BY year),
        2
    ) AS yoy_pct
FROM yearly_avg
ORDER BY
    type,
    year;
```

### Observed pipeline highlights

* Parallel columnar scan
* Vectorized aggregation
* Partitioned window execution
* Multi-stage pipeline with merge + sort

📄 Full pipeline: `clickhouse-q3.plan.txt`
⏱ **Execution time:** ~25 ms

---

## Summary (qualitative)

| Engine              | Strength in Query 3                | Primary Cost Driver               |
| ------------------- | ---------------------------------- | --------------------------------- |
| PostgreSQL HEAP     | Correctness, rich SQL semantics    | MVCC + executor + window overhead |
| CedarDB             | Fast analytical SQL on row storage | Scan only                         |
| pg_clickhouse (FDW) | Best-of-both worlds execution      | Window in Postgres                |
| ClickHouse          | High-throughput analytic pipelines | CPU-efficient vector processing   |

---

## Key takeaway

Query 3 clearly separates **OLTP-style executors** from **analytical execution engines**:

* Window functions amplify executor cost in PostgreSQL
* CedarDB minimizes that cost dramatically
* FDW pushdown keeps PostgreSQL relevant as an analytics orchestrator
* ClickHouse excels when the entire pipeline stays columnar

This query sets the stage perfectly for **Query 4 (percentiles + joins)**, where architectural differences become even more pronounced.
