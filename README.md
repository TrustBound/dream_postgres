<div align="center">
  <img src="https://raw.githubusercontent.com/TrustBound/dream/main/ricky_and_lucy.png" alt="Ricky Moony and Lucy, a moon shaped mascot for Dream with the star shaped mascot for Gleam, each with cute cartoon eyes and a smile" width="200">

<b>A PostgreSQL client for Gleam, with queries that are checked against the database before they run</b>

</div>

<br />

<div align="center">
  <a href="https://hex.pm/packages/dream_postgres"><img src="https://img.shields.io/hexpm/v/dream_postgres" alt="Hex Package"></a>
  <a href="https://github.com/TrustBound/dream_postgres/releases"><img src="https://img.shields.io/github/v/release/TrustBound/dream_postgres?label=Release" alt="Latest Release"></a>
  <a href="https://hexdocs.pm/dream_postgres"><img src="https://img.shields.io/badge/hex-docs-lightgreen.svg" alt="HexDocs"></a>
  <a href="https://github.com/TrustBound/dream_postgres/actions/workflows/ci.yml?query=branch%3Amain"><img src="https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/TrustBound/dream_postgres/badges/coverage.json" alt="Coverage"></a>
  <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/LICENSE.md"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License"></a>
  <a href="https://gleam.run"><img src="https://img.shields.io/badge/gleam-%E2%9C%A8-ffaff3" alt="Gleam"></a>
</div>

<br />

# dream_postgres

dream_postgres is a PostgreSQL client for Gleam on the Erlang target. It keeps a pool of connections, checks the codecs of each query against the types of the database before the query runs, and runs transactions as a pipe of steps. Every failure is a `dream_errors.Error`, so your app handles it the same way as the errors of the other [Dream](https://github.com/TrustBound/dream) packages.

dream_postgres has its own implementation of the PostgreSQL protocol. It has no dependency on another PostgreSQL client.

## Features

- ✅ A pool of connections, alone or under your supervisor, with reconnects and health checks
- ✅ TLS on by default, with the certificate and the host checked, and the `sslmode` settings of libpq
- ✅ Login with SCRAM-SHA-256 and channel binding, MD5, or a cleartext password
- ✅ Queries with typed parameters and row readers, checked against the server before each run
- ✅ Codecs for the built-in types, for `hstore`, `citext` and pgvector, and for your own enums, composite types and extension types
- ✅ Transactions as a pipe of steps and checks, with isolation levels and savepoints
- ✅ Errors with a kind from `dream_errors` and every field that PostgreSQL sent
- ✅ Binary `COPY`, `LISTEN` and `NOTIFY`, interceptors, OpenTelemetry traces, recorded queries for tests, and a boot check of every query

## Installation

```sh
gleam add dream_postgres dream_errors
```

## Quick Start

Start a pool. The local test server has no certificate, so this example turns TLS off. In production, keep the default, which requires TLS:

### Start a pool <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/connect.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a> <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/docs/guides/getting-started.md#start-a-pool-"><img align="right" alt="Guide: Getting started with dream_postgres" title="Guide: Getting started with dream_postgres" src="https://img.shields.io/badge/%F0%9F%93%96_read-guide-blue.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/config.{
  TlsOff, database, default_config, host, password, pool_size, port, tls, user,
}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection, start}

/// Starts a pool of 4 connections to the database `dream_test` on this
/// machine. The local test server has no certificate, so TLS is off.
pub fn connect(port_number: Int) -> Result(Connection, Error(PostgresError)) {
  default_config()
  |> host("localhost")
  |> port(port_number)
  |> database("dream_test")
  |> user("dream")
  |> password("dream")
  |> pool_size(4)
  |> tls(TlsOff)
  |> start
}
```

Read each row into a value with a row reader:

### A row reader for users <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/user_row.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a> <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/docs/guides/queries.md#a-row-reader-for-users-"><img align="right" alt="Guide: Queries" title="Guide: Queries" src="https://img.shields.io/badge/%F0%9F%93%96_read-guide-blue.svg?style=flat-square"></a>

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

Run a query with parameters:

### Store a user <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/create_user.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a> <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/docs/guides/queries.md#store-a-user-"><img align="right" alt="Guide: Queries" title="Guide: Queries" src="https://img.shields.io/badge/%F0%9F%93%96_read-guide-blue.svg?style=flat-square"></a>

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

### Find a user by email <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/find_user.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a> <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/docs/guides/queries.md#find-a-user-by-email-"><img align="right" alt="Guide: Queries" title="Guide: Queries" src="https://img.shields.io/badge/%F0%9F%93%96_read-guide-blue.svg?style=flat-square"></a>

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

Run several statements as one transaction:

### Move money between accounts <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/move_money.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a> <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/docs/guides/transactions.md#move-money-between-accounts-"><img align="right" alt="Guide: Transactions" title="Guide: Transactions" src="https://img.shields.io/badge/%F0%9F%93%96_read-guide-blue.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error, Invalid}
import dream_postgres/codec.{int}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{affected, one, parameter, query}
import dream_postgres/row.{single}
import dream_postgres/transaction.{check, commit, step, transaction}
import gleam/result

/// Why a move of money failed.
pub type MoveMoneyCause {
  /// The first account has less money than the move takes.
  NotEnoughFunds(balance: Int, wanted: Int)
  /// A statement of the move failed.
  Database(PostgresError)
  /// A step failed, and the rollback after it failed too.
  RollbackAlsoFailed(
    step_error: Error(MoveMoneyCause),
    rollback_error: PostgresError,
  )
}

/// Moves money from one account to another in one transaction. Nothing
/// changes when the first account has too little money.
pub fn move_money(
  connection: Connection,
  from: Int,
  to: Int,
  cents: Int,
) -> Result(Nil, Error(MoveMoneyCause)) {
  transaction(
    connection,
    database: Database,
    rollback_also_failed: RollbackAlsoFailed,
  )
  |> step(debit(_, from, cents))
  |> check(require_funds(_, cents))
  |> step(credit(_, to, cents))
  |> commit
}

/// Takes the cents from the account, and gives the new balance.
fn debit(
  connection: Connection,
  account_id: Int,
  cents: Int,
) -> Result(Int, Error(PostgresError)) {
  "UPDATE accounts SET balance = balance - $1 WHERE id = $2 RETURNING balance"
  |> query
  |> parameter(int, cents)
  |> parameter(int, account_id)
  |> one(single(int), connection)
}

/// Refuses a balance below 0 after the debit.
fn require_funds(
  balance_after: Int,
  wanted: Int,
) -> Result(Nil, Error(MoveMoneyCause)) {
  case balance_after >= 0 {
    True -> Ok(Nil)
    False ->
      Error(Invalid(
        "not enough funds",
        NotEnoughFunds(balance: balance_after + wanted, wanted:),
      ))
  }
}

/// Adds the cents to the account.
fn credit(
  connection: Connection,
  account_id: Int,
  cents: Int,
) -> Result(Nil, Error(PostgresError)) {
  "UPDATE accounts SET balance = balance + $1 WHERE id = $2"
  |> query
  |> parameter(int, cents)
  |> parameter(int, account_id)
  |> affected(connection)
  |> result.replace(Nil)
}
```

