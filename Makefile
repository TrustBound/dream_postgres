# dream_postgres Makefile

.PHONY: test test-playback build format check check-snippets docs clean db-up db-down

# Run the tests with line coverage (fails below 100%). The tests need the
# PostgreSQL servers of docker-compose.yml: start them with `make db-up`.
# The test run stops at once with a message when a server does not answer.
test:
	@gleam test

# Run only the recorder tests that need no database. They pass with both
# test servers stopped (`make db-down`), which proves that playback mode
# opens no connection.
test-playback:
	@gleam run -m recorder_playback_main

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

# Start the test PostgreSQL servers and wait until they accept connections:
# PostgreSQL 16 with SSL off and with SSL on, PostgreSQL 17, 18 and 19 for
# the type proof, and the driver servers for PostgreSQL 16 to 19 (CI runs the
# same script)
db-up:
	@sh scripts/db-up.sh

# Stop the test PostgreSQL servers and remove their containers (they keep
# no data)
db-down:
	@docker compose down

# Clean build artifacts
clean:
	@gleam clean
	@rm -f erl_crash.dump
