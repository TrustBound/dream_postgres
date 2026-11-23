# dream_postgres Makefile

.PHONY: test build format check check-snippets docs clean db-up db-down

# Run the tests with line coverage (fails below 100%). The tests need the
# PostgreSQL server of docker-compose.yml: start it with `make db-up`. The
# test run stops at once with a message when the server does not answer.
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

# Start the test PostgreSQL server and wait until it accepts connections
db-up:
	@docker compose up -d --wait postgres
	@echo "PostgreSQL 16 accepts connections at postgresql://dream:dream@localhost:5436/dream_test"

# Stop the test PostgreSQL server and remove its container (it keeps no data)
db-down:
	@docker compose down

# Clean build artifacts
clean:
	@gleam clean
	@rm -f erl_crash.dump
