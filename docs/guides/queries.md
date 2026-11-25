# Running queries and handling their results

A handler that reads from the database needs one of three answers: here's the data, there's no such thing, or something broke. Pog gives you more than that. `dream_postgres_client.execute` returns a `Result(dream_postgres_client.Returned(row), dream_postgres_client.QueryError)`, and `QueryError` has seven variants. The `dream_postgres/query` helpers fold that into the answers a handler needs. This guide shows how to use them in real handlers, when to look past them at the Pog error, and how to test it all without a database.

## Table of Contents

- [What you'll build](#what-youll-build)
- [Before you start](#before-you-start)
- [Which helper to use](#which-helper-to-use)
- [Step 1: Write the query functions](#step-1-write-the-query-functions)
- [Step 2: Turn one row into a response](#step-2-turn-one-row-into-a-response)
- [Step 3: Turn many rows into a response](#step-3-turn-many-rows-into-a-response)
- [Step 4: Tell a duplicate apart from a failure](#step-4-tell-a-duplicate-apart-from-a-failure)
- [Step 5: Keep the cause of a failure](#step-5-keep-the-cause-of-a-failure)
- [What each failure looks like](#what-each-failure-looks-like)
- [Test your code](#test-your-code)
- [Common pitfalls](#common-pitfalls)
- [Where to go next](#where-to-go-next)

## What you'll build

In this guide you'll:

- Write query functions in the shape that Squirrel generates.
- Turn a "find by id" result into a 200 or a 404 response, and a failure into a 500.
- Turn a list result into a response, including the empty list.
- Answer 409 when an insert breaks a unique constraint.
- Log the real cause of a failure before it becomes a 500.
- Test each handler, mostly without a database.

## Before you start

You need the package and `dream_postgres_client` (a fork of Pog), and a connection. The [Getting started](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/getting-started.md) guide shows how to get one from a `DATABASE_URL`.

```sh
gleam add dream_postgres dream_postgres_client
```

The examples use this table. With the `docker-compose.yml` from [Getting started](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/getting-started.md#before-you-start), create it in `psql` (`docker compose exec postgres psql -U dream -d dream_test`):

### Make the users table <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/fixtures/sql/queries_users.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
CREATE TABLE users (
  id serial PRIMARY KEY,
  name text NOT NULL,
  email text NOT NULL UNIQUE
);
```

The handlers return a small `Response` type with a status and a body, which Step 2 defines. Swap in the response type of your web framework. The outputs below come from the package's tests: queries and handlers that run against PostgreSQL 16 on this table, results built by hand, and handlers that run on a pool where no database listens.

## Which helper to use

| Your situation | Use | Why |
|:---|:---|:---|
| The query finds one thing, such as a row by its id | `query.first_row(result)` | You get the row, `NotFound` for no rows, or `DatabaseError`. That's a 200, a 404 or a 500. |
| The query returns a list, and an empty list is a valid answer | `query.all_rows(result)` | You get every row, `[]` when there are none, or `DatabaseError`. |
| One kind of failure needs its own answer, such as a duplicate email | Match the `dream_postgres_client.QueryError` first, then use a helper for the rest | The helpers turn every Pog error into `DatabaseError`, so the detail is gone after them. |
| You need the number of rows an `UPDATE` or `DELETE` changed | `returned.count` from the Pog result | The helpers return rows, not the count. |

## Step 1: Write the query functions

Keep each query in a function that takes a connection and the parameters, and returns Pog's result unchanged. [Squirrel](https://hexdocs.pm/squirrel) generates functions in this shape from `.sql` files: a row type per query, and a function that returns `Result(dream_postgres_client.Returned(Row), dream_postgres_client.QueryError)`. Whether you generate them or write them by hand, the rest of this guide works the same:

### Query functions for the users table <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/guide_queries_sql.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres_client
import gleam/dynamic/decode

pub type FindUserRow {
  FindUserRow(id: Int, name: String, email: String)
}

pub fn find_user(
  db: dream_postgres_client.Connection,
  id: Int,
) -> Result(
  dream_postgres_client.Returned(FindUserRow),
  dream_postgres_client.QueryError,
) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    use name <- decode.field(1, decode.string)
    use email <- decode.field(2, decode.string)
    decode.success(FindUserRow(id:, name:, email:))
  }
  "SELECT id, name, email FROM users WHERE id = $1"
  |> dream_postgres_client.query
  |> dream_postgres_client.parameter(dream_postgres_client.int(id))
  |> dream_postgres_client.returning(decoder)
  |> dream_postgres_client.execute(db)
}

pub type ListUsersRow {
  ListUsersRow(id: Int, name: String)
}

pub fn list_users(
  db: dream_postgres_client.Connection,
) -> Result(
  dream_postgres_client.Returned(ListUsersRow),
  dream_postgres_client.QueryError,
) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    use name <- decode.field(1, decode.string)
    decode.success(ListUsersRow(id:, name:))
  }
  "SELECT id, name FROM users ORDER BY name"
  |> dream_postgres_client.query
  |> dream_postgres_client.returning(decoder)
  |> dream_postgres_client.execute(db)
}

pub type CreateUserRow {
  CreateUserRow(id: Int)
}

pub fn create_user(
  db: dream_postgres_client.Connection,
  name: String,
  email: String,
) -> Result(
  dream_postgres_client.Returned(CreateUserRow),
  dream_postgres_client.QueryError,
) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(CreateUserRow(id:))
  }
  "INSERT INTO users (name, email) VALUES ($1, $2) RETURNING id"
  |> dream_postgres_client.query
  |> dream_postgres_client.parameter(dream_postgres_client.text(name))
  |> dream_postgres_client.parameter(dream_postgres_client.text(email))
  |> dream_postgres_client.returning(decoder)
  |> dream_postgres_client.execute(db)
}
```

Each function builds a query, fills the `$1` and `$2` parameters with `dream_postgres_client.parameter`, decodes each row with `dream_postgres_client.returning`, and runs it with `dream_postgres_client.execute`. The values travel as parameters, never as part of the SQL text, so they can't change the query.

In this guide's tested code the module is `snippets/guide_queries_sql`. The handlers import it `as sql`, which is what an import of a Squirrel module (`import app/sql`) looks like in your app.

### Generate the query functions

[dream_sql_generator](https://hexdocs.pm/dream_sql_generator), a fork of Squirrel, writes these query functions from your `.sql` files. Set its `client_module` to `dream_postgres/client` in `gleam.toml`:

### Point the SQL generator at dream_postgres/client <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/fixtures/generated/gleam.toml"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```toml
[dev-dependencies]
dream_sql_generator = ">= 1.0.0 and < 2.0.0"

[tools.dream_sql_generator]
client_module = "dream_postgres/client"
```

The generated module then starts with `import dream_postgres/client as pog`. Each function calls `pog.query`, `pog.parameter`, `pog.returning` and `pog.execute`. `dream_postgres/client` has these functions, the value functions such as `pog.int` and `pog.text`, and the decoders such as `pog.timestamp_decoder`. So your app needs no `dream_postgres_client` import for the generated code. This is one function that the generator wrote for the `database` example of Dream:

### A generated query function <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/generated/database_sql.gleam#L215-L239"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
pub fn get_user(
  connection: pog.Connection,
  id: Int,
) -> Result(pog.Returned(GetUserRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    use name <- decode.field(1, decode.string)
    use email <- decode.field(2, decode.string)
    use created_at <- decode.field(3, decode.optional(pog.timestamp_decoder()))
    decode.success(GetUserRow(id:, name:, email:, created_at:))
  }

  "-- Get a single user by ID
SELECT id, name, email, created_at FROM users WHERE id = $1





"
  |> pog.query
  |> pog.parameter(pog.int(id))
  |> pog.returning(decoder)
  |> pog.execute(connection)
}
```

The tests of this package run every query of two generated modules against PostgreSQL 16 through `dream_postgres/client`, then play them back with no database.

## Step 2: Turn one row into a response

A "show user" handler runs `find_user` and turns its result into a response. Split those two parts into two functions:

### Answer with one user <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/guide_queries_show_user.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/query
import dream_postgres_client
import gleam/int
import snippets/guide_queries_sql as sql

pub type Response {
  Response(status: Int, body: String)
}

pub fn show_user(db: dream_postgres_client.Connection, id: Int) -> Response {
  sql.find_user(db, id)
  |> user_response
}

pub fn user_response(
  result: Result(
    dream_postgres_client.Returned(sql.FindUserRow),
    dream_postgres_client.QueryError,
  ),
) -> Response {
  case query.first_row(result) {
    Ok(user) ->
      Response(
        200,
        int.to_string(user.id) <> ": " <> user.name <> " <" <> user.email <> ">",
      )
    Error(query.NotFound) -> Response(404, "No user with that id")
    Error(query.DatabaseError) -> Response(500, "Internal server error")
  }
}
```

`show_user` is the handler your router calls. It does nothing but run the query and pass the result on. `user_response` holds the logic, and it needs no connection:

- `query.first_row(result)` returns `Ok(user)` with the first row, which becomes a 200.
- `Error(query.NotFound)` means the query worked and returned no rows, so there's no user with that id: a 404.
- `Error(query.DatabaseError)` means the query itself failed, for any reason: a 500.

Against the table, after `sql.create_user(db, "Ada", "ada@example.com")` gave Ada the id 1, here's what `show_user` answers:

### What show_user answers <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/outputs/guide_queries_show_user.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
show_user(db, 1)
  -> Response(200, "1: Ada <ada@example.com>")

show_user(db, 2)
  -> Response(404, "No user with that id")
```

And here's what `user_response` returns for each case, with results built by hand:

### What user_response returns <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/outputs/guide_queries_user_response.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
user_response(Ok(dream_postgres_client.Returned(count: 1, rows: [FindUserRow(1, "Ada", "ada@example.com")])))
  -> Response(200, "1: Ada <ada@example.com>")

user_response(Ok(dream_postgres_client.Returned(count: 0, rows: [])))
  -> Response(404, "No user with that id")

user_response(Error(dream_postgres_client.QueryTimeout))
  -> Response(500, "Internal server error")
```

## Step 3: Turn many rows into a response

For a list, an empty result isn't an error. `all_rows` gives you `Ok([])` for it, and never `NotFound`:

### Answer with every user <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/guide_queries_list_users.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/query
import dream_postgres_client
import gleam/list
import gleam/string
import snippets/guide_queries_show_user.{type Response, Response}
import snippets/guide_queries_sql as sql

pub fn index_users(db: dream_postgres_client.Connection) -> Response {
  sql.list_users(db)
  |> users_response
}

pub fn users_response(
  result: Result(
    dream_postgres_client.Returned(sql.ListUsersRow),
    dream_postgres_client.QueryError,
  ),
) -> Response {
  case query.all_rows(result) {
    Ok([]) -> Response(200, "No users yet")
    Ok(users) ->
      Response(200, string.join(list.map(users, fn(user) { user.name }), ", "))
    // all_rows never gives NotFound, so one branch covers the failure
    Error(_error) -> Response(500, "Internal server error")
  }
}
```

`Ok([])` comes first, so an empty table gets its own message. `Ok(users)` joins the names. `all_rows` only fails with `DatabaseError`, but the error type has `NotFound` too, so the last branch matches any error with `Error(_error)`.

### What index_users and users_response return <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/outputs/guide_queries_index_users.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
index_users(db)                       // the table is empty
  -> Response(200, "No users yet")

index_users(db)                       // after Grace, then Ada, signed up
  -> Response(200, "Ada, Grace")

users_response(Ok(dream_postgres_client.Returned(count: 2, rows: [ListUsersRow(1, "Ada"), ListUsersRow(2, "Grace")])))
  -> Response(200, "Ada, Grace")

users_response(Ok(dream_postgres_client.Returned(count: 0, rows: [])))
  -> Response(200, "No users yet")

index_users(<a pool where nothing listens>)
  -> Response(500, "Internal server error")
```

## Step 4: Tell a duplicate apart from a failure

`DatabaseError` is right for "something broke", but some failures are the user's to fix. When a sign-up uses an email that's already taken, the `UNIQUE` constraint on `email` stops the insert, and the user should get a 409 with a message, not a 500. Pog reports that as `dream_postgres_client.ConstraintViolated`, with the name of the constraint. Match it before the result reaches `first_row`:

### Answer 409 for a duplicate email <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/guide_queries_create_user.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/query
import dream_postgres_client
import gleam/int
import snippets/guide_queries_show_user.{type Response, Response}
import snippets/guide_queries_sql as sql

pub fn create_user(
  db: dream_postgres_client.Connection,
  name: String,
  email: String,
) -> Response {
  sql.create_user(db, name, email)
  |> created_response
}

pub fn created_response(
  result: Result(
    dream_postgres_client.Returned(sql.CreateUserRow),
    dream_postgres_client.QueryError,
  ),
) -> Response {
  case result {
    Error(dream_postgres_client.ConstraintViolated(
      constraint: "users_email_key",
      ..,
    )) -> Response(409, "That email is already taken")
    _ -> new_user_response(result)
  }
}

fn new_user_response(
  result: Result(
    dream_postgres_client.Returned(sql.CreateUserRow),
    dream_postgres_client.QueryError,
  ),
) -> Response {
  case query.first_row(result) {
    Ok(created) -> Response(201, "Created user " <> int.to_string(created.id))
    Error(_error) -> Response(500, "Internal server error")
  }
}
```

`created_response` looks at the raw Pog result first. `users_email_key` is the name PostgreSQL gives a `UNIQUE` constraint on the `email` column of `users`, so only that violation becomes a 409. Every other result goes on to `new_user_response`, which uses `first_row` as before. The two functions keep the match flat, with one `case` each.

Here's the handler against the table, for a first sign-up and a second one with the same email, and the Pog error behind the 409:

### What create_user answers <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/outputs/guide_queries_create_user.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
create_user(db, "Ada", "ada@example.com")
  -> Response(201, "Created user 1")

create_user(db, "Ada", "ada@example.com")
  -> Response(409, "That email is already taken")

sql.create_user(db, "Ada", "ada@example.com")   // the email is taken
  -> Error(ConstraintViolated(
       message: "duplicate key value violates unique constraint \"users_email_key\"",
       constraint: "users_email_key",
       detail: "Key (email)=(ada@example.com) already exists.",
     ))
```

And with results built by hand:

### What created_response returns <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/outputs/guide_queries_created_response.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
created_response(Ok(dream_postgres_client.Returned(count: 1, rows: [CreateUserRow(7)])))
  -> Response(201, "Created user 7")

created_response(Error(dream_postgres_client.ConstraintViolated(constraint: "users_email_key", ..)))
  -> Response(409, "That email is already taken")

created_response(Error(dream_postgres_client.ConstraintViolated(constraint: "users_name_check", ..)))
  -> Response(500, "Internal server error")
```

A constraint you didn't plan for still becomes a 500, because you didn't decide what the user should do about it.

## Step 5: Keep the cause of a failure

`DatabaseError` tells the handler what to answer, but it doesn't tell you why. Was it a timeout, a missing table, a row that didn't decode? The Pog error knows, and once `first_row` has run it's gone. Log it on the way through:

### Log the Pog error, then answer <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/guide_queries_log_failure.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres_client
import gleam/io
import gleam/string
import snippets/guide_queries_show_user.{type Response, user_response}
import snippets/guide_queries_sql as sql

pub fn show_user(db: dream_postgres_client.Connection, id: Int) -> Response {
  sql.find_user(db, id)
  |> log_failure
  |> user_response
}

pub fn log_failure(
  result: Result(
    dream_postgres_client.Returned(row),
    dream_postgres_client.QueryError,
  ),
) -> Result(
  dream_postgres_client.Returned(row),
  dream_postgres_client.QueryError,
) {
  case result {
    Error(error) -> io.println_error("Query failed: " <> string.inspect(error))
    Ok(_returned) -> Nil
  }
  result
}
```

`log_failure` writes the Pog error to standard error and gives back the result it got, so it drops into the pipeline between the query and the response function. When no database listens, `show_user` still answers `Response(500, "Internal server error")`, and the log line names the cause: `Query failed: ConnectionUnavailable`. When the `users` table is missing, the answer is the same 500, and the log line says why: `Query failed: PostgresqlError("42P01", "undefined_table", "relation \"users\" does not exist")`.

Swap `io.println_error` for your logger. Pog errors hold the SQL error message and constraint details, not the connection settings, but they can hold values from the row (the `detail` of a unique violation names the duplicate value), so treat them like any other log line with user data.

## What each failure looks like

These are the errors `dream_postgres_client.execute` returns, and what the helpers make of them. The first four come from runs against PostgreSQL 16. The last three come from Pog's documentation.

| Pog error | What it means | After `first_row` or `all_rows` |
|:---|:---|:---|
| `ConnectionUnavailable` | The pool had no connection for the query within 2 to 3 seconds: nothing listens, the login failed, the database doesn't exist, or the pool size is 0 | `DatabaseError` |
| `QueryTimeout` | The query ran longer than its timeout (5 seconds unless you set `dream_postgres_client.timeout`, from Pog's source). With `dream_postgres_client.timeout(200)`, `SELECT pg_sleep(1)` gives it after 200 ms. | `DatabaseError` |
| `ConstraintViolated(message, constraint, detail)` | The change broke a constraint, such as `UNIQUE` or a foreign key | `DatabaseError` |
| `PostgresqlError(code, name, message)` | PostgreSQL refused the query, for example `PostgresqlError("42P01", "undefined_table", ..)` for a missing table, or `PostgresqlError("42601", "syntax_error", "syntax error at or near \"SELEC\"")` for bad SQL | `DatabaseError` |
| `UnexpectedArgumentCount(expected, got)` | The number of parameters doesn't match the `$n` in the SQL | `DatabaseError` |
| `UnexpectedArgumentType(expected, got)` | A parameter has the wrong type | `DatabaseError` |
| `UnexpectedResultType(errors)` | A row didn't decode with your decoder | `DatabaseError` |

An empty result isn't in this table, because it's not an error: `dream_postgres_client.execute` returns `Ok` with no rows, `first_row` makes it `NotFound` and `all_rows` makes it `[]`.

## Test your code

Because each handler splits the query from the response logic, most tests need no database. Build the result the database would return, call the response function, and check the response. For the "database is down" path, run the handler itself on a pool where nothing listens.

These tests use [dream_test](https://hexdocs.pm/dream_test), added as the [Getting started](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/getting-started.md#test-your-code) guide shows:

### Test the user handlers <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/guide_queries_testing.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/client as postgres
import dream_postgres_client
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import snippets/guide_queries_create_user.{created_response}
import snippets/guide_queries_show_user.{Response, show_user, user_response}
import snippets/guide_queries_sql.{FindUserRow}

pub fn tests() -> TestSuite {
  describe("user handlers", [
    it("answers 200 with the user of the first row", fn() {
      // Arrange
      let ada = FindUserRow(id: 1, name: "Ada", email: "ada@example.com")
      let result = Ok(dream_postgres_client.Returned(count: 1, rows: [ada]))

      // Act
      let response = user_response(result)

      // Assert
      response
      |> should
      |> be_equal(Response(200, "1: Ada <ada@example.com>"))
      |> or_fail_with("Expected 200 with Ada")
    }),
    it("answers 404 when no row has the id", fn() {
      // Arrange
      let result = Ok(dream_postgres_client.Returned(count: 0, rows: []))

      // Act
      let response = user_response(result)

      // Assert
      response
      |> should
      |> be_equal(Response(404, "No user with that id"))
      |> or_fail_with("Expected 404")
    }),
    it("answers 409 when the email is taken", fn() {
      // Arrange
      let result =
        Error(dream_postgres_client.ConstraintViolated(
          message: "duplicate key value violates unique constraint \"users_email_key\"",
          constraint: "users_email_key",
          detail: "Key (email)=(ada@example.com) already exists.",
        ))

      // Act
      let response = created_response(result)

      // Assert
      response
      |> should
      |> be_equal(Response(409, "That email is already taken"))
      |> or_fail_with("Expected 409")
    }),
    it("answers 500 when the database is not there", fn() {
      // Arrange
      // Nothing listens on port 1 of this machine
      let assert Ok(db) =
        postgres.from_url("postgresql://app:secret@127.0.0.1:1/app")

      // Act
      let response = show_user(db, 1)

      // Assert
      response
      |> should
      |> be_equal(Response(500, "Internal server error"))
      |> or_fail_with("Expected 500")
    }),
  ])
}
```

What each test covers:

- `dream_postgres_client.Returned(count: 1, rows: [ada])` is the value `find_user` returns when the user exists. The row type is a plain record, so you build it like any other.
- `dream_postgres_client.Returned(count: 0, rows: [])` is the result for an id that doesn't exist.
- `dream_postgres_client.ConstraintViolated(..)` is the error PostgreSQL gives for a duplicate email, value for value: this package's tests insert the same email twice and get exactly this error. You can build any Pog error the same way, so you can test a 409 without a database that holds a duplicate.
- The last test runs `show_user` on a pool on port 1 of `127.0.0.1`, where nothing listens. It takes 2 to 3 seconds, so keep one or two tests like it.

To test the SQL itself, run the query functions against a real test database with the tables you need. That checks what a hand-built result can't: that the SQL is valid and the decoder matches the columns.

## Common pitfalls

**Expecting `NotFound` from `all_rows`.** *Symptom:* an empty list shows up as a 200 with an empty body, when you meant a 404. *Fix:* `all_rows` returns `Ok([])` for no rows. Match `Ok([])` yourself, as in [Step 3](#step-3-turn-many-rows-into-a-response).

**Using `first_row` on a query that can return many rows.** *Symptom:* the handler answers with some row, and which one changes from call to call. *Fix:* `first_row` takes the first row and ignores the rest. Use it for queries by a unique key, or add `ORDER BY` and `LIMIT 1` to the SQL.

**A 500 with no clue why.** *Symptom:* the logs show nothing, and `DatabaseError` is all you have. *Fix:* the helpers keep no detail. Log the Pog error before you call them, as in [Step 5](#step-5-keep-the-cause-of-a-failure).

**A duplicate becomes a 500.** *Symptom:* users who sign up twice see "Internal server error". *Fix:* match `dream_postgres_client.ConstraintViolated` with the constraint name before the helper, as in [Step 4](#step-4-tell-a-duplicate-apart-from-a-failure).

**A decoder that doesn't match the SQL.** *Symptom:* every call fails with `DatabaseError`, and Step 5's log shows `UnexpectedResultType`. *Fix:* the decoder reads columns by position. Keep `decode.field(0, ..)`, `decode.field(1, ..)` in the order of the `SELECT`, and use `decode.optional` for a column that can be `NULL`. Squirrel writes the decoder from the SQL, which removes this class of bug.

## Where to go next

- [Getting started](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/getting-started.md): a first connection, a startup check and a first query.
- [Connecting to PostgreSQL in production](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/connecting.md): SSL, pool size, IPv6 and a supervised pool.
- [README](https://github.com/TrustBound/dream_postgres/blob/main/README.md): the package at a glance.
- [API reference on HexDocs](https://hexdocs.pm/dream_postgres/dream_postgres/query.html): `first_row`, `all_rows` and `QueryError`.
- [Squirrel on HexDocs](https://hexdocs.pm/squirrel/): generate the query functions from SQL files.
- [Pog on HexDocs](https://hexdocs.pm/pog/pog.html), which has the same API as `dream_postgres_client`: queries, parameters, decoders, timeouts and transactions.
