# dream_postgres 2.0.0 Release Notes

**Release Date:** not released yet (draft)

This release makes `postgres.from_url()` read a connection URL correctly and tell you when it cannot. Before, it read the user and the password wrongly, kept the query string in the database name, and stopped the calling process when the pool did not start.

It is a major version because `from_url()` now returns a `Result`. Read the Migration Guide before you upgrade. The package also moved to its own repository.

## Key Highlights

- **`from_url()` returns a `Result` (breaking)**: a pool that does not start, or a URL that cannot be read, is an error that your code can handle
- **The user and the password come from the URL**: `postgresql://user:pass@localhost:5432/myapp` now connects as `user` with the password `pass`
- **`sslmode`, `application_name` and server parameters work**: the query string no longer becomes a part of the database name, and a parameter such as `search_path` goes to the server
- **New `parse_config`**: read a URL into a `Config` and do not connect
- **New `check`**: stop at startup when the database does not answer
- **Its own repository**: `dream_postgres` now lives at [TrustBound/dream_postgres](https://github.com/TrustBound/dream_postgres), with its own version and its own releases

## What's New

### `from_url()` Returns a `Result`

```text
Before: pub fn from_url(url: String) -> Connection
After:  pub fn from_url(url: String) -> Result(Connection, FromUrlError)
```

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

### `sslmode`, `application_name` and IPv6

The `sslmode` query parameter sets the SSL mode. The values are `disable`, `require`, `verify-ca` and `verify-full`. `verify-ca` works the same as `verify-full`: it checks the certificate and the host name, where `libpq` checks only the certificate. The client trusts the CA certificates of the operating system. The connecting guide shows how to trust a private CA. `application_name` sets the PostgreSQL connection parameter with that name in the config, and the server shows that name. Tests on a real PostgreSQL 16 server, with SSL off and with SSL on, assert it. pgo, the driver under Pog, also sends the Erlang node name as `application_name`, and PostgreSQL keeps the last value. So `parse_config` and `connect` put `client_encoding` (`UTF8`, or the value of the config) just before your `application_name`, and pgo then puts its own value before both. A config without an `application_name` sends no `client_encoding`. A config that goes to `pog.supervised` or `pog.start` without `parse_config` or `connect` does not get this order: the connecting guide shows the fix. An IPv6 host such as `[::1]` sets IPv6.

Any other name in the query string goes to the server as a run-time parameter, with its percent-decoded value, in the order of the URL: `?search_path=app&timezone=UTC` sets `search_path` and `timezone` on each connection, and `options` goes to the server as `libpq` sends it. The other `libpq` connection keywords, such as `connect_timeout`, and `database` give `UnsupportedParameter`, because the server cannot apply them. A name one edit from a keyword, such as `sslmod` or `SSLMODE`, gives `UnknownParameterLooksLike(name, keyword)`, so a misspelled `sslmode` never connects without TLS. A name or a value that the server refuses fails at connection time: `from_url` returns `Ok`, and each query returns `pog.ConnectionUnavailable` after about 2 seconds. Only the server log says why.

### Its Own Repository

`dream_postgres` moved out of the Dream repository. It has its own version, its own changelog and its own release workflow. The package name on Hex and the module names are the same as before.

### Guides

The package has three guides in [`docs/guides/`](https://github.com/TrustBound/dream_postgres/tree/main/docs/guides). Each one walks through a task from start to finish, with tested code, the failure cases, a test and the common pitfalls:

- **Getting started**: connect from `DATABASE_URL`, stop at startup when the URL or the database is wrong, and run a first query.
- **Connecting to PostgreSQL in production**: SSL, pool size, IPv6, a supervised pool, the URL format and a clear message for each URL error.
- **Running queries and handling their results**: turn query results and their errors into responses, and test them without a database.

The README is short and links to them, and HexDocs shows the guides.

## Bug Fixes

### The User and the Password

`from_url()` read the user and the password wrongly. For `postgresql://user:pass@localhost:5432/myapp` it used the user `postgres` and no password. It now reads the URL with `gleam/uri` and gets the user `user` and the password `pass`. The user, the password and the database are percent-decoded.

### The Query String in the Database Name

`from_url()` kept the query string in the database name. For `.../myapp?sslmode=require` the database was `myapp?sslmode=require`. The database is now `myapp`, and `sslmode` sets the SSL mode.

## Testing

- 243 tests run, 0 failed, 100.0% line coverage. `make test` takes about 52 seconds, and the test times add up to about 97 seconds, because 4 tests run at a time and the 18 SSL tests run one at a time (Apple M1 Max, 10 cores, 64 GB, macOS 26.5.1, OTP 29, Gleam 1.19.2)
- The tests run against two PostgreSQL 16 servers (the `postgres:16-alpine` image): one with SSL off, and one with SSL on and a certificate from a test CA. The SSL tests run each `sslmode` against both, with a matching and a non-matching host name, and with and without the test CA in the CA list

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

Step 1 applies to every project that calls `from_url()`. Steps 2 and 3 apply only in the cases they name.

#### 1. Your code calls `postgres.from_url()`

Handle the `Result`, as the example under "What's New" shows.

#### 2. Your URL has parts that `from_url()` does not support

These now give an error: a `libpq` connection keyword other than `sslmode`, `application_name` and `options` (for example `connect_timeout` or `channel_binding`), `database`, a name one edit from a keyword (for example `sslmod`), a `sslmode` other than `disable`, `require`, `verify-ca` or `verify-full`, a fragment, no host, or no database. Remove the unsupported parts from the URL, or use the builder functions for those settings. Every other query parameter, such as `search_path`, goes to the server. A name or a value that the server refuses makes each query return `ConnectionUnavailable`, so call `check` at startup.

#### 3. Your app connected only because of the old bugs

Before, the user was always `postgres` with no password, whatever the URL said. Now the user and the password of the URL are used. Make sure that they are correct for your database before you upgrade.

## Documentation

- [dream_postgres](https://hexdocs.pm/dream_postgres) - v2.0.0
- [README](https://github.com/TrustBound/dream_postgres/blob/main/README.md)
- [Getting started](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/getting-started.md)
- [Connecting to PostgreSQL in production](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/connecting.md)
- [Running queries and handling their results](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/queries.md)
- [Changelog](https://github.com/TrustBound/dream_postgres/blob/main/CHANGELOG.md)

## Community

- [Discussions](https://github.com/TrustBound/dream/discussions)
- [Report Issues](https://github.com/TrustBound/dream_postgres/issues)
- [Contributing Guide](https://github.com/TrustBound/dream_postgres/blob/main/CONTRIBUTING.md)
