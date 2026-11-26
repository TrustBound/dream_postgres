# Contributing to dream_postgres

Thank you for your interest in contributing to dream_postgres! We're excited to have you here.

dream_postgres is part of the [Dream](https://github.com/TrustBound/dream) family of packages. It follows Dream's coding and testing standards. Those standards live in the Dream repository, so every Dream package uses the same rules.

## Quick Links

📖 **[Full Contributing Guide](https://github.com/TrustBound/dream/blob/release/3.0.0/docs/contributing/contributing.md)** - Detailed contribution guidelines  
🧪 **[Testing Guide](https://github.com/TrustBound/dream/blob/release/3.0.0/docs/contributing/testing.md)** - How Dream packages are tested  
✍️ **[Tone Guide](https://github.com/TrustBound/dream/blob/release/3.0.0/docs/contributing/tone-guide.md)** - Documentation writing style  
🤝 **[Code of Conduct](CODE_OF_CONDUCT.md)** - Community standards  
🔒 **[Security Policy](SECURITY.md)** - Reporting security vulnerabilities

## Quick Start for Contributors

### Prerequisites

- Gleam 1.19.2 or later
- Erlang/OTP 28 or later, with the JIT (the test run measures line coverage)
- Docker with Docker Compose, for the two PostgreSQL 16 servers that the tests run against

Many tests run queries on a real PostgreSQL server. `make db-up` starts two from `docker-compose.yml`, both with the user `dream`, the password `dream` and the database `dream_test`, and both keep no data:

- `postgres`, on port 5436, with SSL off. Most tests use it. To use another server, set `DREAM_POSTGRES_TEST_URL` to its URL.
- `postgres-ssl`, on port 5437, with SSL on. The SSL tests (`test/postgres_ssl_test.gleam`) use it. Its certificate and the test CA that signed it are in `test/fixtures/ssl`, which also says how they were made. They are for the tests only. The certificate names only `localhost`, so the tests connect to `localhost` for a matching host name and to `127.0.0.1` for one that does not match.

When a server does not answer, `make test` stops at once with a message that says so. The SSL tests change the CA list of the whole BEAM, so they run one at a time, after the other tests.

### Packages that are not on Hex yet

Version 2.1.0 needs `dream_postgres_client` 1.1.0, `dream_postgres_driver` 1.1.0 and `dream_errors` 1.0.0. Until these are on Hex, the build uses local copies, and CI fails at `gleam deps download`. `manifest.toml` holds their entries with a checksum of zeros.

1. Clone `dream_postgres_client`, `dream_postgres_driver` and `dream_errors`, and check out the release version of each.
2. Run `sh scripts/stand-ins.sh` in this repository. Set `DREAM_POSTGRES_CLIENT_SOURCE`, `DREAM_POSTGRES_DRIVER_SOURCE` and `DREAM_ERRORS_SOURCE` to the clones, and `DREAM_POSTGRES_CLIENT_COMMIT`, `DREAM_POSTGRES_DRIVER_COMMIT` and `DREAM_ERRORS_COMMIT` when the release version is not the checked-out commit.

The script copies each package into `build/packages` and lists it in `packages.toml`, so Gleam makes no Hex request for it. When these packages are on Hex, remove `scripts/stand-ins.sh` and this section, and run `gleam deps update dream_postgres_client dream_postgres_driver dream_errors` to write the real checksums.

### Development Setup

1. **Fork and clone:**
   ```bash
   git clone https://github.com/YOUR-USERNAME/dream_postgres.git
   cd dream_postgres
   ```

2. **Run tests:**
   ```bash
   make db-up               # Start the two test PostgreSQL servers
   make test                # All tests, with line coverage
   make check               # Format check, build, tests and docs build
   make db-down             # Stop the two test PostgreSQL servers
   ```

3. **Make your changes:**
   - Write code following Dream's [design principles](https://github.com/TrustBound/dream/blob/release/3.0.0/docs/reference/design-principles.md)
   - Add tests for new functionality
   - Update documentation as needed

4. **Format and verify:**
   ```bash
   gleam format             # Format code
   make check               # Ensure everything passes
   ```

5. **Submit a pull request:**
   - Clear description of changes
   - Reference any related issues
   - Ensure CI passes

## What Can I Contribute?

### 🐛 Bug Reports
Found a bug? [Open an issue](https://github.com/TrustBound/dream_postgres/issues/new) with:
- Clear description of the problem
- Steps to reproduce
- Expected vs actual behavior
- Your environment (Gleam version, OS, etc.)

### 💡 Feature Requests
Have an idea? [Open an issue](https://github.com/TrustBound/dream_postgres/issues/new) with:
- Clear use case
- Proposed API or behavior
- Why this fits Dream's philosophy

### 📝 Documentation
Documentation improvements are always welcome:
- Fix typos or unclear explanations
- Add examples
- Improve guides

### 🔧 Code Contributions
- Fix bugs
- Implement approved features
- Improve performance
- Add tests

## Code Standards

dream_postgres follows Dream's strict coding standards. Please read:
- **[Design Principles](https://github.com/TrustBound/dream/blob/release/3.0.0/docs/reference/design-principles.md)** - The "why" behind Dream
- **[Naming Conventions](https://github.com/TrustBound/dream/blob/release/3.0.0/docs/reference/naming-conventions.md)** - Code style rules

Key principles:
- **No magic** - Everything explicit
- **No closures** - All dependencies are parameters
- **Full words** - No abbreviations (except standard ones)
- **100% test coverage** - For `src/` code
- **Black box testing** - Test public interfaces only

## Development Workflow

1. **Create a branch:**
   ```bash
   git checkout -b feature/my-feature
   # or
   git checkout -b fix/issue-123
   ```

2. **Make focused commits:**
   ```bash
   git commit -m "Add an sslrootcert URL parameter"
   ```

3. **Keep your fork updated:**
   ```bash
   git remote add upstream https://github.com/TrustBound/dream_postgres.git
   git fetch upstream
   git rebase upstream/main
   ```

4. **Push and create PR:**
   ```bash
   git push origin feature/my-feature
   ```

## Testing Requirements

All contributions must include tests:

- **Unit tests** - Fast, isolated, deterministic
- **100% coverage** - For all code in `src/`. `gleam test` fails below 100%.
- **Tested snippets** - Every code block in the README and in the HexDocs comes from a file in `test/snippets/` that the tests run

See Dream's [Testing Guide](https://github.com/TrustBound/dream/blob/release/3.0.0/docs/contributing/testing.md) for details.

## Documentation Requirements

Update documentation for:
- New features (HexDocs + README)
- API changes (update all references)
- Breaking changes (migration notes in CHANGELOG.md)

## Review Process

1. **Automated checks:**
   - Code formatting (`gleam format`)
   - Unit tests and 100% coverage
   - Documentation build
   - No compiler warnings

2. **Manual review:**
   - Code quality
   - Tests coverage
   - Documentation
   - Fits Dream's philosophy

3. **Maintainer approval:**
   - At least one maintainer approval required
   - May request changes or clarification

## Getting Help

- **Questions?** [Open a discussion](https://github.com/TrustBound/dream/discussions)
- **Stuck?** Comment on your PR or issue
- **Security issue?** See [SECURITY.md](SECURITY.md)

## Recognition

All contributors are recognized in our documentation and release notes. Thank you for making dream_postgres better! 🎉

## About Dream

Dream was created by [TrustBound](https://trustbound.ai), an AI security platform, to build our production SaaS. We needed a type-safe web toolkit that was explicit, composable, and ran on the BEAM for massive concurrency.

We built Dream, used it to build TrustBound, and open-sourced it under MIT license so others could benefit.

Dream is community-driven. TrustBound funds development, but contributions come from everyone. All decisions happen in public issues and discussions.

---

**Read more:** [Full Contributing Guide](https://github.com/TrustBound/dream/blob/release/3.0.0/docs/contributing/contributing.md)
