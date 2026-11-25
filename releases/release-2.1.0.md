# dream_postgres 2.1.0 Release Notes

**Release Date:** Unreleased

This release lets generated code use `dream_postgres/client` alone. The module now has the query functions, the value functions and the decoders of `dream_postgres_client`, so code from `dream_sql_generator` compiles with `client_module = "dream_postgres/client"`. It also adds three helpers for the model modules that dream_model generates: the name of a violated constraint, a check of a `-- not null:` promise, and a schema fingerprint that an app checks at startup.

It is a minor version. No existing function changed.

## Key Highlights

- **The query API in `dream_postgres/client`**: `query`, `parameter`, `returning`, `execute`, `transaction`, the value functions and the decoders
- **`violated_constraint`**: get the name of the constraint that a query violated, for example `users_email_key`
- **`promised_not_null`**: check on each row that a column that a SQL file promised is never NULL is not NULL
- **`check_schema`**: stop at startup when the schema changed after dream_model generated the modules

## What's New

### The query API in `dream_postgres/client`

`dream_postgres/client` has `query`, `parameter`, `returning`, `timeout`, `execute`, `transaction`, `null`, `bool`, `int`, `float`, `text`, `bytea`, `array`, `nullable`, `timestamp`, `calendar_date`, `calendar_time_of_day` and the decoders `timestamp_decoder`, `calendar_date_decoder`, `calendar_time_of_day_decoder` and `numeric_decoder`. Each function calls the function of the same name in `dream_postgres_client`. The new type aliases are `Query(row)` and `TransactionError(error)`.

### `violated_constraint`

`violated_constraint(error: QueryError) -> Result(String, Nil)` gives the name of the constraint that a query violated: a unique constraint, a primary key, a unique index, a foreign key, a check constraint or an exclusion constraint. Every other error gives `Error(Nil)`, also a `NOT NULL` violation.

The function does not tell the kinds of constraints apart. To find a duplicate, compare the name with the names of constraints that you know are unique. dream_model makes sure at generation time that each `-- unique <name>` hint names a unique constraint, a primary key or a unique index of the table, and `check_schema` finds a schema that changed after that.

#### Tell the user that the email is taken <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_violated_constraint.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/client as postgres

pub fn sign_up_error_message(error: postgres.QueryError) -> String {
  case postgres.violated_constraint(error) {
    Ok("users_email_key") -> "Email already taken"
    Ok(constraint) -> "The sign-up broke the constraint " <> constraint
    Error(Nil) -> "The sign-up failed"
  }
}
```

### `promised_not_null`

`promised_not_null(decoder, file, column)` wraps a column decoder. A value that is not NULL goes to `decoder`. A NULL fails the row with a `decode.DecodeError` at the path of the column, with `found: "NULL"` and the message `the SQL file order_total.sql promised the column total is never NULL, and PostgreSQL returned NULL`.

### `broken_promise`

`broken_promise(error)` gives the message of a broken promise from the error of `execute`: `Ok(message)` when a `promised_not_null` column was NULL, and `Error(Nil)` for every other error. Code that imports only `dream_postgres/client` can show the message without a match on `UnexpectedResultType`.

#### Show the broken promise of a query <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_broken_promise.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/client as postgres

pub fn error_message(error: postgres.QueryError) -> String {
  case postgres.broken_promise(error) {
    Ok(message) -> message
    Error(Nil) -> "The query failed"
  }
}
```

### `timestamp_with_time_zone_decoder`

`timestamp_with_time_zone_decoder()` reads a `timestamptz` column as a `Timestamp`. `timestamp_decoder` reads only a `timestamp` column: `dream_postgres_client` gives a `timestamptz` value as a date and a time of day in UTC, and this decoder reads that form. `timestamp` sends a `Timestamp` to either kind of column.

#### Read a timestamptz <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_timestamp_with_time_zone_decoder.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/client as postgres
import gleam/dynamic/decode

