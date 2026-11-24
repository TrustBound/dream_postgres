# dream_postgres 2.0.0 Release Notes

**Release Date:** not released yet (draft)

This release makes `postgres.from_url()` read a connection URL correctly and tell you when it cannot. Before, it read the user and the password wrongly, kept the query string in the database name, and stopped the calling process when the pool did not start.

It is a major version because `from_url()` now returns a `Result`, the package now uses `dream_pog` in place of `pog`, and `sslmode=verify-ca` now has the meaning of `libpq`. Read the Migration Guide before you upgrade. The release also adds query recording, and the package moved to its own repository.

## Key Highlights

- **`from_url()` returns a `Result` (breaking)**: a pool that does not start, or a URL that cannot be read, is an error that your code can handle
- **The user and the password come from the URL**: `postgresql://user:pass@localhost:5432/myapp` now connects as `user` with the password `pass`
- **`sslmode`, `application_name` and server parameters work**: the query string no longer becomes a part of the database name, and a parameter such as `search_path` goes to the server
- **New `parse_config`**: read a URL into a `Config` and do not connect
- **New `check`**: stop at startup when the database does not answer
- **Query recording (new)**: record the queries of a test once against PostgreSQL, then play them back with no database
- **`dream_pog` (breaking)**: the package uses `dream_pog`, a fork of Pog. Import it as `import dream_pog as pog`
- **`sslmode` as in `libpq` (breaking for `verify-ca`)**: `verify-ca` checks the certificate chain but not the host name, and `sslrootcert` trusts the CA file of one pool
- **Its own repository**: `dream_postgres` now lives at [TrustBound/dream_postgres](https://github.com/TrustBound/dream_postgres), with its own version and its own releases

## What's New

### Query recording

The new module `dream_postgres/recorder` records each query of a test, with its parameters and its result, to one JSON file, and plays the file back with no database. It has the three modes of the HTTP recorder of `dream_http_client`, the constructors of the type `recorder.Mode`:

- `Record`: each query runs on the database. The recorder writes the query and its result (the count and the rows, or the error) to the file before the query returns. A query in `pog.transaction` is recorded too.
- `Playback`: no pool starts and nothing connects. Each query gets the result of its recording. A query with no recording fails with `pog.InterceptorFailed`, and never reaches a database. `recorder.error` reads the `recorder.NoRecording(sql:, parameters:, path:)` error back from it.
- `Passthrough`: each query runs on the database, and nothing is recorded.

Set the mode with `recorder.mode(recorder.Playback)`. A wrong mode name is a compile error. For a mode in a text, for example from an environment variable, `recorder.parse_mode(text)` accepts `"record"`, `"playback"` and `"passthrough"`, and gives an `Error` that names any other text.

#### Record a test once, then play it back <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/guide_recording_round_trip.gleam#L18-L29"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
pub fn run_recorded(
  mode: recorder.Mode,
  database_url: String,
  directory: String,
) -> Result(User, String) {
  use recording <- result.try(start_recorder(mode, directory, "create_and_find"))
  use db <- result.try(connect(recording, database_url))
  let user = create_and_find(db) |> result.map_error(string.inspect)
  // In record mode, each query was on disk when it returned
  use Nil <- result.try(recorder.stop(recording))
  user
}
```

A query gets the first recording with its key that it was not given yet. So the same query run two times gets its two results in recorded order, and queries from two processes get their own recordings in any order. The keys are `sql_and_parameters` (the default), `normalized_sql_and_parameters`, `sql_only`, or a function of your own. A query transformer and a result transformer hide secrets before the file is written. Every kind of value that the driver returns comes back the same in playback, and a test against PostgreSQL 16 proves each one. The module `dream_postgres/recording` documents the file format (version 1, one key order, one line for each row) and reads and writes it.

The new guide [Test database code with recorded queries](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/recorded-queries.md) walks through it.

In record mode, a query that the recorder cannot record fails: the file cannot be written (`WriteFailed`), a value cannot be recorded (`NotRecordable`), or the recorder stopped (`RecorderStopped`). `recorder.error` reads the `recorder.RecorderError` back from the query error, and gives `Error(Nil)` for an error of the database or of another interceptor. `recorder.stop` gives an `Error` only when the recorder had stopped already.

### `dream_pog` in Place of `pog`

The package uses `dream_pog`, a fork of Pog 4.1.0, on the driver `dream_pgo`, a fork of pgo 0.20.0. The API is the same, but the module is `dream_pog`, so your code imports it as `import dream_pog as pog`. The fork adds the query interceptor that the recorder uses, the chain-only and CA file SSL modes, and a fix for `application_name`.

### `from_url()` Returns a `Result`

- Before: `pub fn from_url(url: String) -> Connection`
- After: `pub fn from_url(url: String) -> Result(Connection, FromUrlError)`

Before, `from_url()` stopped the calling process with a `let assert` when the pool did not start, so a caller could not handle the failure.

`FromUrlError` holds a `UrlError` or the reason the pool did not start: `InvalidUrl` and `PoolStartExited`. No error value holds the password.

#### Connect from a URL and handle each result <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/client_from_url.gleam#L1-L11"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/client as postgres
import gleam/string

pub fn describe_connection(url: String) -> String {
  case postgres.from_url(url) {
    Ok(_connection) -> "The pool started"
    Error(postgres.InvalidUrl(error)) ->
      "Invalid URL: " <> string.inspect(error)
    Error(error) -> "The pool did not start: " <> string.inspect(error)
  }
}
```

### A URL That Cannot Be Read Is an Error

`from_url()` returns `Error(InvalidUrl(UrlError))` for a URL it cannot read. Before, it used default values for the parts it could not find.

`UrlError` says what is wrong: `MalformedUrl`, `MissingScheme`, `UnsupportedScheme`, `MissingHost`, `InvalidPort`, `MissingDatabase`, `InvalidDatabase`, `MissingUser`, `InvalidUserEncoding`, `InvalidPasswordEncoding`, `InvalidDatabaseEncoding`, `UnsupportedParameter`, `UnknownParameterLooksLike`, `UnsupportedSslMode` and `UnsupportedFragment`.

### `parse_config`

`postgres.parse_config(pool_name, url) -> Result(Config, UrlError)` reads a connection URL into a `Config` and does not connect. Use it to check a URL at startup, or to change a setting with the builder functions before you connect.

### `check`

`postgres.check(connection) -> Result(Nil, QueryError)` runs `SELECT 1` on the connection. It gives `Ok(Nil)` when the database answers, or the error of the query when it does not. `connect` and `from_url` return `Ok` before the pool connects, so an app calls `check` after them to stop at startup, not at the first request. When no database listens, the password is wrong, the database does not exist or the pool size is 0, the error is `pog.ConnectionUnavailable`, after about 2 seconds. The getting started guide shows how to combine the errors of `from_url` and `check` in one startup error type.

### `sslmode`, `sslrootcert`, `application_name` and IPv6

The `sslmode` query parameter sets the SSL mode, with the meaning of `libpq`. The values are `disable`, `require`, `verify-ca` and `verify-full`. `verify-ca` gives `pog.SslVerifiedChainOnly`: it checks that a trusted CA signed the certificate, but not the host name. `verify-full` gives `pog.SslVerified`, which also checks the host name. Without `sslrootcert`, the client trusts the CA certificates of the operating system. `sslrootcert=<path>` makes the pool trust the CA certificates of that PEM file only: it gives `pog.SslVerifiedCaFile(path)` with `verify-full`, and `pog.SslVerifiedChainOnlyCaFile(path)` with `verify-ca` or `require`. `sslrootcert=system` needs `verify-full`. These are the rules of `pog.url_config` in `dream_pog`. Tests on a real PostgreSQL 16 server, whose certificate names only `localhost`, prove each mode: with the test CA file, `verify-ca` connects to `127.0.0.1` and `verify-full` does not.

`application_name` sets the PostgreSQL connection parameter with that name in the config, and the server shows that name. Tests on a real PostgreSQL 16 server, with SSL off and with SSL on, assert it. An IPv6 host such as `[::1]` sets IPv6.

Any other name in the query string goes to the server as a run-time parameter, with its percent-decoded value, in the order of the URL: `?search_path=app&timezone=UTC` sets `search_path` and `timezone` on each connection, and `options` goes to the server as `libpq` sends it. The other `libpq` connection keywords, such as `connect_timeout`, and `database` give `UnsupportedParameter`, because the server cannot apply them. A name one edit from a keyword, such as `sslmod` or `SSLMODE`, gives `UnknownParameterLooksLike(name, keyword)`, so a misspelled `sslmode` never connects without TLS. A name or a value that the server refuses fails at connection time: `from_url` returns `Ok`, and each query returns `pog.ConnectionUnavailable` after about 2 seconds. Only the server log says why. A name that starts with `_pq_.` is a protocol option of PostgreSQL, not a setting, so it gives `UnsupportedParameter`. An `application_name` in `options` (`-c application_name=x`) does not show: the server applies the separate parameters after `options`, so it shows the `application_name` parameter or the Erlang node name.

A null byte never reaches the server. pgo writes the user, the database name and the connection parameters as strings that end with a null byte, so the text after a null byte would reach the server as another parameter: the database name `dream_test%00search_path%00evil` connected to `dream_test` with `search_path` set to `evil`. `%00` in a query parameter gives `MalformedUrl`, and `%00` in the user, the password or the database name gives `InvalidUserEncoding`, `InvalidPasswordEncoding` or `InvalidDatabaseEncoding`. `connect` refuses a config with a null byte in the user, the database name, the password or a connection parameter with `actor.InitFailed`, and starts no pool.

### Its Own Repository

`dream_postgres` moved out of the Dream repository. It has its own version, its own changelog and its own release workflow. The package name on Hex and the module names are the same as before.

### Guides

The package has four guides in [`docs/guides/`](https://github.com/TrustBound/dream_postgres/tree/main/docs/guides). Each one walks through a task from start to finish, with tested code, the failure cases, a test and the common pitfalls:

- **Getting started**: connect from `DATABASE_URL`, stop at startup when the URL or the database is wrong, and run a first query.
- **Connecting to PostgreSQL in production**: SSL, pool size, IPv6, a supervised pool, the URL format and a clear message for each URL error.
- **Running queries and handling their results**: turn query results and their errors into responses, and test them without a database.
- **Test database code with recorded queries**: record the queries of a test once, play them back with no database, read a query with no recording, hide a secret and record again after a query changes.

The README is short and links to them, and HexDocs shows the guides.

## Bug Fixes

### The User and the Password

`from_url()` read the user and the password wrongly. For `postgresql://user:pass@localhost:5432/myapp` it used the user `postgres` and no password. It now reads the URL with `gleam/uri` and gets the user `user` and the password `pass`. The user, the password and the database are percent-decoded.

### The Query String in the Database Name

`from_url()` kept the query string in the database name. For `.../myapp?sslmode=require` the database was `myapp?sslmode=require`. The database is now `myapp`, and `sslmode` sets the SSL mode.

## Testing

- 369 tests run, 0 failed, 100.0% line coverage (509 of 509 lines). `make test` takes about 62 seconds, and the test times add up to about 107 seconds, because 4 tests run at a time and the 20 SSL tests run one at a time (Apple M1 Max, 10 cores, 64 GB, macOS 26.5.1, OTP 29, Gleam 1.19.2)
- The 59 recorder tests that need no database pass with both test servers stopped (`make test-playback`), which proves that playback mode opens no connection
- A test against PostgreSQL 16 records and plays back each kind of value: integers, floats, `Infinity` and `NaN`, text, `bytea`, booleans, `NULL`, arrays, `timestamp`, `timestamptz`, `date`, `time`, `numeric`, `uuid`, a UUID as text, `json`, `jsonb`, `interval`, `bit`, `point` and rows as maps
- The tests run against two PostgreSQL 16 servers (the `postgres:16-alpine` image): one with SSL off, and one with SSL on and a certificate from a test CA. The SSL tests run each `sslmode` against both, with a matching and a non-matching host name, and with and without the test CA in `sslrootcert`

## Upgrading

Update your dependencies:

```toml
[dependencies]
dream_postgres = ">= 2.0.0 and < 3.0.0"
```

Then run:

```bash
gleam deps update dream_postgres
```

### Migration Guide

Steps 1 and 2 apply to every project. Steps 3 to 6 apply only in the cases they name.

#### 1. Replace `pog` with `dream_pog`

Remove `pog` from `[dependencies]` and add `dream_pog` (`gleam add dream_pog`). Replace each `import pog` with `import dream_pog as pog`. The rest of your code stays the same. Two copies of the same types do not mix, so a project that keeps `pog` too cannot pass a `pog.Config` to this package.

#### 2. Your code calls `postgres.from_url()`

Handle the `Result`, as the example under "What's New" shows.

#### 3. Your URL has parts that `from_url()` does not support

These now give an error: a `libpq` connection keyword other than `sslmode`, `application_name` and `options` (for example `connect_timeout` or `channel_binding`), `database`, a name one edit from a keyword (for example `sslmod`), a `sslmode` other than `disable`, `require`, `verify-ca` or `verify-full`, a fragment, no host, no database, a name that starts with `_pq_.`, and `%00` in the user, the password, the database name or a query parameter. Remove the unsupported parts from the URL, or use the builder functions for those settings. Every other query parameter, such as `search_path`, goes to the server. A name or a value that the server refuses makes each query return `ConnectionUnavailable`, so call `check` at startup.

#### 4. Your app connected only because of the old bugs

Before, the user was always `postgres` with no password, whatever the URL said. Now the user and the password of the URL are used. Make sure that they are correct for your database before you upgrade.

#### 5. Your URL has `sslmode=verify-ca`

`verify-ca` no longer checks the host name. Use `verify-full` where you want it checked. A URL with an address that the certificate does not name now connects with `verify-ca`, as it does in `psql`.

#### 6. Your code reads `config.connection_parameters`, or loads a CA file with `public_key:cacerts_load`

`parse_config` no longer adds `client_encoding` before an `application_name`, and keeps every `application_name` of the URL in order. Write `application_name` in lower case. To trust a private CA, put `sslrootcert=<path>` in the URL, or use `pog.SslVerifiedCaFile(path)`, in place of `public_key:cacerts_load`, which changed the CA list of the whole BEAM.

## Documentation

- [dream_postgres](https://hexdocs.pm/dream_postgres) - v2.0.0
- [README](https://github.com/TrustBound/dream_postgres/blob/main/README.md)
- [Getting started](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/getting-started.md)
- [Connecting to PostgreSQL in production](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/connecting.md)
- [Running queries and handling their results](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/queries.md)
- [Test database code with recorded queries](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/recorded-queries.md)
- [Changelog](https://github.com/TrustBound/dream_postgres/blob/main/CHANGELOG.md)

## Community

- [Discussions](https://github.com/TrustBound/dream/discussions)
- [Report Issues](https://github.com/TrustBound/dream_postgres/issues)
- [Contributing Guide](https://github.com/TrustBound/dream_postgres/blob/main/CONTRIBUTING.md)
