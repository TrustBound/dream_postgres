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

A standalone module with clean interfaces for PostgreSQL operations that use [Pog](https://hex.pm/packages/pog). It includes query result helpers and a builder pattern for connection management. It is built with the same quality standards as [Dream](https://github.com/TrustBound/dream), but it is completely independent. Use it in any Gleam project.

## Features

- ✅ Builder pattern for connection configuration
- ✅ Type-safe query result extraction
- ✅ Simplified error handling
- ✅ Connection pooling via Pog
- ✅ Zero dependencies on Dream or other frameworks

## Installation

```bash
gleam add dream_postgres
```

## Quick Start

### Connection Setup <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/test/snippets/readme_connection_setup.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a> <a href="https://github.com/TrustBound/dream_postgres/blob/2.0.0/docs/guides/getting-started.md#connection-setup-"><img align="right" alt="Guide" src="https://img.shields.io/badge/%F0%9F%93%96_read-guide-blue.svg?style=flat-square"></a>

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

## Guides

- [Getting started](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/getting-started.md): install the package and connect to a database
- [Connection builder](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/connection-builder.md): configure a connection step by step and start the pool
- [Connection URLs](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/connection-urls.md): read a PostgreSQL URL into a config or start a pool from it, the URL format and the URL errors
- [Running queries](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/running-queries.md): run queries with Pog or Squirrel on a connection
- [Query results and errors](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/query-results.md): turn query results into values and handle each error

## API Reference

The full API reference is on [HexDocs](https://hexdocs.pm/dream_postgres). Each guide lists the functions it uses.

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
