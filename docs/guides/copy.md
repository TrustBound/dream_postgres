# Load and export rows with COPY

This guide shows `copy_from`, which stores many rows with one binary `COPY ... FROM STDIN`, and `copy_to`, which reads the rows of a query with one binary `COPY (...) TO STDOUT`. Each code block is a file that the tests of this package run against PostgreSQL.

## Table of Contents

- [When to use COPY](#when-to-use-copy)
- [Store rows with copy_from](#store-rows-with-copy_from)
- [Name the table](#name-the-table)
- [Read rows with copy_to](#read-rows-with-copy_to)
- [Fold into one value](#fold-into-one-value)
- [Stop a COPY early](#stop-a-copy-early)
- [What makes a COPY fail before it starts](#what-makes-a-copy-fail-before-it-starts)
- [Where to go next](#where-to-go-next)

## When to use COPY

Use `copy_from` to store many rows at once, for example an import. It sends all rows in one statement, so it is the fastest way to load rows. Use `copy_to` to read a result that is too large to keep in memory, for example an export. It reads one row at a time.

For a few rows, an `INSERT` with `affected` or `one` is simpler. The [queries guide](queries.md) shows those functions.

## Store rows with copy_from

The examples use this table:

```sql illustration
CREATE TABLE users (id int4, email text)
```

A `User` has an id and an email that can be NULL. `user_fields` gives the fields of one user, one for each column, in the order of the columns. `composite.field` pairs a codec with a value, as `parameter` does for a query:

### Store users with one COPY <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/copy_users.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/codecs.{int, nullable, text}
import dream_postgres/codecs/composite.{type Field, field}
import dream_postgres/copy.{copy_from, table}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/row.{type Row, column, row}
import gleam/option.{type Option}

pub type User {
  User(id: Int, email: Option(String))
}

/// Reads the columns id and email, in this order, into a User.
pub fn user_row() -> Row(User) {
  use id <- column(int)
  use email <- column(nullable(text))
  row(User(id:, email:))
}

/// The fields of a user for `copy_from`, in the order of the columns.
pub fn user_fields(user: User) -> List(Field) {
  [field(int, user.id), field(nullable(text), user.email)]
}

pub fn load_users(
  connection: Connection,
  users: List(User),
) -> Result(Int, Error(PostgresError)) {
  copy_from(
    connection,
    into: table("users"),
    columns: ["id", "email"],
    rows: users,
    write: user_fields,
  )
}
```

`copy_from` gives the number of rows that it stored. When any row fails, the COPY ends and the server stores no row of it.

Before the COPY starts, `copy_from` gets the types of the columns from the server. It checks the fields of the first row against those types, as a query checks its parameters. A codec that does not take the type of its column fails with `ParameterTypeMismatch`, and nothing goes to the server.

## Name the table

`table("users")` names a table that the search path finds. `copy_from` quotes the name as a PostgreSQL identifier, so the name is exact: `"Users"` is not `"users"`, and a dot is a part of the name, not a schema. The names of `columns` are quoted the same way.

For a table in a schema, use `table_in_schema`. It quotes the schema and the name each on its own:

### Store rows in a table of a schema <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/load_invoice_totals.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/codecs.{int}
import dream_postgres/codecs/composite.{type Field, field}
import dream_postgres/copy.{copy_from, table_in_schema}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}

/// Stores one invoice row for each total, in the table `invoices` of the
/// schema `billing`.
pub fn load_invoice_totals(
  connection: Connection,
  totals: List(Int),
) -> Result(Int, Error(PostgresError)) {
  copy_from(
    connection,
    into: table_in_schema("billing", "invoices"),
    columns: ["total"],
    rows: totals,
    write: total_fields,
  )
}

fn total_fields(total: Int) -> List(Field) {
  [field(int, total)]
}
```

## Read rows with copy_to

`copy_to` runs the query inside a COPY, and folds over its rows. `with` gets the value so far and the next row. `from` is the first value. This export prepends each user to a list, then reverses the list:

### Read every user with one COPY <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/export_users.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/copy.{copy_to}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{query}
import gleam/list
import gleam/result
import snippets/copy_users.{type User, user_row}

pub fn export_users(
  connection: Connection,
) -> Result(List(User), Error(PostgresError)) {
  copy_to(
    connection,
    query("SELECT id, email FROM users ORDER BY id"),
    read: user_row(),
    from: [],
    with: list.prepend,
  )
  |> result.map(list.reverse)
}
```

The query is prepared first, and the row reader is checked against its columns, as `all` checks them. Then the rows come one at a time. The connection reads the next row from the server only after `with` took the last one. So the whole result is never in memory, also when the fold keeps only a part of it.

The connection serves no other call until `copy_to` returns.

## Fold into one value

A fold does not have to make a list. This one keeps only a sum:

### Sum a column with one COPY <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/sum_of_totals.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/codecs.{int}
import dream_postgres/copy.{copy_to}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{query}
import dream_postgres/row.{single}
import gleam/int

/// The sum of the totals of all invoices. The rows come one at a time, and
/// only the sum stays in memory.
pub fn sum_of_totals(
  connection: Connection,
) -> Result(Int, Error(PostgresError)) {
  copy_to(
    connection,
    query("SELECT total FROM billing.invoices"),
    read: single(int),
    from: 0,
    with: int.add,
  )
}
```

## Stop a COPY early

A row that the reader cannot read stops `copy_to`, with the reason of that row, for example `UnexpectedNull`. The driver then reads the rest of the COPY from the server and drops it. The session stays usable, and so does a transaction that the COPY runs in. The time that this takes grows with the rows that are left, and the query timeout of the config limits it.

This function reads each total with `codecs.int`, which takes no NULL. A NULL total stops the COPY. The transaction goes on, and a query counts the invoices instead:

### Go on in the transaction after a stopped COPY <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/count_invoices.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/codecs.{int}
import dream_postgres/copy.{copy_to}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{one, query}
import dream_postgres/row.{single}
import dream_postgres/transaction.{keep_both, run, transaction}
import gleam/function
import gleam/list

/// The number of invoices, in one transaction. The COPY reads each total
/// with a codec that takes no NULL, so a NULL total stops it. The
/// transaction stays usable, and a query counts the invoices instead.
pub fn count_invoices(
  connection: Connection,
) -> Result(Int, Error(PostgresError)) {
  transaction(
    connection,
    database: function.identity,
    rollback_also_failed: keep_both,
  )
  |> run(count_invoices_in_transaction)
}

fn count_invoices_in_transaction(
  connection: Connection,
) -> Result(Int, Error(PostgresError)) {
  let totals =
    copy_to(
      connection,
      query("SELECT total FROM billing.invoices"),
      read: single(int),
      from: [],
      with: list.prepend,
    )
  case totals {
    Ok(all_totals) -> Ok(list.length(all_totals))
    Error(_null_total) ->
      query("SELECT count(*) FROM billing.invoices")
      |> one(single(int), connection)
  }
}
```

The test of this function stores three totals and one NULL, and gets 4.

A failed row of `copy_from` stops that COPY too. The server gets a CopyFail message, so it stores no row of the COPY, and the connection stays usable.

## What makes a COPY fail before it starts

| Failure | Reason | Kind |
|---|---|---|
| A field or a column reader has the codec of `codecs.custom`, which uses the text format. A binary COPY needs codecs in the binary format. | `CopyNeedsBinaryCodec` | `Failed` |
| The query of `copy_to` has parameters. PostgreSQL takes no parameters in a COPY statement. | `CopyQueryHasParameters` | `Failed` |
| A field of the first row does not fit the type of its column. | `ParameterTypeMismatch` | `Failed` |
| The reader of `copy_to` does not fit the columns of the query. | as for `all` | `Failed` |

In each case nothing goes to the server.

Each COPY goes through the interceptors of the connection, as a `CopyFrom` or a `CopyTo` request. A recorder records it and plays it back. The [interceptors guide](interceptors.md) and the [recorded queries guide](recorded-queries.md) show both.

## Where to go next

- [Interceptors](interceptors.md): watch, change or answer each request, a COPY too
- [Transactions](transactions.md): run a COPY with other statements in one transaction
- [Tracing](tracing.md): the span of each COPY
