# OLAP Execution Benchmark

### ClickHouse vs CedarDB vs PostgreSQL (HEAP & pg_clickhouse)

## TL;DR

This repository provides a **fully reproducible OLAP comparison lab** using the **same 30M-row dataset**, identical schema, and identical query shapes across four different execution engines:

1. **ClickHouse** – Columnar OLAP engine
2. **CedarDB** – Row-based engine with modern MVCC
3. **PostgreSQL + pg_clickhouse** – Executor pushdown into ClickHouse
4. **PostgreSQL HEAP** – Classic row-store with B-tree indexes

**No query rewrites.
No pre-aggregations.
No data skew.**

Only the **execution engine** differs.

---

## Why this repo exists

Most database benchmarks fail in at least one way:

* Different schemas per engine
* Different data distributions
* Pre-aggregated tables
* Engine-specific SQL rewrites
* Non-reproducible ingestion pipelines

This lab is intentionally **boring and honest**:

* Same dataset
* Same cardinality
* Same distributions
* Same SQL semantics

The goal is to **observe execution behavior**, not win a benchmark.

---

## Dataset

**UK Price Paid dataset**

* ~30.7 million rows
* Real-world skew
* Wide rows
* High-cardinality dimensions
* Time-series friendly

Row count used throughout the lab:

```
30,729,146 rows
```

---

## Architecture Overview

```
          ┌───────────────┐
          │  ClickHouse   │  (Columnar OLAP)
          │ uk_price_paid │
          └───────┬───────┘
                  │ CSV stream
                  ▼
┌───────────────┐     ┌───────────────┐
│  CedarDB      │     │ PostgreSQL    │
│ row + MVCC    │     │ HEAP + index  │
│ ingest table  │     │ native table  │
└───────────────┘     └───────────────┘
          ▲
          │ FDW / pushdown
          │
    ┌───────────────┐
    │ PostgreSQL    │
    │ pg_clickhouse │
    └───────────────┘

```

---

## Engines Compared

| Engine                     | Storage   | Execution        |
| -------------------------- | --------- | ---------------- |
| ClickHouse                 | Columnar  | Vectorized       |
| CedarDB                    | Row-based | Modern MVCC      |
| PostgreSQL + pg_clickhouse | Hybrid    | Pushdown         |
| PostgreSQL HEAP            | Row-based | Classic executor |

---

## Requirements

* Docker
* Docker Compose
* ~15GB free disk
* ~8GB RAM recommended

---

## Start the Lab

```bash
docker-compose up -d
docker-compose ps -a
```

Expected services:

```
cedardb_server
clickhouse_server
pg18_clickhouse
```

---

## Step 1 – Check if ClickHouse baseline tables exists...

```bash
docker exec -it clickhouse_server \
  clickhouse-client --query "SHOW CREATE TABLE uk_price_paid FORMAT Pretty"

docker exec -it clickhouse_server \
  clickhouse-client --query "SELECT count() FROM uk_price_paid"
```


--- 

## Step 2 – ClickHouse base table ingestion via url() --- This will take 5-10 minutes to ingest the 30 million row based on network speed. 

```bash
docker exec clickhouse_server \
  clickhouse-client --query "
INSERT INTO default.uk_price_paid
SELECT
    toUInt32(price_string) AS price,

    -- Convert to Date (not DateTime)
    toDate(parseDateTimeBestEffortUS(time)) AS date,

    splitByChar(' ', postcode)[1] AS postcode1,
    splitByChar(' ', postcode)[2] AS postcode2,

    -- Map single-letter codes → Enum8 values
    transform(
        a,
        ['T', 'S', 'D', 'F', 'O'],
        ['terraced', 'semi-detached', 'detached', 'flat', 'other']
    ) AS type,

    -- UInt8 (0/1) matches your schema
    b = 'Y' AS is_new,

    transform(
        c,
        ['F', 'L', 'U'],
        ['freehold', 'leasehold', 'unknown']
    ) AS duration,

    addr1,
    addr2,
    street,
    locality,
    town,
    district,
    county
FROM url(
    'http://prod1.publicdata.landregistry.gov.uk.s3-website-eu-west-1.amazonaws.com/pp-complete.csv',
    'CSV',
    'uuid_string String,
     price_string String,
     time String,
     postcode String,
     a String,
     b String,
     c String,
     addr1 String,
     addr2 String,
     street String,
     locality String,
     town String,
     district String,
     county String,
     d String,
     e String'
)
SETTINGS
    max_http_get_redirects = 10,
    input_format_allow_errors_num = 1000,
    input_format_allow_errors_ratio = 0.001";
```

Verify:

```bash
docker exec -it clickhouse_server \
  clickhouse-client --query "SELECT count() FROM uk_price_paid"
```

---

## Step 3 – Validate pg_clickhouse FDW 

```bash
PGPASSWORD=pgdbre psql -h localhost -p 5434 -U postgres -d postgres \
  -c "SELECT count(*) FROM uk_price_paid;"
```

This query executes inside PostgreSQL, but is **pushed down to ClickHouse**.

---

## Step 4 – Create CedarDB ingest table (no indexes)

```sql
PGPASSWORD=cedardbre psql -h localhost -p 5433 -U postgres -d postgres -v ON_ERROR_STOP=1 <<'SQL'
-- safe: drop if exists so repeated runs are idempotent
DROP TABLE IF EXISTS uk_price_paid_ingest;

CREATE TABLE uk_price_paid_ingest (
    price INTEGER,
    date DATE,
    postcode1 TEXT,
    postcode2 TEXT,
    type TEXT,
    is_new SMALLINT,
    duration TEXT,
    addr1 TEXT,
    addr2 TEXT,
    street TEXT,
    locality TEXT,
    town TEXT,
    district TEXT,
    county TEXT
);
SQL
```

