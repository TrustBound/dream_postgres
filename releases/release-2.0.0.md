# dream_postgres 2.0.0 Release Notes

**Release Date:** not released yet (draft)

This release makes `postgres.from_url()` read a connection URL correctly and tell you when it cannot. Before, it read the user and the password wrongly, kept the query string in the database name, and stopped the calling process when the pool did not start.

It is a major version because `from_url()` now returns a `Result`. Read the Migration Guide before you upgrade. The package also moved to its own repository.

## Key Highlights

- **`from_url()` returns a `Result` (breaking)**: a pool that does not start, or a URL that cannot be read, is an error that your code can handle
- **The user and the password come from the URL**: `postgresql://user:pass@localhost:5432/myapp` now connects as `user` with the password `pass`
- **`sslmode` and `application_name` work**: the query string no longer becomes a part of the database name
- **New `parse_config`**: read a URL into a `Config` and do not connect
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

`UrlError` says what is wrong: `MalformedUrl`, `MissingScheme`, `UnsupportedScheme`, `MissingHost`, `InvalidPort`, `MissingDatabase`, `InvalidDatabase`, `MissingUser`, `InvalidUserEncoding`, `InvalidPasswordEncoding`, `InvalidDatabaseEncoding`, `UnsupportedParameter`, `UnsupportedSslMode` and `UnsupportedFragment`.

### `parse_config`

`postgres.parse_config(pool_name, url) -> Result(Config, UrlError)` reads a connection URL into a `Config` and does not connect. Use it to check a URL at startup, or to change a setting with the builder functions before you connect.

### `sslmode`, `application_name` and IPv6

The `sslmode` query parameter sets the SSL mode. The values are `disable`, `require`, `verify-ca` and `verify-full`. `application_name` sets the PostgreSQL connection parameter with that name in the config. With Pog 4.1, the server does not see it: pgo, the driver under Pog, sends the Erlang node name as `application_name` after it, and PostgreSQL keeps the last value. An IPv6 host such as `[::1]` sets IPv6.

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

- 165 tests run, 0 failed, 100.0% line coverage. `make test` takes about 24 seconds, and the test times add up to about 41 seconds, because 4 tests run at a time (Apple M1 Max, 10 cores, 64 GB, macOS 26.5.1, OTP 29, Gleam 1.19.2)
- The tests run against PostgreSQL 16 (the `postgres:16-alpine` image)

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

These now give an error: a query parameter other than `sslmode` or `application_name`, a `sslmode` other than `disable`, `require`, `verify-ca` or `verify-full`, a fragment, no host, or no database. Remove the unsupported parts from the URL, or use the builder functions for those settings.

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
