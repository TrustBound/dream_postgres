# Getting started with dream_postgres

This guide takes you from an empty project to a program that starts a pool, makes its tables, stores a user and reads users back. Each code block is a file that the tests of this package run against PostgreSQL.

## Table of Contents

- [Before you start](#before-you-start)
- [Step 1: Start a pool](#step-1-start-a-pool)
- [Step 2: Make the tables](#step-2-make-the-tables)
- [Step 3: Read a row into a value](#step-3-read-a-row-into-a-value)
- [Step 4: Store a user](#step-4-store-a-user)
- [Step 5: Read users back](#step-5-read-users-back)
- [Step 6: Change rows](#step-6-change-rows)
- [Step 7: Stop the pool](#step-7-stop-the-pool)
- [Where to go next](#where-to-go-next)

## Before you start

Add the package, and `dream_errors` for its error type:

```sh
gleam add dream_postgres dream_errors
```

dream_postgres runs on the Erlang target. It has no dependency on Dream or on a web framework, so it works in any Gleam project.

You also need a PostgreSQL server. The tests of this package run against PostgreSQL 16, 17, 18 and 19.

## Step 1: Start a pool

A pool is a set of connections to one database. Build its settings with `default_config` and one function for each setting, then call `start_pool`:

### Start a pool <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/connect.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/config.{
  TlsOff, database, default_config, host, password, pool_size, port, tls, user,
}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection, start_pool}

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
  |> start_pool
}
```

`start_pool` checks the config, starts the pool and links it to the calling process. The connections connect in the background. So `start_pool` returns before the server answers, and a server that does not answer shows as the error of the first query.

The default config requires TLS. It checks the certificate of the server against the authorities of the operating system, and it checks that the certificate names the host. A local test server has no certificate, so this example turns TLS off with `tls(TlsOff)`. In production, keep TLS on. The [connecting guide](connecting.md#tls) shows each TLS setting.

## Step 2: Make the tables

`run_sql` runs SQL with the simple query protocol. It can run several statements at once, and it reads no rows:

### Make the tables <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/create_tables.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{run_sql}

/// Makes the tables of the examples: users, and the accounts of users.
pub fn create_tables(
  connection: Connection,
) -> Result(Nil, Error(PostgresError)) {
  "
  CREATE TABLE users (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email text NOT NULL UNIQUE,
    name text NOT NULL
  );
  CREATE TABLE accounts (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id bigint NOT NULL REFERENCES users (id),
    balance bigint NOT NULL DEFAULT 0
  );
  "
  |> run_sql(connection)
}
```

The unique email of the users table gets the constraint name `users_email_key`. The [queries guide](queries.md#tell-a-taken-email-apart-from-other-failures) uses that name.

## Step 3: Read a row into a value

A row reader says how to read one row of a result. `column` reads the next column with a codec, and `row` gives the value of the row:

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

A codec connects a Gleam type and a PostgreSQL type. `codec.int` reads `int2`, `int4`, `int8` and `oid` as `Int`. `codec.text` reads `text`, `varchar` and the other text types as `String`. The [codecs guide](codecs.md) lists each codec.

## Step 4: Store a user

`query` makes a query of the SQL. Each `parameter` adds the next parameter: the first call gives `$1`, the next `$2`. `one` runs the query and reads exactly one row:

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

The server prepares each statement and describes its parameters and columns. Before each run, dream_postgres checks the codec of each parameter against the type of the parameter, and the reader against the number and the types of the columns. A mismatch is an error that names the parameter or the column, and the query does not run.

## Step 5: Read users back

`maybe_one` reads at most one row, and gives `None` when there is no row. `named` gives the query a name that errors and logs show with the SQL:

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

`all` reads every row into a list:

### List every user <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/list_users.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{all, query}
import snippets/user_row.{type User, user_row}

/// Gives every user, in the order of their ids.
pub fn list_users(
  connection: Connection,
) -> Result(List(User), Error(PostgresError)) {
  "SELECT id, email, name FROM users ORDER BY id"
  |> query
  |> all(user_row(), connection)
}
```

## Step 6: Change rows

`affected` runs a command and gives the row count of its command tag, for example 1 for `UPDATE 1`:

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

## Step 7: Stop the pool

`pool.stop_pool(connection)` stops the pool and closes its connections. The calls that hold a connection get at most 5 seconds to finish. A pool that runs for the whole life of an app goes under the app's supervisor instead. The [connecting guide](connecting.md#run-the-pool-under-a-supervisor) shows how.

## Where to go next

- [Connecting to PostgreSQL](connecting.md): TLS, a supervised pool, reconnects, PgBouncer, notices and pool events
- [Pool tuning](pool-tuning.md): the pool size and the timeouts
- [Queries](queries.md): row readers, the functions that run a query, and errors
- [Transactions](transactions.md): steps, checks, isolation, savepoints and rollbacks
- [Codecs](codecs.md): each PostgreSQL type and its Gleam type
