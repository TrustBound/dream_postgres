# Changelog

All notable changes to `dream_postgres` will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.1.0] - Unreleased

### Added
- `dream_postgres/client` now has the query functions, the value functions
  and the decoders of `dream_postgres_client`: `query`, `parameter`,
  `returning`, `timeout`, `execute`, `transaction`, `null`, `bool`, `int`,
  `float`, `text`, `bytea`, `array`, `nullable`, `timestamp`,
  `calendar_date`, `calendar_time_of_day`, `timestamp_decoder`,
  `calendar_date_decoder`, `calendar_time_of_day_decoder` and
  `numeric_decoder`. Each function calls the function of the same name in
  `dream_postgres_client`, with the same arguments.
- The type aliases `Query(row)` and `TransactionError(error)`, next to the
  aliases `Connection`, `QueryError`, `Value` and `Returned(a)`.
- Code that `dream_sql_generator` writes with
  `client_module = "dream_postgres/client"` now compiles against this
  package. The generated module imports `dream_postgres/client as pog`,
  and an app needs no `dream_postgres_client` import for it. The README and
  the queries guide show the `gleam.toml` setting.
- `gleam_time` is now a direct dependency, for the `Timestamp`, `Date` and
  `TimeOfDay` types of the new functions.
- `violated_constraint(error)` gives the name of the constraint that a
  query violated, for example `Ok("users_email_key")`: a unique
  constraint, a primary key, a unique index, a foreign key, a check or an
  exclusion constraint. Every other error gives `Error(Nil)`. It does not
  tell the kinds apart: compare the name with the constraints that you
  know are unique.
- `promised_not_null(decoder, file, column)` decodes a column that a SQL
  file promised is never NULL. A NULL fails the row with a message that
  names the file and the column.
- `timestamp_with_time_zone_decoder()` reads a `timestamptz` column as a
  `Timestamp`. `timestamp_decoder` reads only a `timestamp` column, because
  `dream_postgres_client` gives a `timestamptz` value as a date and a time
  of day in UTC.
- `broken_promise(error)` gives the message of a broken `-- not null:`
  promise from the error of `execute`, and `Error(Nil)` for every other
  error. Generated model modules return it as an `InternalServerError`.
- The type aliases `Timestamp`, `Date` and `TimeOfDay`, for the types of
  `gleam/time`. Generated model modules name these types through
  `dream_postgres/client` and import no `gleam_time` module.
- `schema_fingerprint(connection, tables)` gives the SHA-256 hash of the
  catalog facts of the tables, their child tables and their partitions.
  `schema_fingerprint_sql` is its SQL. `check_schema(connection, expected)`
  compares the fingerprint of each generated module with the database, and
  `format_schema_check_error` gives a message that names each module to
  regenerate. The new types are `SchemaFingerprint`, `SchemaMismatch` and
  `SchemaCheckError`.
- The OTP application `crypto` is now in `extra_applications`, for the SHA-256
  hash.

### Tests
- The tests run every query of two generated modules from the Dream
  examples (`database` and `tasks`) through `dream_postgres/client`. Only
  the import line of each module changed. The tests record the queries
  against PostgreSQL 16 and play the committed recordings back with no
  database.
- The 63 tests of the new helpers passed on PostgreSQL 16, 17, 18 and 19,
  with `DREAM_POSTGRES_TEST_URL` set to each server. They show
  that the fingerprint does not change when the same DDL makes the tables
  again, when the columns are in another order, or when the
  `search_path` is different. They also show that each kind of schema
  change changes it.
- 474 tests, 0 failed, 100.0% line coverage of `src/` (620 of 620 lines),
  the Erlang files too. The test times add up to about 122 seconds, and 4
  tests run at a time. The 20 SSL tests run one at a time. Apple M1 Max,
  10 cores, 64 GB, macOS 26.5.1, OTP 29, Gleam 1.19.2.

## [2.0.0] - 2026-11-24

### Changed (breaking)
- The package now uses `dream_postgres_client`, a fork of Pog 4.1.0 on the
  driver `dream_postgres_driver`, a fork of pgo 0.20.0, in place of `pog`.
  The API is the same, but the module name is `dream_postgres_client`.
  - Before: `import pog`, `pog.query(sql)`, and `pog` in `[dependencies]`
  - After: `import dream_postgres_client`,
    `dream_postgres_client.query(sql)`, and `dream_postgres_client` in
    `[dependencies]`
  - Upgrade: replace `pog` with `dream_postgres_client` in `gleam.toml`,
    `import pog` with `import dream_postgres_client`, and each `pog.` with
    `dream_postgres_client.`. `postgres.Config`, `Connection` and the other
    types are the `dream_postgres_client` types now.
- `sslmode=verify-ca` now gives
  `dream_postgres_client.SslVerifiedChainOnly`, the meaning of `libpq`: it
  checks that a trusted CA signed the certificate, but not the host name.
  Before, it gave `dream_postgres_client.SslVerified`, which also checks the
  host name. `sslmode=verify-full` still gives
  `dream_postgres_client.SslVerified`. Upgrade: use `verify-full` where you
  want the host name checked.
