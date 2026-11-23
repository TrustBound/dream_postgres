# Query results and errors

This guide shows how to turn Pog query results into values with the `query` module, and how to handle each `QueryError`.

## Query result helpers

The `query` module provides simple helpers for extracting data from Pog results:

### Turn results into values <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/readme_query_result_helpers.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/client as postgres
import dream_postgres/query
import gleam/list
import gleam/string

pub type User {
  User(id: Int, name: String)
}

// First row (for "get by ID" queries)
pub fn user_from_result(
  result: Result(postgres.Returned(User), postgres.QueryError),
) -> Result(User, String) {
  case query.first_row(result) {
    Ok(user) -> {
      // pog.returning already decoded the row to your type
      Ok(user)
    }
    Error(query.NotFound) -> {
      // Query succeeded but no rows returned
      Error("User not found")
    }
    Error(query.DatabaseError) -> {
      // Query failed (connection error, SQL error, etc.)
      Error("Database error")
    }
  }
}

// All rows (for "list" queries)
pub fn user_names_from_result(
  result: Result(postgres.Returned(User), postgres.QueryError),
) -> Result(List(String), String) {
  case query.all_rows(result) {
    Ok(users) -> {
      // Process all rows
      Ok(list.map(users, fn(user) { user.name }))
    }
    Error(error) -> {
      Error("Database error: " <> string.inspect(error))
    }
  }
}
```

## Error handling

The `QueryError` type simplifies error handling:

### Handle each QueryError <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/readme_error_handling.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/query

pub fn explain_query_error(error: query.QueryError) -> String {
  case error {
    // Query succeeded but no rows
    query.NotFound -> "The query returned no rows"
    // Query failed (connection, SQL, etc.)
    query.DatabaseError -> "The query failed"
  }
}
```

This is much simpler than Pog's error types, making it easier to handle common cases.

## Functions

- `query.first_row(result)` - Extract first row or `NotFound`
- `query.all_rows(result)` - Extract all rows (empty list if none)

## See also

- [Getting started](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/getting-started.md): install the package and connect to a database
- [Connection builder](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/connection-builder.md): configure a connection step by step and start the pool
- [Connection URLs](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/connection-urls.md): read a PostgreSQL URL into a config or start a pool from it
- [Running queries](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/running-queries.md): run queries with Pog or Squirrel on a connection
- [README](https://github.com/TrustBound/dream_postgres/blob/main/README.md)
