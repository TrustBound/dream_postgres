# Running queries

This guide shows how to run queries on a `Connection` with Pog, and how to read the first row or all rows of the result.

## Run a query

Use with [Squirrel](https://hex.pm/packages/squirrel) or Pog directly:

### Run a query with Pog <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/readme_query_execution.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/client as postgres
import dream_postgres/query
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/string
import pog

pub type User {
  User(id: Int, name: String)
}

fn user_decoder() -> decode.Decoder(User) {
  use id <- decode.field(0, decode.int)
  use name <- decode.field(1, decode.string)
  decode.success(User(id:, name:))
}

pub fn find_user(
  db: postgres.Connection,
  id: Int,
) -> Result(postgres.Returned(User), postgres.QueryError) {
  pog.query("SELECT id, name FROM users WHERE id = $1")
  |> pog.parameter(pog.int(id))
  |> pog.returning(user_decoder())
  |> pog.execute(db)
}

pub fn list_users(
  db: postgres.Connection,
) -> Result(postgres.Returned(User), postgres.QueryError) {
  pog.query("SELECT id, name FROM users")
  |> pog.returning(user_decoder())
  |> pog.execute(db)
}

// Get first row
pub fn describe_user(
  result: Result(postgres.Returned(User), postgres.QueryError),
) -> String {
  case query.first_row(result) {
    Ok(user) -> "User " <> int.to_string(user.id) <> ": " <> user.name
    Error(query.NotFound) -> "No such user"
    Error(query.DatabaseError) -> "The database query failed"
  }
}

// Get all rows
pub fn describe_user_count(
  result: Result(postgres.Returned(User), postgres.QueryError),
) -> String {
  case query.all_rows(result) {
    Ok(users) -> int.to_string(list.length(users)) <> " users"
    Error(error) -> "The database query failed: " <> string.inspect(error)
  }
}
```

For more about `first_row`, `all_rows` and their errors, see [Query results and errors](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/query-results.md).

## See also

- [Getting started](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/getting-started.md): install the package and connect to a database
- [Connection builder](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/connection-builder.md): configure a connection step by step and start the pool
- [Connection URLs](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/connection-urls.md): read a PostgreSQL URL into a config or start a pool from it
- [Query results and errors](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/query-results.md): turn query results into values and handle each error
- [README](https://github.com/TrustBound/dream_postgres/blob/main/README.md)
