# Queries

This guide shows how to build a query, how to read its rows, which function runs it, and how to handle its errors. The examples use the tables of the [getting started guide](getting-started.md#step-2-make-the-tables).

## Table of Contents

- [Build a query](#build-a-query)
- [Read rows](#read-rows)
- [Run a query](#run-a-query)
- [The checks before each run](#the-checks-before-each-run)
- [Errors](#errors)

## Build a query

`query(sql)` makes a query with no parameters. `parameter(query, codec, value)` adds the next parameter: the first call gives `$1`, the next `$2`. The codec says how to write the value:

### Store a user <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/create_user.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/codec.{text}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{one, parameter, query}
import snippets/user_row.{type User, user_row}

/// Stores a new user, and gives the user with the id that the database
/// gave it.
pub fn create_user(
  connection: Connection,
  email: String,
  name: String,
) -> Result(User, Error(PostgresError)) {
  "INSERT INTO users (email, name) VALUES ($1, $2) RETURNING id, email, name"
  |> query
  |> parameter(text, email)
  |> parameter(text, name)
  |> one(user_row(), connection)
}
```

A parameter goes to the server apart from the SQL text, so a value never becomes part of the SQL.

`named(query, name)` gives the query a name. Errors and logs show the name with the SQL:

### Find a user by email <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/find_user.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/codec.{text}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{maybe_one, named, parameter, query}
import gleam/option.{type Option}
import snippets/user_row.{type User, user_row}

/// Finds the user with an email, if there is one.
pub fn find_user(
  connection: Connection,
  email: String,
) -> Result(Option(User), Error(PostgresError)) {
  "SELECT id, email, name FROM users WHERE email = $1"
  |> query
  |> named("user.find")
  |> parameter(text, email)
  |> maybe_one(user_row(), connection)
}
```

`secret_parameter(query, codec, value)` adds the next parameter as `parameter` does, and marks it secret. Use it for a password, a token or a key. A live run sends it as any other parameter. A recorder never saves its value, so a recording file never holds it. `string.inspect` of the request that an interceptor gets shows the parameter as `Secret`, not its value:

### Check a password against its hash <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/password_check.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/codec.{bool, text}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{named, one, parameter, query, secret_parameter}
import dream_postgres/row.{single}

/// Checks a password against its stored SHA-256 hash in hex. The password
/// is a secret parameter, so a recording of this query never holds it.
pub fn password_matches(
  connection: Connection,
  password: String,
  stored_hash: String,
) -> Result(Bool, Error(PostgresError)) {
  "SELECT encode(sha256(convert_to($1, 'UTF8')), 'hex') = $2"
  |> query
  |> named("password.matches")
  |> secret_parameter(text, password)
  |> parameter(text, stored_hash)
  |> one(single(bool), connection)
}
```

A list goes to the server as one array parameter. `codec.array` makes the codec of a list from the codec of its elements:

### Find the users of a list of ids <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/find_users.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/codec.{array, int}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{all, parameter, query}
import snippets/user_row.{type User, user_row}

/// Gives the users with the ids. The list goes to PostgreSQL as one array
/// parameter.
pub fn find_users(
  connection: Connection,
  user_ids: List(Int),
) -> Result(List(User), Error(PostgresError)) {
  "SELECT id, email, name FROM users WHERE id = ANY($1) ORDER BY id"
  |> query
  |> parameter(array(int), user_ids)
  |> all(user_row(), connection)
}
```

## Read rows

A row reader, of type `Row(a)`, says how to read one row into a value of type `a`. Build it from these functions:

| Function | What it reads |
|---|---|
| `column(codec, next)` | The next column. A reader that uses `column` reads every column, in order. |
| `column_at(position, codec, next)` | The column at a position. Positions count from 1, like `$1`. |
| `column_named(name, codec, next)` | The column with this name. The name must belong to one column only. |
| `row(value)` | Nothing. It gives the value of the row, after its columns are read. |
| `single(codec)` | The one column of a result of one column. |

Use `column` with `use`, one line for each column, and end with `row`:

### A row reader for users <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/user_row.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/codec.{int, text}
import dream_postgres/row.{type Row, column, row}

pub type User {
  User(id: Int, email: String, name: String)
}

/// Reads the columns id, email and name, in this order, into a User.
pub fn user_row() -> Row(User) {
  use id <- column(int)
  use email <- column(text)
  use name <- column(text)
  row(User(id:, email:, name:))
}
```

`column_at` and `column_named` read some of the columns, in any order:

### Read columns by position and by name <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/user_names.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/codec.{int, text}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{all, query}
import dream_postgres/row.{column_at, column_named, row}

/// Gives the id and the name of each user. The reader reads the first
/// column by position and the name column by name, and skips the email.
pub fn user_names(
  connection: Connection,
) -> Result(List(#(Int, String)), Error(PostgresError)) {
  let id_and_name = {
    use id <- column_at(1, int)
    use name <- column_named("name", text)
    row(#(id, name))
  }
  "SELECT id, email, name FROM users ORDER BY id"
  |> query
  |> all(id_and_name, connection)
}
```

A reader cannot mix `column` with `column_at` or `column_named`. A reader that reads one column two times is an error too.

`single` reads a result of one column:

### Count the users <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/count_users.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/codec.{int}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{one, query}
import dream_postgres/row.{single}

/// Gives the number of users. The result has one column, so `single`
/// reads it.
pub fn count_users(
  connection: Connection,
) -> Result(Int, Error(PostgresError)) {
  "SELECT count(*) FROM users"
  |> query
  |> one(single(int), connection)
}
```

## Run a query

Four functions run a query. Each takes the query, a row reader where it reads rows, and the connection:

| Function | Result | When the row count is wrong |
|---|---|---|
| `all(query, reader, connection)` | `List(a)` of every row | never |
| `one(query, reader, connection)` | `a` of exactly one row | no row is `NotFound`, and more than one row is `Failed` |
| `maybe_one(query, reader, connection)` | `Option(a)` of at most one row | more than one row is `Failed` |
| `affected(query, connection)` | `Int`, the row count of the command tag | never |

`affected` reads the row count of the command tag, for example 1 for `UPDATE 1`. It reads no rows:

### Rename a user <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/rename_user.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/codec.{int, text}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{affected, parameter, query}

/// Gives the user a new name, and gives the number of rows that changed:
/// 0 when no user has the id.
pub fn rename_user(
  connection: Connection,
  user_id: Int,
  name: String,
) -> Result(Int, Error(PostgresError)) {
  "UPDATE users SET name = $1 WHERE id = $2"
  |> query
  |> parameter(text, name)
  |> parameter(int, user_id)
  |> affected(connection)
}
```

The connection can be a pool, the connection of a transaction, or the connection of `with_connection`. `with_connection(connection, callback)` holds one connection of the pool for the callback, so each call in it runs on the same connection, for example a temporary table and the queries on it.

## The checks before each run

The server prepares each statement and describes its parameters and its columns. Before each run, dream_postgres checks the query against that description:

- The number of parameters must be the number that the SQL uses.
- The codec of each parameter must take the type of the parameter.
- The reader must read the number of columns that the query returns, and the codec of each column must take the type of the column. For an enum, the labels of the codec must be the labels of the type.

A failed check is a `Failed` error that names the query, the parameter or the column, and the query does not run. For example: `parameter $1 is int4, and the query gives it with the text codec`.

## Errors

Every function that runs a query returns `Result(a, dream_errors.Error(PostgresError))`. The `dream_errors` variant says what kind of failure it is. The `PostgresError` cause keeps the name of the query, its SQL text, and the exact reason, with every field that PostgreSQL sent. The cause never keeps the values of the parameters, because they can hold secrets.

### The kind of each failure

| Kind | Failures |
|---|---|
| `NotFound` | `one` got no row |
| `Conflict` | A unique violation (SQLSTATE `23505`) |
| `Invalid` | Any other integrity violation of class `23`, such as not null or a foreign key, a data exception of class `22`, a value that a codec cannot write, a wrong config |
| `Retry` | A serialization failure (`40001`), a deadlock (`40P01`), a statement whose tables or types changed during the run |
| `Unavailable` | A failed connect, a lost connection, no free connection in time, a stopped pool, the classes `08`, `28`, `53`, `58` and `F0`, and the codes of class `57` other than `57014` |
| `Timeout` | The query timeout, a query that the server cancelled (`57014`), a lock that was not free in time (`55P03`) |
| `Failed` | Anything else, such as a syntax error, a failed check before the run, or more rows than `one` or `maybe_one` take |

### Answer with your own text

Match on the kind, and show your own text. The message of the error is for developers and logs: it can name tables, constraints, hosts and keys. Never show it to the users of your app:

### Answer a sign-up <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/signup_answer.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{
  type Error, Conflict, Failed, Invalid, NotFound, Retry, Timeout, Unavailable,
}
import dream_postgres/error.{type PostgresError}
import snippets/user_row.{type User}

/// The status code and the text that a sign-up page shows for the result
/// of `create_user`. The text is the app's own text, never the message of
/// the error.
pub fn signup_answer(
  created: Result(User, Error(PostgresError)),
) -> #(Int, String) {
  case created {
    Ok(_user) -> #(201, "Welcome.")
    Error(Conflict(..)) -> #(409, "That email has an account already.")
    Error(Invalid(..)) -> #(400, "Please check your input.")
    Error(Retry(..)) | Error(Unavailable(..)) | Error(Timeout(..)) -> #(
      503,
      "Please try again soon.",
    )
    Error(NotFound(..)) | Error(Failed(..)) -> #(500, "Something went wrong.")
  }
}
```

### Tell a taken email apart from other failures

The module `dream_postgres/error` reads the most used details of a failure in one call:

| Function | Result |
|---|---|
| `server_error(failure)` | `Option(ServerError)`, every field that PostgreSQL sent |
| `sql_state(failure)` | `Option(SqlState)`, the SQLSTATE |
| `constraint_name(failure)` | `Option(String)`, the constraint that the failure names |
| `table_name(failure)` | `Option(String)`, the table that the failure names |
| `column_name(failure)` | `Option(String)`, the column that the failure names |
| `describe_error(failure)` | `String`, the kind and the message, for a log line |

Each gives `None` when PostgreSQL sent no such field, for example for a lost connection. This example finds the unique email of the users table:

### Find a taken email <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/email_taken.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/error.{type PostgresError, constraint_name, sql_state}
import dream_postgres/sql_state.{UniqueViolation}
import gleam/option.{Some}

/// True when the failure is a clash on the unique email of the users
/// table.
pub fn is_email_taken(failure: Error(PostgresError)) -> Bool {
  sql_state(failure) == Some(UniqueViolation)
  && constraint_name(failure) == Some("users_email_key")
}
```

`describe_error` never holds a parameter value, so it is safe for a log line.
