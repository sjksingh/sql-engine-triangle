#!/bin/bash
set -e

# Execute the default PostgreSQL entrypoint
exec docker-entrypoint.sh "$@"
