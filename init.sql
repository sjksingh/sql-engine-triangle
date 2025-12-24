-- PostgreSQL 18 + pg_clickhouse initialization script

-- Create pg_clickhouse extension
CREATE EXTENSION IF NOT EXISTS pg_clickhouse;

-- Create a ClickHouse foreign server (connecting to our ClickHouse container)
CREATE SERVER clickhouse_server
    FOREIGN DATA WRAPPER clickhouse_fdw
    OPTIONS (
        host 'clickhouse',  -- container name from docker-compose
        port '8123',        -- HTTP port (NOT 9000 which is native protocol)
        dbname 'default'
    );

-- Create user mapping
CREATE USER MAPPING FOR postgres
    SERVER clickhouse_server
    OPTIONS (
        user 'default',
        password 'chidbre'
    );

-- Verify installation
SELECT extname, extversion FROM pg_extension WHERE extname = 'pg_clickhouse';

-- Create foreign table for sales_data (from clickhouse-init/01-create-table.sql)
CREATE FOREIGN TABLE sales_data (
    id bigint,
    product_name text,
    category text,
    price numeric,
    quantity integer,
    sale_date date,
    created_at timestamp
)
SERVER clickhouse_server
OPTIONS (table_name 'sales_data');

-- Create foreign table for user_events (from clickhouse-init/01-create-table.sql)
CREATE FOREIGN TABLE user_events (
    user_id bigint,
    event_type text,
    event_time timestamp,
    page_url text,
    duration integer
)
SERVER clickhouse_server
OPTIONS (table_name 'user_events');

-- Create foreign table for uk_price_paid
-- NOTE: You must manually load the CSV data first!
-- Run: zcat uk_price_paid.csv.gz | docker exec -i clickhouse_server clickhouse-client --query "INSERT INTO default.uk_price_paid FORMAT CSV"
CREATE FOREIGN TABLE uk_price_paid (
    price integer,
    date date,
    postcode1 text,
    postcode2 text,
    type text,
    is_new smallint,
    duration text,
    addr1 text,
    addr2 text,
    street text,
    locality text,
    town text,
    district text,
    county text
)
SERVER clickhouse_server
OPTIONS (table_name 'uk_price_paid');

-- Create pg_partman extension
CREATE EXTENSION IF NOT EXISTS pg_partman;

-- Create pg_cron extension
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Verify all extensions are installed
SELECT extname, extversion FROM pg_extension
WHERE extname IN ('pg_clickhouse', 'pg_partman', 'pg_cron')
ORDER BY extname;
