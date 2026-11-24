# Changelog

All notable changes to `dream_postgres` will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.0] - Unreleased

### Changed (breaking)
- The package now uses `dream_pog`, a fork of Pog 4.1.0 on the driver
  `dream_pgo`, a fork of pgo 0.20.0, in place of `pog`. The API is the
  same, but the module name is `dream_pog`.
  - Before: `import pog`, and `pog` in `[dependencies]`
  - After: `import dream_pog as pog`, and `dream_pog` in `[dependencies]`
  - Upgrade: replace `pog` with `dream_pog` in `gleam.toml`, and
    `import pog` with `import dream_pog as pog`. The rest of the code stays
    the same. `postgres.Config`, `Connection` and the other types are the
    `dream_pog` types now.
- `sslmode=verify-ca` now gives `pog.SslVerifiedChainOnly`, the meaning of
  `libpq`: it checks that a trusted CA signed the certificate, but not the
  host name. Before, it gave `pog.SslVerified`, which also checks the host
  name. `sslmode=verify-full` still gives `pog.SslVerified`. Upgrade: use
  `verify-full` where you want the host name checked.
- `parse_config` and `connect` no longer put `client_encoding` before an
  `application_name` in the connection parameters, and they no longer drop
  an earlier `application_name`. That order was a workaround for a pgo bug
  that lost the caller's `application_name`. `dream_pgo` fixes the bug: the
  caller's `application_name` reaches the server in any order, also from a
  config that goes to `pog.start` or `pog.supervised` without `connect`.
  The name has no case, as in PostgreSQL: `Application_Name` also reaches
  the server. The real-server tests of the name pass without the workaround.
  - Before: `?application_name=billing` gave
    `[#("client_encoding", "UTF8"), #("application_name", "billing")]`
  - After: it gives `[#("application_name", "billing")]`, and the server
    keeps its default `client_encoding`
  - Upgrade: none, unless your code reads `config.connection_parameters`.
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
  find. URLs with a `libpq` connection keyword other than `sslmode`,
  `application_name` and `options` (for example `connect_timeout`),
  `database`, a name one edit from a keyword (for example `sslmod`), a
  `sslmode` other than `disable`, `require`, `verify-ca` or `verify-full`, a
  fragment, no host, no database, a name that starts with `_pq_.` and `%00` in
  the user, the password, the database name or a query parameter now give
  an error. Upgrade: remove the unsupported parts from the URL, or use the
  builder functions for those settings.

### Changed
- Moved to its own repository
- The package has three guides in `docs/guides/`: Getting started,
  Connecting to PostgreSQL in production, and Running queries and handling
  their results. Each guide walks through a task from start to finish, with
  tested code, the failure cases, a test and the common pitfalls. The README
  is short and links to them, and HexDocs shows the guides. Each output
  block of the guides is a file in `test/outputs/` that a test compares
  with the real output, and the SQL, the `docker-compose.yml` service and
  the commands are copies of the files that the tests and CI use.
- The connecting guide trusts a private CA with `sslrootcert` or
  `pog.SslVerifiedCaFile` for one pool. Before, it loaded the CA file into
  the CA list of the whole BEAM with `public_key:cacerts_load`.

### Added
- Query recording: the new modules `dream_postgres/recorder` and
  `dream_postgres/recording`. A recorder keeps the queries of one test in
  one JSON file, in the modes `Record`, `Playback` and `Passthrough`.
  - The mode is a typed value, `recorder.Mode`, so a wrong mode name is a
    compile error: `recorder.mode(recorder.Playback)`. For a mode in a
    text, for example from an environment variable, use
    `recorder.parse_mode(text)`. It accepts `"record"`, `"playback"` and
    `"passthrough"`, and gives an `Error` that names any other text.
  - Record mode runs each query on the database, and writes the query, its
    parameters and its result (the count and the rows, or the error) to
    the file before the query returns. A query in `pog.transaction` is
    recorded too.
  - Playback mode starts no pool and opens no connection
    (`pog.disconnected`). Each query gets the result of its recording. A
    query with no recording fails with `pog.InterceptorFailed`, and never
    reaches a database.
  - `recorder.error(query_error)` reads a `recorder.RecorderError` back from
    a query error that the recorder made: `NoRecording(sql, parameters,
    path)`, `PlayedAlready(sql, parameters, path)`, `WriteFailed(path,
    reason)`, `NotRecordable(sql, reason)` or `RecorderStopped(sql)`. It
    gives `Error(Nil)` for any other query error, also for the
    `pog.InterceptorFailed` of another interceptor.
  - In record mode, a query fails when the recorder cannot record it: the
    file cannot be written, a parameter or a value of the result cannot be
    recorded, or the recorder stopped. `recorder.stop` gives an `Error` only
    when the recorder had stopped already.
  - A query matches the first recording with its key that it was not given
    yet. The keys are `sql_and_parameters` (the default),
    `normalized_sql_and_parameters`, `sql_only`, or a function of your own.
  - A query transformer and a result transformer hide secrets before the
    file is written.
  - Every kind of value that the driver returns comes back the same in
    playback: integers, floats, text, `bytea`, booleans, `NULL`, arrays,
    timestamps, dates, times, numerics, UUIDs, JSON, intervals, bits and
    rows as maps. A test against PostgreSQL 16 proves each one.
  - The file format has a version (1), one key order and one line for each
    row, so a diff shows only what changed. `recording.to_json` and
    `recording.from_json` write and read it.
  - The guide "Test database code with recorded queries" walks through it.
