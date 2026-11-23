# dream_postgres Makefile

.PHONY: test build format check check-snippets docs clean db-up db-down

# Run the tests with line coverage (fails below 100%). The tests need the
# two PostgreSQL servers of docker-compose.yml: start them with `make db-up`.
# The test run stops at once with a message when a server does not answer.
test:
	@gleam test

# Build the package
build:
	@gleam build

# Format code
format:
	@gleam format src test

# Run everything CI runs: format check, build, tests and docs build
check:
	@gleam format --check src test
	@gleam build
	@gleam test
	@gleam docs build
	@gleam run -m dream_snippets

# Check that each code block in the docs matches a tested snippet
check-snippets:
	@gleam run -m dream_snippets

# Generate documentation
docs:
	@gleam docs build

# Start the two test PostgreSQL servers and wait until they accept
# connections: one with SSL off, one with SSL on
db-up:
	@docker compose up -d --wait postgres postgres-ssl
	@echo "PostgreSQL 16 accepts connections at postgresql://dream:dream@localhost:5436/dream_test"
	@echo "PostgreSQL 16 with SSL on accepts connections at postgresql://dream:dream@localhost:5437/dream_test"

# Stop the two test PostgreSQL servers and remove their containers (they keep
# no data)
db-down:
	@docker compose down

# Clean build artifacts
clean:
	@gleam clean
	@rm -f erl_crash.dump
