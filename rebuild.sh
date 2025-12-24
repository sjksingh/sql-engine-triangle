#!/bin/bash
# Stop and remove container
docker-compose down -v

# (Optional) Remove dangling volumes if any
docker volume prune -f

# Rebuild and restart
docker-compose up --build -d

# Show logs
echo "Container starting... Showing logs:"
docker-compose logs -f
