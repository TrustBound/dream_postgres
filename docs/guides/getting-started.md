# Getting started

This guide shows how to add dream_postgres to a Gleam project and connect to a PostgreSQL database with a connection pool.

## Install

Add the package as a dependency:

```bash
gleam add dream_postgres
```

dream_postgres has no dependency on Dream or other frameworks. It uses [Pog](https://hex.pm/packages/pog) for connection pooling. You can use it in any Gleam project.

## Connect to a database

Create a config with a pool name, set the connection settings with the builder functions, then start the pool with `connect`.

### Connection Setup <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/readme_connection_setup.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/client as postgres
import gleam/erlang/process
import gleam/otp/actor

pub fn database_config() -> postgres.Config {
  let pool_name = process.new_name("db_pool")
  postgres.new(pool_name)
  |> postgres.host("localhost")
  |> postgres.port(5432)
  |> postgres.database("myapp")
  |> postgres.user("postgres")
  |> postgres.password("secret")
  |> postgres.pool_size(15)
}

pub fn connect_database() -> Result(postgres.Connection, actor.StartError) {
  database_config()
  |> postgres.connect()
}
```

To read the settings from a URL instead, see [Connection URLs](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/connection-urls.md).

## See also

- [Connection builder](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/connection-builder.md): configure a connection step by step and start the pool
- [Connection URLs](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/connection-urls.md): read a PostgreSQL URL into a config or start a pool from it
- [Running queries](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/running-queries.md): run queries with Pog or Squirrel on a connection
- [Query results and errors](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/query-results.md): turn query results into values and handle each error
- [README](https://github.com/TrustBound/dream_postgres/blob/main/README.md)
