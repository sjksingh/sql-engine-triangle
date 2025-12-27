-- ClickHouse initialization script
-- This creates sample tables with sample data

-- Create a MergeTree table for sales demo
CREATE TABLE IF NOT EXISTS default.sales_data
(
    id UInt64,
    product_name String,
    category String,
    price Decimal(10, 2),
    quantity UInt32,
    sale_date Date,
    created_at DateTime
)
ENGINE = MergeTree()
ORDER BY (sale_date, id)
PARTITION BY toYYYYMM(sale_date);

-- Insert sample data
INSERT INTO default.sales_data VALUES
(1, 'Laptop', 'Electronics', 999.99, 5, '2024-01-15', '2024-01-15 10:30:00'),
(2, 'Mouse', 'Electronics', 29.99, 50, '2024-01-15', '2024-01-15 11:00:00'),
(3, 'Keyboard', 'Electronics', 79.99, 30, '2024-01-16', '2024-01-16 09:15:00'),
(4, 'Monitor', 'Electronics', 299.99, 15, '2024-01-16', '2024-01-16 14:20:00'),
(5, 'Desk Chair', 'Furniture', 199.99, 10, '2024-01-17', '2024-01-17 16:45:00'),
(6, 'Standing Desk', 'Furniture', 499.99, 8, '2024-01-18', '2024-01-18 10:00:00'),
(7, 'Webcam', 'Electronics', 89.99, 25, '2024-01-19', '2024-01-19 13:30:00'),
(8, 'Headphones', 'Electronics', 149.99, 20, '2024-01-20', '2024-01-20 11:15:00');

-- Create another example table for analytics
CREATE TABLE IF NOT EXISTS default.user_events
(
    user_id UInt64,
    event_type String,
    event_time DateTime,
    page_url String,
    duration UInt32
)
ENGINE = MergeTree()
ORDER BY (event_time, user_id)
PARTITION BY toYYYYMMDD(event_time);

-- Insert sample user events
INSERT INTO default.user_events VALUES
(101, 'page_view', '2024-01-15 10:00:00', '/home', 45),
(101, 'click', '2024-01-15 10:01:30', '/products', 120),
(102, 'page_view', '2024-01-15 10:05:00', '/home', 30),
(102, 'page_view', '2024-01-15 10:06:00', '/about', 60),
(103, 'page_view', '2024-01-15 10:10:00', '/products', 90),
(103, 'click', '2024-01-15 10:12:00', '/product/123', 180);

-- Create UK Price Paid table schema (data loaded separately via CSV)
CREATE TABLE IF NOT EXISTS default.uk_price_paid
(
    price UInt32,
    date Date,
    postcode1 LowCardinality(String),
    postcode2 LowCardinality(String),
    type Enum8('terraced' = 1, 'semi-detached' = 2, 'detached' = 3, 'flat' = 4, 'other' = 0),
    is_new UInt8,
    duration Enum8('freehold' = 1, 'leasehold' = 2, 'unknown' = 0),
    addr1 String,
    addr2 String,
    street LowCardinality(String),
    locality LowCardinality(String),
    town LowCardinality(String),
    district LowCardinality(String),
    county LowCardinality(String)
)
ENGINE = MergeTree
ORDER BY (postcode1, postcode2, addr1, addr2)
PARTITION BY toYYYYMM(date)
SETTINGS index_granularity = 8192;