---

## Step 5 – Stream ClickHouse → CedarDB 

```bash
docker exec clickhouse_server \
  clickhouse-client --query "
    SELECT
      price,
      toString(date) AS date,
      postcode1,
      postcode2,
      CAST(type, 'String') AS type,
      is_new,
      CAST(duration, 'String') AS duration,
      addr1,
      addr2,
      street,
      locality,
      town,
      district,
      county
    FROM uk_price_paid
    FORMAT CSVWithNames
  " \
| PGPASSWORD=cedardbre psql -h localhost -p 5433 -U postgres -d postgres \
  -c "\copy uk_price_paid_ingest FROM STDIN WITH (FORMAT csv, HEADER true)"
```

Verify:

```bash
PGPASSWORD=cedardbre psql -h localhost -p 5433 -U postgres -d postgres \
  -c "SELECT count(*) FROM uk_price_paid_ingest;"
```

---

## Step 6 – Create PostgreSQL HEAP table

```sql
PGPASSWORD=pgdbre psql -h localhost -p 5434 -U postgres -d postgres -v ON_ERROR_STOP=1 <<'SQL'
DROP TABLE IF EXISTS uk_price_paid_pg;

CREATE TABLE uk_price_paid_pg (
    price INTEGER NOT NULL,
    date DATE NOT NULL,
    postcode1 VARCHAR(8),
    postcode2 VARCHAR(4),
    type VARCHAR(15),
    is_new BOOLEAN,
    duration VARCHAR(10),
    addr1 VARCHAR(200),
    addr2 VARCHAR(200),
    street VARCHAR(200),
    locality VARCHAR(100),
    town VARCHAR(100),
    district VARCHAR(100),
    county VARCHAR(100)
);
SQL
```

Populate from ClickHouse FDW:

```sql
PGPASSWORD=pgdbre psql -h localhost -p 5434 -U postgres -d postgres -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO uk_price_paid_pg
SELECT
    price,
    date,
    postcode1,
    postcode2,
    type,
    is_new = 1,
    duration,
    addr1,
    addr2,
    street,
    locality,
    town,
    district,
    county
FROM uk_price_paid;
SQL
```

---

## Step 7 – Indexing strategy

### PostgreSQL HEAP

```sql
PGPASSWORD=pgdbre psql -h localhost -p 5434 -U postgres -d postgres -v ON_ERROR_STOP=1 <<'SQL'
CREATE INDEX idx_pg_date ON uk_price_paid_pg(date);
CREATE INDEX idx_pg_town ON uk_price_paid_pg(town);
CREATE INDEX idx_pg_type ON uk_price_paid_pg(type);
CREATE INDEX idx_pg_postcode ON uk_price_paid_pg(postcode1, postcode2);
CREATE INDEX idx_pg_date_type ON uk_price_paid_pg(date, type);
CREATE INDEX idx_pg_town_date ON uk_price_paid_pg(town, date);
CREATE INDEX idx_pg_type_date_price ON uk_price_paid_pg(type, date, price);
CREATE INDEX idx_pg_county_type_date ON uk_price_paid_pg(county, type, date)
WHERE county IS NOT NULL;

ANALYZE uk_price_paid_pg;
SQL
```

### CedarDB

```sql
PGPASSWORD=cedardbre psql -h localhost -p 5433 -U postgres -d postgres -v ON_ERROR_STOP=1 <<'SQL'
CREATE INDEX idx_cedar_date ON uk_price_paid_ingest(date);
CREATE INDEX idx_cedar_town ON uk_price_paid_ingest(town);
CREATE INDEX idx_cedar_type ON uk_price_paid_ingest(type);
CREATE INDEX idx_cedar_date_type ON uk_price_paid_ingest(date, type);
CREATE INDEX idx_cedar_town_date ON uk_price_paid_ingest(town, date);

ANALYZE uk_price_paid_ingest;
SQL
```

---

## Final Validation (must match)

```bash
# ClickHouse
docker exec clickhouse_server clickhouse-client \
  --query "SELECT count() FROM uk_price_paid"

# CedarDB
PGPASSWORD=cedardbre psql -h localhost -p 5433 -U postgres -d postgres \
  -c "SELECT count(*) FROM uk_price_paid_ingest;"

# PostgreSQL + pg_clickhouse
PGPASSWORD=pgdbre psql -h localhost -p 5434 -U postgres -d postgres \
  -c "SELECT count(*) FROM uk_price_paid;"

# PostgreSQL HEAP
PGPASSWORD=pgdbre psql -h localhost -p 5434 -U postgres -d postgres \
  -c "SELECT count(*) FROM uk_price_paid_pg;"
```

Expected result everywhere:

```
30729146
```

---

## What this benchmark is NOT

* ❌ Not a micro-benchmark
* ❌ Not TPC-H / TPC-DS
* ❌ Not engine-tuning competition
* ❌ Not storage or compression comparison

This lab focuses on **execution behavior** under realistic analytical workloads.

---

## Next steps (planned)

* Query suite comparison
* EXPLAIN / EXPLAIN ANALYZE diffs
* Memory usage comparison
* MVCC vs immutable storage analysis
* Pushdown vs native execution cost

---

## Author

Built by a practicing DBRE exploring **how execution engines behave in the real world**.

