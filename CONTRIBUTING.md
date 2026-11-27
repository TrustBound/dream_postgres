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
- Docker with Docker Compose, for the PostgreSQL servers that the tests run against

Many tests run queries on a real PostgreSQL server. `make db-up` starts nine from `docker-compose.yml`, all with the user `dream`, the password `dream` and the database `dream_test`, and all keep their data in memory, so each start gives an empty database. Each one uses the image `dream-test-postgres:<version>`: `postgres:<version>-alpine` with pgvector, which `test/docker/Dockerfile` builds when the image is not there yet. At the first start, `test/docker/extensions.sql` makes the extensions `hstore`, `ltree`, `citext` and `vector`.

- `postgres`, on port 5436, with SSL off. Most tests use it. To use another server, set `DREAM_POSTGRES_TEST_URL` to its URL.
- `postgres-ssl`, on port 5437, with SSL on. The SSL tests (`test/postgres_ssl_test.gleam`) use it. Its certificate and the test CA that signed it are in `test/fixtures/ssl`, which also says how they were made. They are for the tests only. The certificate names only `localhost`, so the tests connect to `localhost` for a matching host name and to `127.0.0.1` for one that does not match.
- `postgres-17`, `postgres-18` and `postgres-19`, on ports 5438, 5439 and 5440, for the type proof. Give the proof the URLs of all four versions in `DREAM_POSTGRES_PROOF_URLS`, divided by commas, as CI does.
- `driver-16`, `driver-17`, `driver-18` and `driver-19`, on ports 5441, 5442, 5443 and 5444, for the driver tests (`test/driver`), which run on all four. Each has SSL on with the certificate of `test/fixtures/ssl`. `test/docker/driver_pg_hba.conf` gives each database user its own login method: `dream` uses SCRAM-SHA-256, `dream_trust` needs no password, `dream_cleartext` sends a cleartext password, `dream_md5` uses MD5, and `dream_tls` uses SCRAM-SHA-256 over TLS only. `test/docker/driver_users.sql` makes these users, all with the password `dream`.

When a server does not answer, `make test` stops at once with a message that says so. The SSL tests change the CA list of the whole BEAM, so they run one at a time, after the other tests.

### Development Setup

1. **Fork and clone:**
   ```bash
   git clone https://github.com/YOUR-USERNAME/dream_postgres.git
   cd dream_postgres
   ```

2. **Run tests:**
   ```bash
   make db-up               # Start the test PostgreSQL servers
   make test                # All tests, with line coverage
   make check               # Format check, build, tests and docs build
   make db-down             # Stop the test PostgreSQL servers
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