- `parse_config` and `connect` no longer put `client_encoding` before an
  `application_name` in the connection parameters, and they no longer drop
  an earlier `application_name`. That order was a workaround for a pgo bug
  that lost the caller's `application_name`. `dream_postgres_driver` fixes
  the bug: the caller's `application_name` reaches the server in any order,
  also from a config that goes to `dream_postgres_client.start` or
  `dream_postgres_client.supervised` without `connect`. The name has no
  case, as in PostgreSQL: `Application_Name` also reaches the server. The
  real-server tests of the name pass without the workaround.
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
  `dream_postgres_client.SslVerifiedCaFile` for one pool. Before, it loaded
  the CA file into the CA list of the whole BEAM with
  `public_key:cacerts_load`.

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
    parameters and its result (the count and the rows, or the error) to the
    file before the query returns. A query in
    `dream_postgres_client.transaction` is recorded too.
  - Playback mode starts no pool and opens no connection
    (`dream_postgres_client.disconnected`). Each query gets the result of
    its recording. A query with no recording fails with
    `dream_postgres_client.InterceptorFailed`, and never reaches a database.
  - `recorder.error(query_error)` reads a `recorder.RecorderError` back from
    a query error that the recorder made: `NoRecording(sql, parameters,
    path, nearest)`, `PlayedAlready(sql, parameters, path)`,
    `WriteFailed(path, reason)`, `NotRecordable(sql, reason)` or
    `RecorderStopped(sql)`. It gives `Error(Nil)` for any other query
    error, also for the `dream_postgres_client.InterceptorFailed` of
    another interceptor.
  - A `NoRecording` names the nearest recordings in the file and what
    differs. `nearest` holds up to 3 `recorder.NearestRecording(position,
    recorded, requested)`: recordings that the key would match with their
    parameters, fewest differing parameters first, then in file order. The
    recorder compares after the query transformer, so a hidden value never
    shows.
  - `recorder.describe_error(error)` gives the text of a recorder error.
    For a `NoRecording`, each nearest recording shows its parameters on a
    `-` line and the query's on a `+` line. With no recording of the SQL,
    the text names the file that the recorder searched.
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
  `dream_postgres_client.SslVerifiedCaFile(path)`,
  `dream_postgres_client.SslVerifiedChainOnlyCaFile(path)`,
  `dream_postgres_client.SslVerified` or
  `dream_postgres_client.SslDisabled`, by the same rules as
  `dream_postgres_client.url_config` of `dream_postgres_client` and `libpq`.
  The new `UrlError` values `SslRootCertSystemNeedsVerifyFull(mode)` and
  `SslRootCertWithoutSslMode` refuse the cases that `libpq` refuses or that
  this package does not read. `connect` reads the CA file before the pool
  starts, and gives `actor.InitExited` with a message that names the file
  when it cannot read it.
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
  exist or the pool size is 0, the error is
  `dream_postgres_client.ConnectionUnavailable`, after 2 to 3 seconds. The
  guides use it for their startup check.
- `FromUrlError` holds a `UrlError` or the reason the pool did not start:
  `InvalidUrl` and `PoolStartExited`.
  No error value holds the password.
- The `sslmode` query parameter sets the SSL mode, with the meaning of
  `libpq`: `require` gives `dream_postgres_client.SslUnverified`,
  `verify-ca` gives `dream_postgres_client.SslVerifiedChainOnly` and
  `verify-full` gives `dream_postgres_client.SslVerified`. Without
  `sslrootcert`, the client trusts the CA certificates of the operating
  system. The connecting guide shows how to trust a private CA for one pool
  with `sslrootcert`. A test on a real PostgreSQL 16 server with a
  certificate that names only `localhost` proves each mode: with the test
  CA, `verify-ca` connects to `127.0.0.1` and `verify-full` does not.
  `application_name` sets the PostgreSQL connection parameter with that name
  in the config, and the server shows that name: a test on a real PostgreSQL
  16 server, with SSL off and with SSL on, asserts it. An IPv6 host such as
  `[::1]` sets IPv6.
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
  fails at connection time: each query returns
  `dream_postgres_client.ConnectionUnavailable` after 2 to 3 seconds, and
  only the server log says why. A name that starts with `_pq_.` is a
  protocol option of PostgreSQL, not a setting, so it gives
  `UnsupportedParameter`. An `application_name` in `options` (`-c
  application_name=x`) does not show: the server applies the separate
  parameters after `options`, so it shows the `application_name` parameter
  or the Erlang node name.
- A null byte never reaches the server. The driver writes the user, the database
  name and the connection parameters as strings that end with a null byte,
  so the text after a null byte would reach the server as another parameter:
  the database name `dream_test%00search_path%00evil` connected to
  `dream_test` with `search_path` set to `evil`. `%00` in a query parameter
  name or value gives `MalformedUrl`, and `%00` in the user, the password or
  the database name gives `InvalidUserEncoding`, `InvalidPasswordEncoding`
  or `InvalidDatabaseEncoding`. `connect` refuses a config with a null byte
  in the user, the database name, the password or a connection parameter
  with `actor.InitFailed`, and starts no pool. A config that goes to
  `dream_postgres_client.start` or `dream_postgres_client.supervised`
  without `connect` or `parse_config` does not get this check.

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

- 388 tests, 0 failed, 100.0% line coverage of `src/` (557 of 557 lines),
  the Erlang file of the recorder too. The test times add up to about 108
  seconds, and 4 tests run at a time. The 20 SSL tests run one at a time. Apple M1 Max, 10 cores, 64 GB,
  macOS 26.5.1, OTP 29, Gleam 1.19.2.
- `make test-playback` runs the 74 recorder tests that need no database.
  They pass with both test servers stopped, which proves that playback mode
  opens no connection.
- The tests run against two PostgreSQL 16 servers (the `postgres:16-alpine`
  image), started with `make db-up`. One has SSL off. It runs as a service
  container in CI. The other has SSL on, with a test CA and a server
  certificate from `test/fixtures/ssl`. CI starts it with `docker compose`.

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

