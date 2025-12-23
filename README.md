OLAP Benchmark : ClickHouse vs Cedar vs PostgreSQL

Once docker-compose is completed 

```
docker-compose ps -a
NAME                IMAGE                                            COMMAND                  SERVICE      CREATED       STATUS                 PORTS
cedardb_server      cedardb/cedardb:latest                           "/usr/local/bin/dock…"   cedardb      4 hours ago   Up 4 hours             0.0.0.0:5433->5432/tcp, [::]:5433->5432/tcp
clickhouse_server   clickhouse/clickhouse-server:latest              "/entrypoint.sh"         clickhouse   4 hours ago   Up 4 hours (healthy)   0.0.0.0:8123->8123/tcp, [::]:8123->8123/tcp, 0.0.0.0:9000->9000/tcp, [::]:9000->9000/tcp, 9009/tcp
pg18_clickhouse     sjksingh/postgres-18-pgclickhouse-cedar:latest   "/custom-entrypoint.…"   postgres     4 hours ago   Up 4 hours (healthy)   0.0.0.0:5434->5432/tcp, [::]:5434->5432/tcp
```


# 1 - ingest data into clickhouse. 

bash 1-lickhuse-ingest.sh

```
#!/bin/bash
# clickhouse_ingest.sh
# Stream UK price paid CSV into ClickHouse

set -euo pipefail

# Config
CLICKHOUSE_CONTAINER=${CLICKHOUSE_CONTAINER:-clickhouse_server}
CSV_GZ_FILE=${CSV_GZ_FILE:-uk_price_paid.csv.gz}
TABLE=${TABLE:-default.uk_price_paid}

echo "Starting ClickHouse ingestion..."
echo "Container: $CLICKHOUSE_CONTAINER"
echo "CSV file: $CSV_GZ_FILE"
echo "Table: $TABLE"

# Stream CSV.gz directly into ClickHouse
zcat "$CSV_GZ_FILE" | docker exec -i "$CLICKHOUSE_CONTAINER" \
    clickhouse-client --query "INSERT INTO $TABLE FORMAT CSV"

echo "ClickHouse ingestion completed!"
```

Verify - should return 30 millon rows 

```
docker exec -it clickhouse_server clickhouse-client --query "SELECT count() FROM uk_price_paid"
```

#2 - Create the ingest table in CedarDB (minimal, no indexes)
```
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

3) Stream ClickHouse → CedarDB using a single command (the meat)

```
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
| PGPASSWORD=cedardbre psql -h localhost -p 5433 -U postgres -d postgres -c "\copy uk_price_paid_ingest FROM STDIN WITH (FORMAT csv, HEADER true)"
```

Verify. This should return 30729146 rows  

```
docker exec -it \
  -e PGPASSWORD=cedardbre \
  cedardb_server \
  psql -U postgres -d postgres \
  -c "SELECT count(*) FROM uk_price_paid_ingest;"
```


4) Create Postgres heap table + same dataset. 

```
PGPASSWORD=pgdbre psql -h localhost -p 5434 -U postgres -d postgres -v ON_ERROR_STOP=1 <<'SQL'
-- safe: drop if exists so repeated runs are idempotent
DROP TABLE IF EXISTS uk_price_paid_pg;

CREATE TABLE uk_price_paid_pg (
    price     INTEGER NOT NULL,
    date      DATE NOT NULL,
    postcode1 VARCHAR(8) NOT NULL,      -- Being conservative for UK postcodes
    postcode2 VARCHAR(4) NOT NULL,
    type      VARCHAR(15) NOT NULL,     -- 'semi-detached' is longest at 13 chars
    is_new    BOOLEAN NOT NULL,         -- Convert smallint to boolean
    duration  VARCHAR(10) NOT NULL,     -- 'freehold', 'leasehold', 'unknown'
    addr1     VARCHAR(200),
    addr2     VARCHAR(200),
    street    VARCHAR(200),
    locality  VARCHAR(100),
    town      VARCHAR(100) NOT NULL,
    district  VARCHAR(100),
    county    VARCHAR(100)
);
SQL
```

```
PGPASSWORD=pgdbre psql -h localhost -p 5434 -U postgres -d postgres -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO uk_price_paid_pg
SELECT
    price,
    date,
    postcode1,
    postcode2,
    type,
    CASE WHEN is_new = 1 THEN true ELSE false END,  -- Convert to boolean
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

Verify. This should return 30729146 rows  

```
docker exec -it \
  -e PGPASSWORD=pgdbre \
  pg18_clickhouse \
  psql -U postgres -d postgres \
  -c "SELECT count(*) FROM uk_price_paid_pg;"
```

Create index on postgres HEAP table... 
```
PGPASSWORD=pgdbre psql -h localhost -p 5434 -U postgres -d postgres -v ON_ERROR_STOP=1 <<'SQL'
-- Create optimal indexes for analytical queries
CREATE INDEX idx_uk_price_paid_pg_date ON uk_price_paid_pg(date);
CREATE INDEX idx_uk_price_paid_pg_town ON uk_price_paid_pg(town);
CREATE INDEX idx_uk_price_paid_pg_type ON uk_price_paid_pg(type);
CREATE INDEX idx_uk_price_paid_pg_postcode ON uk_price_paid_pg(postcode1, postcode2);
CREATE INDEX idx_uk_price_paid_pg_date_type ON uk_price_paid_pg(date, type);
CREATE INDEX idx_uk_price_paid_pg_town_date ON uk_price_paid_pg(town, date);
CREATE INDEX idx_uk_price_paid_pg_type_date_price ON uk_price_paid_pg(type, date, price);
CREATE INDEX idx_uk_price_paid_pg_county_type_date ON uk_price_paid_pg(county, type, date) WHERE county IS NOT NULL;
--- for aggregations
CREATE INDEX idx_uk_price_paid_pg_county_town ON uk_price_paid_pg(county, town);

-- Analyze for query planner
ANALYZE uk_price_paid_pg;

-- Check the result
SELECT COUNT(*) FROM uk_price_paid_pg;
SQL
```



Create indexes on Cedar database... 
```
PGPASSWORD=cedardbre psql -h localhost -p 5433 -U postgres -d postgres -v ON_ERROR_STOP=1 <<'SQL'
CREATE INDEX IF NOT EXISTS idx_cedar_date ON uk_price_paid_ingest(date);
CREATE INDEX IF NOT EXISTS idx_cedar_town ON uk_price_paid_ingest(town);
CREATE INDEX IF NOT EXISTS idx_cedar_type ON uk_price_paid_ingest(type);
CREATE INDEX IF NOT EXISTS idx_cedar_date_type ON uk_price_paid_ingest(date, type);
CREATE INDEX IF NOT EXISTS idx_cedar_town_date ON uk_price_paid_ingest(town, date);
SQL
```
