# Upgrading to 3.0

dream_postgres 3.0 is a new client. Version 2.x wrapped `dream_postgres_client`, a fork of Pog. Version 3.0 has its own driver, and one module for each task: `dream_postgres/config`, `dream_postgres/pool`, `dream_postgres/query`, `dream_postgres/row`, `dream_postgres/transaction` and more. This guide puts each 2.x function next to its 3.0 form. The 2.x code blocks are the files at the release tag 2.0.0. The 3.0 code blocks are files that the tests of this package run against PostgreSQL.

## Table of Contents

- [What changed](#what-changed)
- [Each function and its new form](#each-function-and-its-new-form)
- [Start a pool](#start-a-pool)
- [Run a query](#run-a-query)
- [Turn a result into a response](#turn-a-result-into-a-response)
- [Run a pool under a supervisor](#run-a-pool-under-a-supervisor)
- [Recorded queries](#recorded-queries)
- [What 3.0 does not have](#what-30-does-not-have)
- [Where to go next](#where-to-go-next)

## What changed

- The package no longer depends on `dream_postgres_client` or Pog. Remove `dream_postgres_client` from `gleam.toml`, and import the modules of `dream_postgres`, such as `dream_postgres/pool` and `dream_postgres/query`.
- A query reads its rows with a row reader and codecs, not with a `gleam/dynamic/decode` decoder. Before each run, the codecs are checked against the types of the parameters and the columns.
- Every failure is a `dream_errors.Error(PostgresError)`. Its kind, such as `NotFound` or `Conflict`, tells what to do. The cause holds every detail.
- The default TLS changed. 3.0 requires TLS, and checks the certificate of the server against the authorities of the operating system, and the host name. For a server with no TLS, such as a local test server, set `tls(TlsOff)`. The [connecting guide](connecting.md) shows each TLS setting.

## Each function and its new form

| 2.x | 3.0 |
|---|---|
| `client.new(pool_name)` | `default_config()`. A pool needs a name only under a supervisor: `supervised(config, name:)`. |
| `client.host`, `port`, `database`, `user`, `password`, `pool_size` | the same names in `dream_postgres/config` |
| `client.connect(config)` | `start(config)` |
| `dream_postgres_client.supervised(config)` | `supervised(config, name:)` |
| `dream_postgres_client.named_connection(name)` | `named_connection(name)` |
| `client.from_url(url)`, `client.parse_config(name, url)` | none: see [What 3.0 does not have](#what-30-does-not-have) |
| `client.check(connection)` | none. To check the queries against the schema at boot, use `verify`. |
| `dream_postgres_client.query(sql)` | `query(sql)` |
| `dream_postgres_client.parameter(dream_postgres_client.int(x))` | `parameter(codec.int, x)` |
| `dream_postgres_client.returning(decoder)` | a row reader: `column`, `column_at`, `column_named`, `row`, `single` |
| `dream_postgres_client.execute(connection)` and `query.first_row` | `one(reader, connection)`, or `maybe_one` for zero or one row |
| `dream_postgres_client.execute(connection)` and `query.all_rows` | `all(reader, connection)` |
| `dream_postgres_client.execute(connection)` for a command | `affected(connection)`, which gives the row count |
| `query.NotFound`, `query.DatabaseError` | the kinds of `dream_errors.Error`, such as `NotFound`, `Conflict` and `Unavailable` |
| `dream_postgres_client.ConstraintViolated(constraint:, ..)` | the kind `Conflict`, and `error.constraint_name(error)` |
| `dream_postgres_client.transaction(connection, callback)` | `transaction(connection, database:, rollback_also_failed:)`, then `run(plan, callback)`, or a pipe of `step`, `check` and `commit`. The error is a `dream_errors.Error(cause)`, and a failed rollback keeps both errors. See the [transactions guide](transactions.md). |
| `recorder.new()`, `directory`, `name` | `recorder.new(file: path)`, with the whole path |
| `recorder.mode`, `recorder.start` | the same names in `dream_postgres/recorder` |
| `recorder.connect(recorder, config)` | `config \|> record(recorder) \|> start` |
| `recorder.stop(recorder)`, which gave `Result(Nil, String)` | `stop(connection)`, which also stops the recorder |
| `recorder.Record`, `recorder.Playback`, `recorder.Passthrough` | the same, and `recorder.RecordMissing` |
| `recorder.parse_mode` | none: the test reads the mode from its own config |
| `recorder.key` | `recorder.match_on`, with `match.sql_and_parameters`, `match.sql_only` or a function of the app |
| `query_transformer`, `result_transformer` | `recorder.intercept`, such as `normalize.generated_uuids` and `normalize.timestamps_near_now` |
| `recorder.error`, `recorder.describe_error` | the reasons `RequestNotRecorded`, `RequestNotMatched` and `RecorderStopped` of `dream_postgres/error`, and `error.describe` |

## Start a pool

### Start a pool in 2.x <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/readme_connection_setup.gleam#L9-L23"><img align="right" alt="Code at 2.0.0" src="https://img.shields.io/badge/%F0%9F%93%9C_code_at-2.0.0-lightgrey.svg?style=flat-square"></a>

```gleam
pub fn database_config() -> postgres.Config {
  let pool_name = process.new_name("db_pool")
  postgres.new(pool_name)
  |> postgres.host("localhost")
  |> postgres.port(5432)
  |> postgres.database("myapp")
  |> postgres.user("postgres")
  |> postgres.password("secret")
  |> postgres.pool_size(15)
}

pub fn connect_database() -> Result(postgres.Connection, actor.StartError) {
  database_config()
  |> postgres.connect()
}
```

### Start a pool in 3.0 <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/upgrade_connect_database.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/config.{
  database, default_config, host, password, pool_size, port, user,
}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection, start}

/// The pool of the 2.x README, in the 3.0 form. It has no pool name: a
/// name is only for a pool under a supervisor.
pub fn connect_database() -> Result(Connection, Error(PostgresError)) {
  default_config()
  |> host("localhost")
  |> port(5432)
  |> database("myapp")
  |> user("postgres")
  |> password("secret")
  |> pool_size(15)
  |> start
}
```

`start` gives `Result(Connection, Error(PostgresError))`. A config that is not valid is an error of `start`, with the reason `InvalidConfig`. The connections connect in the background, so a server that does not answer shows as an error of the first query.

## Run a query

In 2.x, a query decoded its rows with a decoder, and `execute` gave all rows:

### Find a user in 2.x <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/guide_queries_sql.gleam#L10-L32"><img align="right" alt="Code at 2.0.0" src="https://img.shields.io/badge/%F0%9F%93%9C_code_at-2.0.0-lightgrey.svg?style=flat-square"></a>

```gleam
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
```

In 3.0, a row reader reads each column with a codec, and `one` gives the one row:

### Find a user in 3.0 <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/upgrade_find_user.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/codecs.{int, text}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{named, one, parameter, query}
import dream_postgres/row.{type Row, column, row}

pub type FindUserRow {
  FindUserRow(id: Int, name: String, email: String)
}

fn find_user_row() -> Row(FindUserRow) {
  use id <- column(int)
  use name <- column(text)
  use email <- column(text)
  row(FindUserRow(id:, name:, email:))
}

pub fn find_user(
  connection: Connection,
  id: Int,
) -> Result(FindUserRow, Error(PostgresError)) {
  "SELECT id, name, email FROM users WHERE id = $1"
  |> query
  |> named("user.find")
  |> parameter(int, id)
  |> one(find_user_row(), connection)
}
```

`named` gives the query a name. The errors, the boot check and the spans show that name.

## Turn a result into a response

In 2.x, `query.first_row` turned the result into `NotFound` or `DatabaseError`:

### Answer with one user in 2.x <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/guide_queries_show_user.gleam#L19-L34"><img align="right" alt="Code at 2.0.0" src="https://img.shields.io/badge/%F0%9F%93%9C_code_at-2.0.0-lightgrey.svg?style=flat-square"></a>

```gleam
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

In 3.0, `one` gives `NotFound` itself. Match on the kind of the error:

### Answer with one user in 3.0 <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/upgrade_show_user.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error, NotFound}
import dream_postgres/error.{type PostgresError}
import snippets/upgrade_find_user.{type FindUserRow}

pub type Response {
  Response(status: Int, body: String)
}

pub fn show_user_response(
  result: Result(FindUserRow, Error(PostgresError)),
) -> Response {
  case result {
    Ok(user) -> Response(200, user.name)
    Error(NotFound(..)) -> Response(404, "User not found")
    Error(_other) -> Response(500, "Internal server error")
  }
}
```

In 2.x, a duplicate was a `ConstraintViolated` error with the constraint name:

### Answer 409 for a duplicate email in 2.x <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/guide_queries_create_user.gleam#L21-L34"><img align="right" alt="Code at 2.0.0" src="https://img.shields.io/badge/%F0%9F%93%9C_code_at-2.0.0-lightgrey.svg?style=flat-square"></a>

```gleam
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
```

In 3.0, a unique violation has the kind `Conflict`. `error.constraint_name` gives the constraint name when two unique constraints need two answers.

### Answer 409 for a duplicate email in 3.0 <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/upgrade_create_user.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error, Conflict}
import dream_postgres/codecs.{int, text}
import dream_postgres/error.{type PostgresError}
import dream_postgres/pool.{type Connection}
import dream_postgres/query.{named, one, parameter, query}
import dream_postgres/row.{single}
import gleam/int
import snippets/upgrade_show_user.{type Response, Response}

pub fn create_user(
  connection: Connection,
  name: String,
  email: String,
) -> Result(Int, Error(PostgresError)) {
  "INSERT INTO users (name, email) VALUES ($1, $2) RETURNING id"
  |> query
  |> named("user.create")
  |> parameter(text, name)
  |> parameter(text, email)
  |> one(single(int), connection)
}

pub fn created_response(result: Result(Int, Error(PostgresError))) -> Response {
  case result {
    Ok(id) -> Response(201, "Created user " <> int.to_string(id))
    Error(Conflict(..)) -> Response(409, "That email is already taken")
    Error(_other) -> Response(500, "Internal server error")
  }
}
```

## Run a pool under a supervisor

### A supervised pool in 2.x <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/guide_connecting_supervised.gleam#L13-L30"><img align="right" alt="Code at 2.0.0" src="https://img.shields.io/badge/%F0%9F%93%9C_code_at-2.0.0-lightgrey.svg?style=flat-square"></a>

```gleam
pub fn start_supervised(
  database_url: String,
) -> Result(postgres.Connection, String) {
  let pool_name = process.new_name("app_database")
  use config <- result.try(
    postgres.parse_config(pool_name, database_url)
    |> result.map_error(explain),
  )
  use _supervisor <- result.try(
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(
      dream_postgres_client.supervised(postgres.pool_size(config, 15)),
    )
    |> supervisor.start()
    |> result.replace_error("The supervisor did not start"),
  )
  Ok(dream_postgres_client.named_connection(pool_name))
}
```

### A supervised pool in 3.0 <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/supervised_pool.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/codecs.{text}
import dream_postgres/config.{type Config}
import dream_postgres/error.{type PostgresError, describe}
import dream_postgres/pool.{type PoolName, named_connection, supervised}
import dream_postgres/query.{one, query}
import dream_postgres/row.{single}
import gleam/otp/actor
import gleam/otp/static_supervisor.{type Supervisor}
import gleam/result

/// Starts the app's supervisor with the pool under it. The pool runs
/// under `pool_name`, also after a restart.
pub fn start_supervisor(
  config: Config,
  pool_name: PoolName,
) -> Result(actor.Started(Supervisor), String) {
  use pool_child <- result.try(
    supervised(config, name: pool_name)
    |> result.map_error(describe),
  )
  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(pool_child)
  |> static_supervisor.start
  |> result.replace_error("the supervisor did not start")
}

/// Any process can reach the pool by its name.
pub fn current_database(
  pool_name: PoolName,
) -> Result(String, Error(PostgresError)) {
  "SELECT current_database()"
  |> query
  |> one(single(text), named_connection(pool_name))
}
```

After the supervisor starts, `named_connection(pool_name)` gives the connection of the pool, as `current_database` shows. It stays valid when the supervisor starts the pool again.

## Recorded queries

### Start a recorder and connect in 2.x <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/guide_recording_setup.gleam#L13-L36"><img align="right" alt="Code at 2.0.0" src="https://img.shields.io/badge/%F0%9F%93%9C_code_at-2.0.0-lightgrey.svg?style=flat-square"></a>

```gleam
pub fn start_recorder(
  mode: recorder.Mode,
  directory: String,
  test_name: String,
) -> Result(recorder.Recorder, String) {
  recorder.new()
  |> recorder.directory(directory)
  |> recorder.name(test_name)
  |> recorder.mode(mode)
  |> recorder.start()
}

/// In playback mode, nothing connects to `database_url`.
pub fn connect(
  recording: recorder.Recorder,
  database_url: String,
) -> Result(dream_postgres_client.Connection, String) {
  use config <- result.try(
    postgres.parse_config(process.new_name("test_database"), database_url)
    |> result.map_error(string.inspect),
  )
  recorder.connect(recording, config)
  |> result.map_error(string.inspect)
}
```

### Start a recorder in 3.0 <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/start_api_key_recorder.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{type Error}
import dream_postgres/error.{type PostgresError}
import dream_postgres/recorder.{
  type Mode, type Recorder, intercept, match_on, mode, new, start,
}
import dream_postgres/recorder/match.{sql_and_parameters}
import dream_postgres/recorder/normalize.{generated_uuids, timestamps_near_now}

/// Starts the recorder of the test that creates an API key. The test
/// gives the mode, which it reads from its own config.
pub fn start_api_key_recorder(
  recorder_mode: Mode,
) -> Result(Recorder, Error(PostgresError)) {
  new(file: "test/recordings/api_key_create.json")
  |> mode(recorder_mode)
  |> match_on(sql_and_parameters)
  |> intercept(generated_uuids(keep: []))
  |> intercept(timestamps_near_now(window_days: 400))
  |> start
}
```

`config.record` attaches the recorder to the 3.0 `Config`, and `pool.start` makes the connection. In playback mode it connects to nothing. The recording file of 2.x has another format, so record each test again in 3.0. The [recorded queries guide](recorded-queries.md) shows the new file.

## What 3.0 does not have

These 2.x functions have no 3.0 form:

- `client.from_url` and `client.parse_config`: 3.0 reads no `DATABASE_URL`. Set each part of the config with its own function.
- `client.check`: 3.0 has no call that only checks that the database answers. `verify` checks the queries against the schema at boot.
- `recorder.parse_mode`: the test reads the mode from its own config, and gives the `recorder.Mode` value to `recorder.mode`.

## Where to go next

- [Getting started](getting-started.md): a first program with 3.0
- [Queries](queries.md): readers, codecs and the error of each failure
- [Recorded queries](recorded-queries.md): the recorder of 3.0
