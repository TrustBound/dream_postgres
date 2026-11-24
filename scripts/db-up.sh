#!/bin/sh
# Starts the two PostgreSQL servers of docker-compose.yml and waits until
# each accepts connections: one with SSL off, one with SSL on. "make db-up"
# runs this script, and CI runs it before the tests.
set -eu

docker compose up -d --wait postgres
docker compose up -d --wait postgres-ssl
echo "PostgreSQL 16 accepts connections at postgresql://dream:dream@localhost:5436/dream_test"
echo "PostgreSQL 16 with SSL on accepts connections at postgresql://dream:dream@localhost:5437/dream_test"
