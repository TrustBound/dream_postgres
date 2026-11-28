# Trace queries with OpenTelemetry

dream_postgres makes an OpenTelemetry span for each call that your app makes to the database. This guide shows the name and the attributes of each span, what a span never holds, and what your app adds to export the spans. The code blocks are files that the tests of this package run against PostgreSQL, with a test tracer that records the spans.

## Table of Contents

- [What makes a span](#what-makes-a-span)
- [The name of a span](#the-name-of-a-span)
- [The attributes of a span](#the-attributes-of-a-span)
- [What a span never holds](#what-a-span-never-holds)
- [What makes no span](#what-makes-no-span)
- [Export the spans](#export-the-spans)
- [Where to go next](#where-to-go-next)

## What makes a span

dream_postgres depends on `opentelemetry_api` only. The driver starts a span of kind `CLIENT` for each statement that the app sends: the prepare and the run of a query, a `run_sql` call, the commands of a transaction, a `copy_from` and a `copy_to`. The span starts and ends in the process that made the call, so it is a child of the current span of that process, for example the span of an HTTP request.

With no OpenTelemetry SDK running, each span call is a no-op of the API.

A process that is killed during a call leaves its span unended. Such a span is not exported, as for any span of a process that ends before it ends its span.

The attributes follow the OpenTelemetry semantic conventions for PostgreSQL, at commit `7c8eb86d04` of `open-telemetry/semantic-conventions` (the files `docs/db/postgresql.md` and `docs/db/database-spans.md`).

## The name of a span

Give a query a name with `named`. The name becomes the name of the span, and the attribute `db.query.summary`. So the name must be low-cardinality and hold no value: one name for one kind of statement, for example `user.find_by_email`.

### A named query <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/named_query.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/codec.{int, text}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{named, one, parameter, query}
import dream_postgres/row.{single}

/// The span of this query is named `user.find_by_email`.
pub fn find_user_id(
  connection: Connection,
  email: String,
) -> Result(Int, Error(PostgresError)) {
  query("SELECT id FROM users WHERE email = $1")
  |> named("user.find_by_email")
  |> parameter(text, email)
  |> one(single(int), connection)
}
```

The test of `find_user_id` records two spans, the prepare and the run, and both are named `user.find_by_email`.

A query with no name gets the name `{operation} {database}` when the span ends, for example `SELECT app`. The operation comes from the command tag of the server. When the operation is not known, the name is the database alone. That is the case for a prepare, and after a failure.

### A query with no name <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/unnamed_query.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/codec.{int}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{one, query}
import dream_postgres/row.{single}

/// This query has no name, so its span is named after the operation and
/// the database, for example `SELECT app`.
pub fn count_users(
  connection: Connection,
) -> Result(Int, Error(PostgresError)) {
  query("SELECT count(*) FROM users")
  |> one(single(int), connection)
}
```

The test of `count_users` on the database `dream_test` records two spans: `dream_test` for the prepare, then `SELECT dream_test` for the run.

The name of a query plays no part in the statement cache, whose key is the SQL text.

## The attributes of a span

| Attribute | Value | When |
|---|---|---|
| `db.system.name` | `postgresql` | always |
| `db.namespace` | the database of the config | always |
| `server.address` | the host of the config | always |
| `server.port` | the port of the config | when it is not 5432 |
| `db.query.summary` | the name of `named` | when the query has a name |
| `db.query.text` | the SQL text | for a prepare, a run and a COPY, whose values go as parameters, but not for a `run_sql` call |
| `db.operation.name` | the operation of the command tag, for example `SELECT` | when the statement worked and gave exactly one tag |
| `db.response.status_code` | the SQLSTATE of the last warning (class `01`), or the SQLSTATE of the failure | when there is one |
| `error.type` | the SQLSTATE of the server, or else the name of the error | when the statement failed |

A failed statement also sets the status of its span to `Error`. The status description stays empty, because a message of the server can hold a value of the statement.

These are the attributes of the two spans of `find_user_id` in the test, with the port 5441 of the test server:

| Span | Attributes |
|---|---|
| prepare | `db.namespace`, `db.query.summary`, `db.query.text`, `db.system.name`, `server.address`, `server.port` |
| run | the same, and `db.operation.name` = `SELECT` |

## What a span never holds

No span holds a parameter value. The test of `find_user_id` passes the email `ada@example.com` as `$1`, and checks every attribute of both spans: `db.query.text` is `SELECT id FROM users WHERE email = $1`, and no attribute holds the email.

A `run_sql` call runs with the simple query protocol, so its text can hold values. Its span has no `db.query.text`.

## What makes no span

The statements that the driver sends for its own work, from its own processes, make no span. They have no span of the app to be a child of, and they would give a new root span for each idle connection at each health check.

- The load of the type catalog
- The `ROLLBACK` and the health check of a pool connection
- The `LISTEN` and `UNLISTEN` of a listener

A hold of a pool connection makes no span of its own either. Each statement on the held connection has its own span.

## Export the spans

To export the spans, the app runs the OpenTelemetry Erlang SDK and an exporter. The SDK is the Hex package `opentelemetry`, and its OTLP exporter is the Hex package `opentelemetry_exporter`. Their setup and their settings are in the [OpenTelemetry Erlang documentation](https://opentelemetry.io/docs/languages/erlang/).

The tests of dream_postgres do not run the SDK or an exporter. They install a test tracer through the API, and they check the spans that it records. So this guide shows no tested code for the setup of the SDK.

## Where to go next

- [Queries](queries.md): `named` and the other parts of a query
- [Interceptors](interceptors.md): run your own code around each request
