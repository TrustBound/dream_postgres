# Interceptors

An interceptor is a function that each request of a connection goes through before it reaches the database. It can change the request, change or replace the answer, answer with no database, refuse the request, or only watch. This guide shows how to write one, the order of the chain, which requests go through it, and how to simulate a failure in a test. Each code block is a file that the tests of this package run.

## Table of Contents

- [Write an interceptor](#write-an-interceptor)
- [Add interceptors](#add-interceptors)
- [The order of the chain](#the-order-of-the-chain)
- [What goes through the chain](#what-goes-through-the-chain)
- [Answer with no database](#answer-with-no-database)
- [Simulate a failure](#simulate-a-failure)
- [Where to go next](#where-to-go-next)

## Write an interceptor

An interceptor has the type `fn(Request, fn(Request) -> Outcome) -> Outcome`. It gets the request and `next`, the rest of the chain. To pass the request on, it calls `next`. The `Outcome` is `Result(Answer, Reason)`: the answer of the database, or the reason of the failure.

A `Request` has four fields:

| Field | What it holds |
|---|---|
| `sql` | the SQL text |
| `name` | the name that `named` gave the query, or `None` |
| `parameters` | the parameters with their codecs, `$1` first, as `composite.field` makes them. A `run_sql` call has none. |
| `kind` | `Statement`, `Sql`, `CopyFrom(table, columns, rows)` or `CopyTo` |

These two interceptors change the request, and watch the time of each request:

### Two interceptors <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/request_tagging.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/interceptor.{type Outcome, type Request, Request}
import gleam/io
import gleam/option
import gleam/order
import gleam/time/duration
import gleam/time/timestamp

/// Puts a comment in front of the SQL, so that `pg_stat_activity` and the
/// server log show which app sent it.
pub fn tag_with_app_name(
  request: Request,
  next: fn(Request) -> Outcome,
) -> Outcome {
  next(Request(..request, sql: "/* billing */ " <> request.sql))
}

/// Prints the name of each request that took more than 500 milliseconds,
/// or its SQL when it has no name.
pub fn log_slow_queries(
  request: Request,
  next: fn(Request) -> Outcome,
) -> Outcome {
  let started = timestamp.system_time()
  let outcome = next(request)
  let elapsed = timestamp.difference(started, timestamp.system_time())
  case duration.compare(elapsed, duration.milliseconds(500)) {
    order.Gt ->
      io.println("slow query: " <> option.unwrap(request.name, request.sql))
    order.Lt | order.Eq -> Nil
  }
  outcome
}
```

The last `next` of the chain prepares the SQL of the request, checks the parameters and the row reader against the prepared statement, and runs it. So a changed request is still checked before it runs.

## Add interceptors

`intercept` adds an interceptor to the config, for each connection of the pool:

### Add two interceptors to the config <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/start_tagged_pool.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/config.{type Config, intercept}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection, start}
import snippets/request_tagging.{log_slow_queries, tag_with_app_name}

pub fn start_tagged_pool(
  config: Config,
) -> Result(Connection, Error(PostgresError)) {
  config
  |> intercept(tag_with_app_name)
  |> intercept(log_slow_queries)
  |> start
}
```

`with_interceptor` adds an interceptor to one connection value, for the calls that use it. The connection that it got does not change.

### Add an interceptor to one call <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/tagged_query.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/codecs.{text}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection, with_interceptor}
import dream_postgres/query.{one, query}
import dream_postgres/row.{single}
import snippets/request_tagging.{tag_with_app_name}

/// The SQL text that the server runs, with the tag in front of it.
pub fn current_sql(
  connection: Connection,
) -> Result(String, Error(PostgresError)) {
  query("SELECT current_query()")
  |> one(single(text), with_interceptor(connection, tag_with_app_name))
}
```

The test of `current_sql` gets `/* billing */ SELECT current_query()` back from the server.

## The order of the chain

1. The interceptors of the config, in the order that `intercept` added them. The first one gets the request first.
2. The interceptors of `with_interceptor`, in the order that they were added.
3. The recorder of `config.record`, in record mode. It runs after all others, so it records the request as it reaches the database.
4. The database. On a connection of a recorder in playback mode, the recording answers in its place.

The interceptors of `recorder.intercept` are not in this chain. They change only the copy that the recorder keeps, so the database and the app get the real values. The [recorded queries guide](recorded-queries.md) shows them.

Inside a transaction and inside `with_connection`, each request goes through the same chain as on the pool.

## What goes through the chain

| Call | Kind of the request |
|---|---|
| `all`, `one`, `maybe_one`, `affected` | `Statement` |
| `run_sql` | `Sql` |
| `BEGIN`, `COMMIT`, `ROLLBACK` and the savepoint commands of a transaction | `Sql` |
| `copy_from` | `CopyFrom`, with the table, the columns and the rows |
| `copy_to` | `CopyTo`, with the query inside the COPY as its SQL |

These go through no interceptor:

- `verify`, because it runs no query. It only prepares each query.
- The `LISTEN` and `UNLISTEN` of a listener, which has a connection of its own.
- The statements that the driver sends for its own work: the load of the type catalog, and the `ROLLBACK` and the health check of a pool connection.

## Answer with no database

The outcome of the chain goes through the same row reader and the same error mapping as an answer of the database. So an interceptor can answer a request in a test, and the code under test reads that answer as a real one.

`rows` makes an answer of rows. `column` names each result column and its PostgreSQL base type, such as `int4` or `text`. Each field is checked against the type of its column, and written with its codec, as a parameter is. The command tag is `SELECT` and the number of rows.

### Answer a query with rows <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/answer_with_two_posts.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/codecs.{int, text}
import dream_postgres/codecs/composite.{field}
import dream_postgres/interceptor.{type Outcome, type Request, column, rows}
import gleam/option.{None, Some}

pub fn answer_with_two_posts(
  request: Request,
  next: fn(Request) -> Outcome,
) -> Outcome {
  case request.name {
    Some("post.list") ->
      rows([column("id", "int4"), column("title", "text")], [
        [field(int, 1), field(text, "First")],
        [field(int, 2), field(text, "Second")],
      ])
    Some(_) | None -> next(request)
  }
}
```

The code under test reads this answer with its own row reader:

### The code under test <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/list_titles.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/codecs.{int, text}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{all, named, query}
import dream_postgres/row.{type Row, column, row}

/// The id and the title of each post.
pub fn list_titles(
  connection: Connection,
) -> Result(List(#(Int, String)), Error(PostgresError)) {
  query("SELECT id, title FROM posts ORDER BY id")
  |> named("post.list")
  |> all(title_row(), connection)
}

fn title_row() -> Row(#(Int, String)) {
  use id <- column(int)
  use title <- column(text)
  row(#(id, title))
}
```

The test of `list_titles` on a connection with no database and `answer_with_two_posts` gives `[#(1, "First"), #(2, "Second")]`.

`command` makes the answer of a command with no rows. The row count is the last number of the tag, or 0 when the tag ends with no number:

### Answer a command with its tag <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/answer_three_updates.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/interceptor.{type Outcome, type Request, command}
import gleam/option.{None, Some}

pub fn answer_three_updates(
  request: Request,
  next: fn(Request) -> Outcome,
) -> Outcome {
  case request.name {
    // `affected` reads this answer as 3.
    Some("user.deactivate_all") -> command("UPDATE 3")
    Some(_) | None -> next(request)
  }
}
```

An interceptor that answers a `run_sql` call with the answer of another kind of request makes the call fail with `InterceptorFailed`.

## Simulate a failure

Each builder gives a `Reason`. Return it as `Error(reason)`. The reason maps to the error kind of `dream_errors` as a real failure does.

| Builder | Failure | Kind |
|---|---|---|
| `server_error(sql_state, message)` | a server error with the SQLSTATE and the message | by the SQLSTATE: `DeadlockDetected` is `Retry`, `UniqueViolation` is `Conflict` |
| `connection_lost()` | the server closed the connection during the query | `Unavailable` |
| `timeout()` | the query did not finish before its deadline | `Timeout` |
| `refuse(reason)` | the interceptor refused the request, which never reaches the database | `Failed` |

### Simulate a deadlock <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/simulate_deadlock.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/interceptor.{type Outcome, type Request, server_error}
import dream_postgres/sql_state.{DeadlockDetected}
import gleam/option.{None, Some}

pub fn simulate_deadlock(
  request: Request,
  next: fn(Request) -> Outcome,
) -> Outcome {
  case request.name {
    Some("account.transfer") ->
      Error(server_error(DeadlockDetected, "deadlock detected"))
    Some(_) | None -> next(request)
  }
}
```

In a transaction, a simulated failure rolls the transaction back, as a real one does.

### Simulate a lost connection <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/simulate_lost_connection.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/interceptor.{type Outcome, type Request, connection_lost}
import gleam/option.{None, Some}

pub fn simulate_lost_connection(
  request: Request,
  next: fn(Request) -> Outcome,
) -> Outcome {
  case request.name {
    Some("report.build") -> Error(connection_lost())
    Some(_) | None -> next(request)
  }
}
```

### Simulate a timeout <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/simulate_timeout.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/interceptor.{type Outcome, type Request, timeout}
import gleam/option.{None, Some}

pub fn simulate_timeout(
  request: Request,
  next: fn(Request) -> Outcome,
) -> Outcome {
  case request.name {
    Some("report.build") -> Error(timeout())
    Some(_) | None -> next(request)
  }
}
```

### Refuse a request <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/refuse_deletes.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/interceptor.{type Outcome, type Request, refuse}
import gleam/option.{None, Some}

pub fn refuse_deletes(
  request: Request,
  next: fn(Request) -> Outcome,
) -> Outcome {
  case request.name {
    Some("user.delete") -> Error(refuse("the connection is read only"))
    Some(_) | None -> next(request)
  }
}
```

The tests run each of these on a connection with no database, and get the kinds `retry`, `unavailable`, `timeout` and `failed`.

## Where to go next

- [Recorded queries](recorded-queries.md): a recorder is an interceptor that records and plays back
- [Transactions](transactions.md): what a failure does in a transaction
- [Tracing](tracing.md): the spans of the requests
