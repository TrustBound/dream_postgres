# dream_postgres Makefile

.PHONY: test build format check docs clean

# Run the tests with line coverage (fails below 100%)
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

# Generate documentation
docs:
	@gleam docs build

# Clean build artifacts
clean:
	@gleam clean
	@rm -f erl_crash.dump