Match on the kind of a failure, and show your own text:

### Answer a sign-up <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/signup_answer.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a> <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/docs/guides/queries.md#answer-a-sign-up-"><img align="right" alt="Guide: Queries" title="Guide: Queries" src="https://img.shields.io/badge/%F0%9F%93%96_read-guide-blue.svg?style=flat-square"></a>

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

## Guides

- [Getting started](https://github.com/TrustBound/dream_postgres/blob/3.0.0/docs/guides/getting-started.md): start a pool, make tables, store a user and read users back
- [Connecting to PostgreSQL](https://github.com/TrustBound/dream_postgres/blob/3.0.0/docs/guides/connecting.md): the config, TLS, a supervised pool, reconnects, PgBouncer, notices and pool events
- [Pool tuning](https://github.com/TrustBound/dream_postgres/blob/3.0.0/docs/guides/pool-tuning.md): the pool size, the checkout timeout, the query timeout and the other times of the pool
- [Queries](https://github.com/TrustBound/dream_postgres/blob/3.0.0/docs/guides/queries.md): build a query, read its rows, run it, and handle its errors
- [Transactions](https://github.com/TrustBound/dream_postgres/blob/3.0.0/docs/guides/transactions.md): steps, checks, isolation, savepoints, a commit that rolls back, and a rollback that fails
- [Codecs](https://github.com/TrustBound/dream_postgres/blob/3.0.0/docs/guides/codecs.md): every codec with its PostgreSQL types, and enums, JSON, custom and composite codecs
- [COPY](https://github.com/TrustBound/dream_postgres/blob/3.0.0/docs/guides/copy.md): load and read many rows with binary `COPY`
- [LISTEN and NOTIFY](https://github.com/TrustBound/dream_postgres/blob/3.0.0/docs/guides/listen-notify.md): get the notifications of a channel
- [Tracing](https://github.com/TrustBound/dream_postgres/blob/3.0.0/docs/guides/tracing.md): OpenTelemetry spans of each query
- [Interceptors](https://github.com/TrustBound/dream_postgres/blob/3.0.0/docs/guides/interceptors.md): change, log or answer each query
- [Recorded queries](https://github.com/TrustBound/dream_postgres/blob/3.0.0/docs/guides/recorded-queries.md): record the queries of a test once, and play them back with no database
- [Boot check](https://github.com/TrustBound/dream_postgres/blob/3.0.0/docs/guides/boot-check.md): check every query against the database when the app starts
- [Upgrading to 3.0.0](https://github.com/TrustBound/dream_postgres/blob/3.0.0/docs/guides/upgrading-to-3.md): move from the Pog-based 2.x to the new client

## API Reference

The full API reference is on [HexDocs](https://hexdocs.pm/dream_postgres). The guides show each function where a task needs it.

## Design Principles

dream_postgres follows Dream's [design principles](https://github.com/TrustBound/dream/blob/release/3.0.0/docs/reference/design-principles.md) and [contributing guide](https://github.com/TrustBound/dream/blob/release/3.0.0/docs/contributing/contributing.md).

## About Dream

This package was first built for the [Dream](https://github.com/TrustBound/dream) web toolkit. It is standalone, and you can use it in any Gleam project. It follows Dream's design principles and is maintained as part of the Dream ecosystem.

## Contributing

See the [Contributing Guide](https://github.com/TrustBound/dream_postgres/blob/3.0.0/CONTRIBUTING.md).

## License

MIT, see [LICENSE.md](https://github.com/TrustBound/dream_postgres/blob/3.0.0/LICENSE.md)

---

<div align="center">
  <sub>Built in Gleam, on the BEAM, by the <a href="https://github.com/trustbound/dream">Dream Team</a> ❤️</sub>
</div>