pub fn signed_up_at(
  connection: postgres.Connection,
) -> Result(postgres.Returned(postgres.Timestamp), postgres.QueryError) {
  "SELECT timestamptz '2024-01-02 03:04:05.25+00'"
  |> postgres.query
  |> postgres.returning(decode.at(
    [0],
    postgres.timestamp_with_time_zone_decoder(),
  ))
  |> postgres.execute(connection)
}
```

### `Timestamp`, `Date` and `TimeOfDay`

`dream_postgres/client` has the type aliases `Timestamp`, `Date` and `TimeOfDay`. They are the types of `gleam/time/timestamp` and `gleam/time/calendar`, so code that names them through `dream_postgres/client` needs no `gleam_time` import.

### The schema fingerprint

The types of a generated module are true only for the schema that dream_model generated it from. Each generated module has a `SchemaFingerprint(module:, tables:, hash:)`. Call `check_schema` right after the pool starts:

#### Check the generated modules at startup <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_check_schema.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/client as postgres
import gleam/result

pub fn check_models(
  connection: postgres.Connection,
  models: List(postgres.SchemaFingerprint),
) -> Result(Nil, String) {
  postgres.check_schema(connection, models)
  |> result.map_error(postgres.format_schema_check_error)
}
```

`schema_fingerprint(connection, tables)` runs `schema_fingerprint_sql` and gives the SHA-256 hash of its text, as 64 lowercase hexadecimal digits. The text holds these facts of each table, and of each child table and partition: the kind of the relation, each column with its type, `NOT NULL`, default, identity and generated kind, each constraint with its kind, name, validated flag and definition, `BEFORE` row triggers, row level security and each policy with its `USING` and `WITH CHECK`, the domains of the columns with their `NOT NULL` and constraints, and the labels of the enums of the columns. A missing table gives a line of its own, not an error.

The text holds no OIDs and no column numbers, and the `search_path` of the connection does not change it. Two databases that the same migrations made give the same fingerprint. PostgreSQL 17 and 18 keep more `NOT NULL` facts as constraints, so the fingerprint of one schema is different on PostgreSQL 16, on 17, and on 18 and later. Generate the modules against the major version of PostgreSQL that the app uses.

`check_schema` gives `SchemaChanged(mismatches)` with each module that differs, or `SchemaUnreadable(module, error)` when a query fails. `format_schema_check_error` gives a message that names each module and its tables, and tells you to regenerate them.

## Testing

- 474 tests run, 0 failed, 100.0% line coverage (620 of 620 lines). The test times add up to about 122 seconds. 4 tests run at a time, and the 20 SSL tests run one at a time (Apple M1 Max, 10 cores, 64 GB, macOS 26.5.1, OTP 29, Gleam 1.19.2)
- The 63 tests of the new helpers passed on PostgreSQL 16, 17, 18 and 19, with `DREAM_POSTGRES_TEST_URL` set to each server
- The fingerprint tests show that the fingerprint does not change when the same DDL makes the tables again with new OIDs, when the columns are in another order, or when the `search_path` is different. Each kind of schema change changes it: a dropped `NOT NULL`, a new `CHECK`, a renamed constraint, a validated constraint, a new type, a new `BEFORE` row trigger, row level security, a changed policy, a new partition or child table, a changed domain and a new enum label

## Upgrading

Change the version requirement in `gleam.toml` to `dream_postgres = ">= 2.1.0 and < 3.0.0"`.

### Migration Guide

No code changes are necessary. The package now lists the OTP application `crypto` in `extra_applications`, for the SHA-256 hash.

## Documentation

- [dream_postgres](https://hexdocs.pm/dream_postgres) - v2.1.0
- [README](https://github.com/TrustBound/dream_postgres/blob/main/README.md)
- [Running queries and handling their results](https://github.com/TrustBound/dream_postgres/blob/main/docs/guides/queries.md)
- [Changelog](https://github.com/TrustBound/dream_postgres/blob/main/CHANGELOG.md)

## Community

- [Discussions](https://github.com/TrustBound/dream/discussions)
- [Report Issues](https://github.com/TrustBound/dream_postgres/issues)
- [Contributing Guide](https://github.com/TrustBound/dream_postgres/blob/main/CONTRIBUTING.md)
