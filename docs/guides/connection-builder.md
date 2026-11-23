# Connection builder

This guide shows how to configure a database connection step by step with the builder functions, and how to start the connection pool.

## Build a config

Configure your database connection step by step:

### Build a production config <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/readme_connection_builder.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/client as postgres
import gleam/erlang/process
import gleam/otp/actor

pub fn production_config() -> postgres.Config {
  let pool_name = process.new_name("my_db_pool")
  postgres.new(pool_name)
  |> postgres.host("localhost")
  |> postgres.port(5432)
  |> postgres.database("myapp_prod")
  |> postgres.user("postgres")
  |> postgres.password("secret")
  // Max 20 connections
  |> postgres.pool_size(20)
}

pub fn connect_production() -> Result(postgres.Connection, actor.StartError) {
  production_config()
  |> postgres.connect()
}
```

## Functions

- `postgres.new(pool_name)` - Create new config
- `postgres.host(config, host)` - Set database host
- `postgres.port(config, port)` - Set database port
- `postgres.database(config, name)` - Set database name
- `postgres.user(config, user)` - Set database user
- `postgres.password(config, password)` - Set database password
- `postgres.pool_size(config, size)` - Set connection pool size
- `postgres.connect(config)` - Start connection pool

To read a config from a URL, see [Connection URLs](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/connection-urls.md).

## See also

- [Getting started](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/getting-started.md): install the package and connect to a database
- [Connection URLs](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/connection-urls.md): read a PostgreSQL URL into a config or start a pool from it
- [Running queries](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/running-queries.md): run queries with Pog or Squirrel on a connection
- [Query results and errors](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/query-results.md): turn query results into values and handle each error
- [README](https://github.com/TrustBound/dream_postgres/blob/main/README.md)
