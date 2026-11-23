# Changelog

All notable changes to `dream_postgres` will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.0] - Unreleased

### Changed (breaking)
- `postgres.from_url()` now returns `Result(Connection, FromUrlError)`.
  Before, it returned `Connection` and stopped the calling process with a
  `let assert` when the pool did not start, so a caller could not handle the
  failure.
  - Before: `pub fn from_url(url: String) -> Connection`
  - After: `pub fn from_url(url: String) -> Result(Connection, FromUrlError)`
  - Upgrade: handle the `Result`, for example
    `case postgres.from_url(url) { Ok(db) -> ... Error(error) -> ... }`.
- `postgres.from_url()` now returns `Error(InvalidUrl(UrlError))` for a URL it
  cannot read. Before, it used default values for the parts it could not
  find. URLs with a query parameter other than `sslmode` or
  `application_name`, a `sslmode` other than `disable`, `require`,
  `verify-ca` or `verify-full`, a fragment, no host or no database now give
  an error. Upgrade: remove the unsupported parts from the URL, or use the
  builder functions for those settings.

### Changed
- Moved to its own repository
- The package has three guides in `docs/guides/`: Getting started,
  Connecting to PostgreSQL in production, and Running queries and handling
  their results. Each guide walks through a task from start to finish, with
  tested code, the failure cases, a test and the common pitfalls. The README
  is short and links to them, and HexDocs shows the guides.

### Added
- `postgres.parse_config(pool_name, url) -> Result(Config, UrlError)` reads
  a connection URL into a `Config` and does not connect.
- `UrlError` says what is wrong with a URL: `MalformedUrl`, `MissingScheme`,
  `UnsupportedScheme`, `MissingHost`, `InvalidPort`, `MissingDatabase`,
  `InvalidDatabase`, `MissingUser`, `InvalidUserEncoding`,
  `InvalidPasswordEncoding`, `InvalidDatabaseEncoding`,
  `UnsupportedParameter`, `UnsupportedSslMode` and `UnsupportedFragment`.
- `postgres.check(connection) -> Result(Nil, QueryError)` runs `SELECT 1`
  and gives `Ok(Nil)` when the database answers, or the error of the query.
  `connect` and `from_url` return `Ok` before the pool connects, so call
  `check` after them to stop at startup when the database does not answer.
  When no database listens, the password is wrong, the database does not
  exist or the pool size is 0, the error is `pog.ConnectionUnavailable`,
  after about 2 seconds. The guides use it for their startup check.
- `FromUrlError` holds a `UrlError` or the reason the pool did not start:
  `InvalidUrl` and `PoolStartExited`.
  No error value holds the password.
- The `sslmode` query parameter sets the SSL mode. `verify-ca` and
  `verify-full` both give `pog.SslVerified`, which checks the certificate
  and the host name, so `verify-ca` checks more than in `libpq`. The client
  trusts the CA certificates of the operating system. The connecting guide
  shows how to trust a private CA. `application_name`
  sets the PostgreSQL connection parameter with that name in the config. With
  Pog 4.1, the server does not see it: pgo sends the Erlang node name as
  `application_name` after it. An IPv6 host such as `[::1]` sets IPv6.

### Fixed
- `postgres.from_url()` read the user and the password wrongly. For
  `postgresql://user:pass@localhost:5432/myapp` it used the user `postgres`
  and no password. It now reads the URL with `gleam/uri` and gets the user
  `user` and the password `pass`. The user, the password and the database
  are percent-decoded.
- `postgres.from_url()` kept the query string in the database name. For
  `.../myapp?sslmode=require` the database was `myapp?sslmode=require`. The
  database is now `myapp`, and `sslmode` sets the SSL mode.

### Testing

- 195 tests, 0 failed, 100.0% line coverage. `make test` takes about 45 seconds, and the test times add up to about 77 seconds, because 4 tests run at a time. The 17 SSL tests run one at a time. Apple M1 Max, 10 cores, 64 GB, macOS 26.5.1, OTP 29, Gleam 1.19.2.
- The tests run against two PostgreSQL 16 servers (the `postgres:16-alpine` image), started with `make db-up`. One has SSL off. It runs as a service container in CI. The other has SSL on, with a test CA and a server certificate from `test/fixtures/ssl`. CI starts it with `docker compose`.

## [1.0.2] - 2025-11-21

### Changed
- Added HexDocs documentation badge to README

## [1.0.1] - 2025-11-22

### Fixed
- Fixed logo display on hex.pm by using full GitHub URL
- Added Dream logo to README

## [1.0.0] - 2025-11-21

### Added
- Initial stable release
- Builder pattern for PostgreSQL connection configuration
- `postgres.from_url()` - Connect from PostgreSQL connection URL
- `query.first_row()` - Extract first row from query result
- `query.all_rows()` - Extract all rows from query result
- Simplified error handling with `QueryError` type
- Integration with Pog for connection pooling

