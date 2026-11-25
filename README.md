<div align="center">
  <img src="https://raw.githubusercontent.com/TrustBound/dream/main/ricky_and_lucy.png" alt="Ricky Moony and Lucy, a moon shaped mascot for Dream with the star shaped mascot for Gleam, each with cute cartoon eyes and a smile" width="200">

<b>PostgreSQL utilities for Gleam with type-safe query helpers</b>

</div>

<br />

<div align="center">
  <a href="https://hex.pm/packages/dream_postgres"><img src="https://img.shields.io/hexpm/v/dream_postgres" alt="Hex Package"></a>
  <a href="https://github.com/TrustBound/dream_postgres/releases"><img src="https://img.shields.io/github/v/release/TrustBound/dream_postgres?label=Release" alt="Latest Release"></a>
  <a href="https://hexdocs.pm/dream_postgres"><img src="https://img.shields.io/badge/hex-docs-lightgreen.svg" alt="HexDocs"></a>
  <a href="https://github.com/TrustBound/dream_postgres/actions/workflows/ci.yml?query=branch%3Amain"><img src="https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/TrustBound/dream_postgres/badges/coverage.json" alt="Coverage"></a>
  <a href="https://github.com/TrustBound/dream_postgres/blob/main/LICENSE.md"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License"></a>
  <a href="https://gleam.run"><img src="https://img.shields.io/badge/gleam-%E2%9C%A8-ffaff3" alt="Gleam"></a>
</div>

<br />

# dream_postgres

A standalone module with clean interfaces for PostgreSQL operations that use `dream_postgres_client`, a fork of [Pog](https://hex.pm/packages/pog). Import it as `import dream_postgres_client`. It includes query result helpers and a builder pattern for connection management. It is built with the same quality standards as [Dream](https://github.com/TrustBound/dream), but it is completely independent. Use it in any Gleam project.

## Features

- ✅ Builder pattern for connection configuration
- ✅ Type-safe query result extraction
- ✅ Simplified error handling
- ✅ Connection pooling via `dream_postgres_client`
- ✅ The query functions, value functions and types that the code of the SQL generator calls, in `dream_postgres/client`
- ✅ Query recording: record the queries of a test once, then play them back with no database
- ✅ Zero dependencies on Dream or other frameworks

## Installation

```bash
gleam add dream_postgres
```

## Quick Start

### Connection Setup <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/readme_connection_setup.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a> <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/docs/guides/connecting.md#build-a-config-and-connect-"><img align="right" alt="Guide: Connecting to PostgreSQL in production" title="Guide: Connecting to PostgreSQL in production" src="https://img.shields.io/badge/%F0%9F%93%96_read-guide-blue.svg?style=flat-square"></a>

```gleam
import dream_postgres/client as postgres
import gleam/erlang/process
import gleam/otp/actor

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

## Recorded queries

`dream_postgres/recorder` records each query of a test, with its parameters and its result, to one JSON file. Later runs play the file back with no database. A query with no recording fails, and never reaches a database. `recorder.error` reads the `recorder.RecorderError` back from the query error, with the SQL, the parameters and the file. The modes are the values `recorder.Record`, `recorder.Playback` and `recorder.Passthrough`, as in the HTTP recorder of `dream_http_client`. `recorder.parse_mode` reads a mode from a text, such as an environment variable.

### Record a test once, then play it back <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/guide_recording_round_trip.gleam#L20-L31"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a> <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/docs/guides/recorded-queries.md#step-3-record-once-against-the-real-database"><img align="right" alt="Guide: Test database code with recorded queries" title="Guide: Test database code with recorded queries" src="https://img.shields.io/badge/%F0%9F%93%96_read-guide-blue.svg?style=flat-square"></a>

```gleam
pub fn run_recorded(
  mode: recorder.Mode,
  database_url: String,
  directory: String,
) -> Result(User, String) {
  use recording <- result.try(start_recorder(mode, directory, "create_and_find"))
  use db <- result.try(connect(recording, database_url))
  let user = create_and_find(db) |> result.map_error(string.inspect)
  // In record mode, each query was on disk when it returned
  use Nil <- result.try(recorder.stop(recording))
  user
}
```

## Generated SQL code

[dream_sql_generator](https://hexdocs.pm/dream_sql_generator), a fork of Squirrel, writes a Gleam function for each `.sql` file. `dream_postgres/client` has every function and type that the generated code calls, such as `query`, `parameter`, `returning`, `execute`, `int`, `text` and `timestamp_decoder`. Set `client_module` in `gleam.toml`, and the generated module starts with `import dream_postgres/client as pog`:

### Point the SQL generator at dream_postgres/client <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/fixtures/generated/gleam.toml"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a> <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/docs/guides/queries.md#point-the-sql-generator-at-dream_postgresclient-"><img align="right" alt="Guide: Running queries and handling their results" title="Guide: Running queries and handling their results" src="https://img.shields.io/badge/%F0%9F%93%96_read-guide-blue.svg?style=flat-square"></a>

```toml
[dev-dependencies]
dream_sql_generator = ">= 1.0.0 and < 2.0.0"

[tools.dream_sql_generator]
client_module = "dream_postgres/client"
```

## Guides

- [Getting started](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/getting-started.md): connect from `DATABASE_URL`, stop at startup when the URL or the database is wrong, run a first query and test it
- [Connecting to PostgreSQL in production](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/connecting.md): SSL, pool size, IPv6, a supervised pool, the URL format and a clear message for each URL error
- [Running queries and handling their results](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/queries.md): use the code of the SQL generator, turn query results and their errors into responses, tell a duplicate apart from a failure, and test it without a database
- [Test database code with recorded queries](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/recorded-queries.md): record the queries of a test once against PostgreSQL, play them back with no database, read a query with no recording, hide a secret and record again after a query changes

## API Reference

The full API reference is on [HexDocs](https://hexdocs.pm/dream_postgres). The guides show each function where a task needs it.

## Design Principles

dream_postgres follows Dream's [design principles](https://github.com/TrustBound/dream/blob/release/3.0.0/docs/reference/design-principles.md) and [contributing guide](https://github.com/TrustBound/dream/blob/release/3.0.0/docs/contributing/contributing.md).

## About Dream

This module was originally built for the [Dream](https://github.com/TrustBound/dream) web toolkit, but it's completely standalone and can be used in any Gleam project. It follows Dream's design principles and will be maintained as part of the Dream ecosystem.

## License

MIT — see [LICENSE.md](https://github.com/TrustBound/dream_postgres/blob/main/LICENSE.md)

---

<div align="center">
  <sub>Built in Gleam, on the BEAM, by the <a href="https://github.com/trustbound/dream">Dream Team</a> ❤️</sub>
</div>