- `sslrootcert` in a URL: the path of a PEM file with the CA certificates
  that the pool trusts, or `system`. With the `sslmode`, it gives
  `pog.SslVerifiedCaFile(path)`, `pog.SslVerifiedChainOnlyCaFile(path)`,
  `pog.SslVerified` or `pog.SslDisabled`, by the same rules as
  `pog.url_config` of `dream_pog` and `libpq`. The new `UrlError` values
  `SslRootCertSystemNeedsVerifyFull(mode)` and `SslRootCertWithoutSslMode`
  refuse the cases that `libpq` refuses or that this package does not read.
  `connect` reads the CA file before the pool starts, and gives
  `actor.InitExited` with a message that names the file when it cannot
  read it.
- `gleam_json` is a dependency, for the recording files.
- `postgres.parse_config(pool_name, url) -> Result(Config, UrlError)` reads
  a connection URL into a `Config` and does not connect.
- `UrlError` says what is wrong with a URL: `MalformedUrl`, `MissingScheme`,
  `UnsupportedScheme`, `MissingHost`, `InvalidPort`, `MissingDatabase`,
  `InvalidDatabase`, `MissingUser`, `InvalidUserEncoding`,
  `InvalidPasswordEncoding`, `InvalidDatabaseEncoding`,
  `UnsupportedParameter`, `UnknownParameterLooksLike`, `UnsupportedSslMode`
  and `UnsupportedFragment`.
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
- The `sslmode` query parameter sets the SSL mode, with the meaning of
  `libpq`: `require` gives `pog.SslUnverified`, `verify-ca` gives
  `pog.SslVerifiedChainOnly` and `verify-full` gives `pog.SslVerified`.
  Without `sslrootcert`, the client trusts the CA certificates of the
  operating system. The connecting guide shows how to trust a private CA
  for one pool with `sslrootcert`. A test on a real PostgreSQL 16 server
  with a certificate that names only `localhost` proves each mode: with the
  test CA, `verify-ca` connects to `127.0.0.1` and `verify-full` does not.
  `application_name` sets the PostgreSQL connection parameter with that
  name in the config, and the server shows that name: a test on a real
  PostgreSQL 16 server, with SSL off and with SSL on, asserts it. An IPv6
  host such as `[::1]` sets IPv6.
- Every other query parameter goes to the server as a run-time parameter,
  with its percent-decoded value, in the order of the URL:
  `?search_path=app&timezone=UTC` sets both on each connection, and
  `options` goes to the server as `libpq` sends it. Of two parameters with
  the same name, the last wins, as in `libpq`. The other `libpq` connection
  keywords and `database` give `UnsupportedParameter`, because the server
  cannot apply them. A name one edit from a keyword, such as `sslmod` or
  `SSLMODE`, gives `UnknownParameterLooksLike(name, keyword)`, so a
  misspelled `sslmode` never connects without TLS. A name or a value that
  the server refuses (for example `serach_path` or `timezone=Mars%2FPhobos`)
  fails at connection time: each query returns `pog.ConnectionUnavailable`
  after about 2 seconds, and only the server log says why. A name that
  starts with `_pq_.` is a protocol option of PostgreSQL, not a setting, so
  it gives `UnsupportedParameter`. An `application_name` in `options`
  (`-c application_name=x`) does not show: the server applies the separate
  parameters after `options`, so it shows the `application_name` parameter
  or the Erlang node name.
- A null byte never reaches the server. pgo writes the user, the database
  name and the connection parameters as strings that end with a null byte,
  so the text after a null byte would reach the server as another
  parameter: the database name `dream_test%00search_path%00evil` connected
  to `dream_test` with `search_path` set to `evil`. `%00` in a query
  parameter name or value gives `MalformedUrl`, and `%00` in the user, the
  password or the database name gives `InvalidUserEncoding`,
  `InvalidPasswordEncoding` or `InvalidDatabaseEncoding`. `connect` refuses
  a config with a null byte in the user, the database name, the password or
  a connection parameter with `actor.InitFailed`, and starts no pool. A
  config that goes to `pog.start` or `pog.supervised` without `connect` or
  `parse_config` does not get this check.

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

- 369 tests, 0 failed, 100.0% line coverage of `src/` (509 of 509 lines), the Erlang file of the recorder too. `make test` takes about 62 seconds, and the test times add up to about 107 seconds, because 4 tests run at a time. The 20 SSL tests run one at a time. Apple M1 Max, 10 cores, 64 GB, macOS 26.5.1, OTP 29, Gleam 1.19.2.
- `make test-playback` runs the 59 recorder tests that need no database. They pass with both test servers stopped, which proves that playback mode opens no connection.
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

