#!/bin/sh
# Starts the PostgreSQL servers of docker-compose.yml and waits until each
# accepts connections: 16 with SSL off and on, 17 to 19 for the type proof,
# and the driver servers for 16 to 19. "make db-up" and CI run this script.
set -eu

docker compose up -d --wait postgres
docker compose up -d --wait postgres-ssl
docker compose up -d --wait postgres-17 postgres-18 postgres-19
docker compose up -d --wait driver-16 driver-17 driver-18 driver-19
echo "PostgreSQL 16 accepts connections at postgresql://dream:dream@localhost:5436/dream_test"
echo "PostgreSQL 16 with SSL on accepts connections at postgresql://dream:dream@localhost:5437/dream_test"
echo "PostgreSQL 17, 18 and 19 accept connections on ports 5438, 5439 and 5440"
echo "The driver servers for PostgreSQL 16, 17, 18 and 19 accept connections on ports 5441, 5442, 5443 and 5444"
