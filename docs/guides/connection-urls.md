# Connection URLs

This guide shows how to read a PostgreSQL connection URL into a config, and how to start a connection pool from a URL.

## Read a URL or connect from it

### Connect from a URL <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/readme_connection_from_url.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/client as postgres
import gleam/erlang/process
import gleam/string

pub fn describe_url(url: String) -> String {
  let pool_name = process.new_name("db_pool")
  case postgres.parse_config(pool_name, url) {
    Ok(config) -> "Database " <> config.database <> " on " <> config.host
    Error(postgres.UnsupportedParameter(name)) ->
      "Unsupported parameter: " <> name
    Error(error) -> "Invalid URL: " <> string.inspect(error)
  }
}

pub fn connect_from_url() -> Result(postgres.Connection, postgres.FromUrlError) {
  postgres.from_url("postgresql://user:pass@localhost:5432/myapp")
}
```

`parse_config` reads the URL into a `Config` and does not connect. `from_url` reads the URL, sets a pool size of 15 and starts the pool. Both return a `Result`: a bad URL gives a `UrlError` value that says what is wrong, and no error holds the password.

## URL format

The URL format is `postgresql://user:password@host:port/database`:

- The scheme is `postgresql` or `postgres`. The host and the database are required.
- The port defaults to 5432. Without a user, the default user `postgres` is kept.
- The user, the password and the database are percent-decoded. Encode `@`, `:` and `/` in a password as `%40`, `%3A` and `%2F`.
- Two query parameters are supported: `sslmode` (`disable`, `require`, `verify-ca` or `verify-full`) and `application_name`. Any other parameter gives `UnsupportedParameter`.

## URL errors

`UrlError` says what is wrong with a URL: `MalformedUrl`, `MissingScheme`, `UnsupportedScheme`, `MissingHost`, `InvalidPort`, `MissingDatabase`, `InvalidDatabase`, `MissingUser`, `InvalidUserEncoding`, `InvalidPasswordEncoding`, `InvalidDatabaseEncoding`, `UnsupportedParameter`, `UnsupportedSslMode` and `UnsupportedFragment`.

`FromUrlError` holds a `UrlError` or the reason the pool did not start: `InvalidUrl` and `PoolStartExited`. No error value holds the password.

## When no database listens

The pool connects to the database in the background. When no database listens at the URL, `from_url` still returns `Ok`, and each query returns `Error(pog.ConnectionUnavailable)`.

## Functions

- `postgres.parse_config(pool_name, url)` - Read a PostgreSQL URL into a config, or return a `UrlError`
- `postgres.from_url(url)` - Start a connection pool from a PostgreSQL URL, or return a `FromUrlError`

## See also

- [Getting started](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/getting-started.md): install the package and connect to a database
- [Connection builder](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/connection-builder.md): configure a connection step by step and start the pool
- [Running queries](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/running-queries.md): run queries with Pog or Squirrel on a connection
- [Query results and errors](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/query-results.md): turn query results into values and handle each error
- [README](https://github.com/TrustBound/dream_postgres/blob/main/README.md)
