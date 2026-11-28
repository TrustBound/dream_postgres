# Check the queries at boot

A query can stop fitting the schema: a migration changes the type of a column, renames it, or drops it. Without a check, the app finds out at the first run of that query. `verify` checks each query of the app against the live database when the app starts, and runs none of them. This guide shows how to make the checks, what `verify` checks, and the message of each failure. Each code block is a file that the tests of this package run against PostgreSQL.

## Table of Contents

- [Make the checks of a module](#make-the-checks-of-a-module)
- [Run the checks at boot](#run-the-checks-at-boot)
- [What verify checks](#what-verify-checks)
- [The messages](#the-messages)
- [What verify does not do](#what-verify-does-not-do)
- [Where to go next](#where-to-go-next)

## Make the checks of a module

A `QueryCheck` is a query and how its rows are read:

- `checked(query, reader)` is the check of a query whose rows the reader reads, as `all`, `one` and `maybe_one` read them.
- `checked_command(query)` is the check of a command whose rows are not read, as `affected` runs it.

A check uses the codec of each parameter, not its value. So a query that is built only for its check gives each parameter `codec.placeholder` of its codec. Each codec has a placeholder: the [codecs guide](codecs.md) lists them.

### Make the checks of the queries of a module <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/user_checks.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/boot_check.{type QueryCheck, checked, checked_command}
import dream_postgres/codec.{int, placeholder, text}
import dream_postgres/query.{named, parameter, query}
import dream_postgres/row.{column, row}

/// The checks of the queries of the user module. A check uses the codec of
/// each parameter, not its value, so each value is a placeholder.
pub fn queries() -> List(QueryCheck) {
  [
    query("SELECT id, email FROM users WHERE id = $1")
      |> named("user.find")
      |> parameter(int, placeholder(int))
      |> checked({
        use id <- column(int)
        use email <- column(text)
        row(#(id, email))
      }),
    query("DELETE FROM users WHERE id = $1")
      |> named("user.delete")
      |> parameter(int, placeholder(int))
      |> checked_command,
  ]
}
```

Give each query the name of the query that the app runs, with `named`. The messages start with that name.

## Run the checks at boot

`verify` takes a list of lists, one list for each module:

### Check the queries at boot <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/check_database.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/boot_check.{verify}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import snippets/user_checks.{queries}

/// Checks each query of the app against the database, at boot.
pub fn check_database(
  connection: Connection,
) -> Result(Nil, List(Error(PostgresError))) {
  verify(connection, [queries()])
}
```

Call it after the pool starts. When it gives an error, stop the app, and log each message.

The error lists one error for each query that fails, in the order of the checks. When the pool gives no connection, the error lists that one error.

## What verify checks

`verify` holds one connection for all checks. For each query:

1. The server prepares the SQL and describes it as it is now, also when the statement cache of the connection holds the query. A missing table or column fails here, with the error of the server.
2. The codec of each parameter is checked against the type of that parameter.
3. The reader is checked against the number and the types of the columns. For an enum, the labels are checked too.

These are the same checks that a run of the query does before it sends its parameters. The check of an `INSERT` inserts no row, because the statement only gets prepared.

## The messages

Each message is the text of `dream_postgres/error.describe`: the kind of `dream_errors`, then the name of the query and what is wrong. The tests of this package check these messages:

| Change | Message |
|---|---|
| The column `email` is now `int4`, and the reader reads it with `codec.text` | `failed: user.find: column 2 (email) is int4, and the query reads it with the text codec` |
| The column `nickname` is now `int4`, and the reader reads it as nullable text | `failed: user.read: column 3 (nickname) is int4, and the query reads it with the nullable text codec` |
| The parameter `$1` is `text`, and the query gives it with `codec.int` | `failed: user.find_by_email: parameter $1 is text, and the query gives it with the int codec` |
| The column `nickname` does not exist | `failed: user.read: column "nickname" does not exist (42703)` |
| The pool is stopped | `unavailable: the pool is stopped` |
| The connection has no database, such as a recorder in playback mode | `failed: the connection has no database to check the queries against` |

## What verify does not do

- It runs no query, so the checks go through no interceptor, and no recorder records them.
- On a connection of a recorder in playback mode, there is no schema to check. The error lists one `NoDatabaseToVerify` error.

## Where to go next

- [Codecs](codecs.md): the codec of each PostgreSQL type, and its placeholder
- [Queries](queries.md): `named`, readers and parameters
