# dream_postgres 2.1.0 Release Notes

**Release Date:** Unreleased

This release lets generated code use `dream_postgres/client` alone. The module now has the query functions, the value functions and the decoders of `dream_postgres_client`, so code from `dream_sql_generator` compiles with `client_module = "dream_postgres/client"`. It also adds the error type of the model modules of dream_model, `ModelError` with the alias `ModelQueryError`, and the helpers that these modules call: `more_than_one_row`, `violated_constraint`, `promised_not_null` and `broken_promise`, `finite_timestamp`, `finite_date` and `infinite_value`, `timestamp_with_time_zone_decoder`, the type aliases `Timestamp`, `Date` and `TimeOfDay`, the exact `numeric` functions `numeric_as_text`, `numeric_text_decoder` and `numeric_text`, and the schema fingerprint (`SchemaFingerprint`, `schema_fingerprint`, `schema_fingerprint_sql` and `check_schema`) that an app checks at startup.

It is a minor version. No existing function changed.

## Key Highlights

- **The query API in `dream_postgres/client`**: `query`, `parameter`, `returning`, `execute`, `transaction`, the value functions and the decoders
- **`ModelError`**: the data error of a generated model function, `NotFound`, `Conflict(constraint)` or `QueryFailed(message, cause)`, with no HTTP status
- **`violated_constraint`**: get the name of the constraint that a query violated, for example `users_email_key`
- **`promised_not_null`**: check on each row that a column that a SQL file promised is never NULL is not NULL
- **Exact `numeric`**: read and write a `numeric` as the exact text of the number, with no loss of digits
- **`check_schema`**: stop at startup when the schema changed after dream_model generated the modules

## What's New

### The query API in `dream_postgres/client`

`dream_postgres/client` has `query`, `parameter`, `returning`, `timeout`, `execute`, `transaction`, `null`, `bool`, `int`, `float`, `text`, `bytea`, `array`, `nullable`, `timestamp`, `calendar_date`, `calendar_time_of_day` and the decoders `timestamp_decoder`, `calendar_date_decoder`, `calendar_time_of_day_decoder` and `numeric_decoder`. Each function calls the function of the same name in `dream_postgres_client`. The new type aliases are `Query(row)` and `TransactionError(error)`.

### `ModelError`

The functions that dream_model generates return `Result(T, ModelQueryError)`. `ModelQueryError` is the alias of `ModelError(QueryError)`. The error is data: it has no HTTP status and no text for a user, so the app maps it, for example in a controller. `ModelError(cause)` has three cases:

- `NotFound`: a `-- returns: one` function found no row.
- `Conflict(constraint)`: the statement violated a unique constraint that a `-- unique:` hint of the SQL file names.
- `QueryFailed(message, cause)`: every other failure. `message` names the model function, and `cause` is the original error of the database call.

#### Give each model error a status and a message <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_model_error.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/client as postgres

pub fn status_and_message(
  error: postgres.ModelError(postgres.QueryError),
) -> #(Int, String) {
  case error {
    postgres.NotFound -> #(404, "User not found")
    postgres.Conflict("users_email_key") -> #(409, "Email already taken")
    postgres.Conflict(constraint) -> #(409, "Conflict on " <> constraint)
    postgres.QueryFailed(message:, cause: _) -> #(500, message)
  }
}
```

#### Log the cause of a failed model call <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_model_query_error.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/client as postgres
import gleam/string

pub fn log_line(error: postgres.ModelQueryError) -> String {
  case error {
    postgres.QueryFailed(message:, cause:) ->
      message <> ": " <> string.inspect(cause)
    postgres.NotFound -> "not found"
    postgres.Conflict(constraint:) -> "conflict on " <> constraint
  }
}
```

`more_than_one_row(count)` makes the cause of a `QueryFailed` when a function that expects at most one row gets more: an `UnexpectedResultType` with `expected` `at most one row` and `found` the number of rows, for example `2 rows`.

#### Fail a lookup that found two rows <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_more_than_one_row.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/client as postgres

pub fn one_email(
  emails: List(String),
) -> Result(String, postgres.ModelQueryError) {
  case emails {
    [email] -> Ok(email)
    [] -> Error(postgres.NotFound)
    _ ->
      Error(postgres.QueryFailed(
        message: "user.email returned more than one row",
        cause: postgres.more_than_one_row(2),
      ))
  }
}
```

### `violated_constraint`

`violated_constraint(error: QueryError) -> Result(String, Nil)` gives the name of the constraint that a query violated: a unique constraint, a primary key, a unique index, a foreign key, a check constraint or an exclusion constraint. Every other error gives `Error(Nil)`, also a `NOT NULL` violation.

The function does not tell the kinds of constraints apart. To find a duplicate, compare the name with the names of constraints that you know are unique. dream_model makes sure at generation time that each name of a `-- unique:` hint names a unique constraint, a primary key or a unique index of the table, and `check_schema` finds a schema that changed after that.

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

### `finite_timestamp`, `finite_date` and `infinite_value`

A `timestamp`, `timestamptz` or `date` column can hold `'infinity'` and `'-infinity'`. A `Timestamp` or a `Date` cannot hold them. `finite_timestamp(decoder, column)` and `finite_date(decoder, column)` wrap a column decoder. An infinite value fails the row with a `decode.DecodeError` at the path of the column, with `found: "infinity"` or `found: "-infinity"` and the message `the column ends_at holds infinity, which the Gleam type Timestamp cannot hold`. Every other value goes to `decoder`.

#### Read a timestamp that can be infinity <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_finite_timestamp.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/client as postgres
import gleam/dynamic/decode

pub fn ends_at(
  connection: postgres.Connection,
  sql: String,
) -> Result(postgres.Returned(postgres.Timestamp), postgres.QueryError) {
  sql
  |> postgres.query
  |> postgres.returning(decode.at(
    [0],
    postgres.finite_timestamp(postgres.timestamp_decoder(), "ends_at"),
  ))
  |> postgres.execute(connection)
}
```

`infinite_value(error)` gives that message from the error of `execute`, and `Error(Nil)` for every other error. Generated model modules return it as the message of a `QueryFailed`, after the name of the model function.

#### Show the infinite value of a query <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_infinite_value.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/client as postgres

pub fn error_message(error: postgres.QueryError) -> String {
  case postgres.infinite_value(error) {
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

### Exact `numeric`

`numeric_decoder` reads a `numeric` column as a `Float`, and a `Float` can lose digits. `numeric_as_text(query)` makes each `numeric` value of the query the exact text of the number, the same text as `value::text` in PostgreSQL: the sign, all the digits of the scale with the trailing zeros (`"1.50"` for a `numeric(20,2)` of 1.5), and `"NaN"`, `"Infinity"` and `"-Infinity"`. `numeric_text_decoder()` decodes that text to a `String`. `numeric_text(value)` gives a `numeric` parameter as text, and PostgreSQL reads the text itself. A text that is not a number fails with the `PostgresqlError` of code `22P02` (`invalid_text_representation`). `numeric_decoder` does not change.

#### Add a cent to an exact amount <a href="https://github.com/TrustBound/dream_postgres/blob/2.1.0/test/snippets/client_numeric_text.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres/client as postgres
import gleam/dynamic/decode

pub fn add_one_cent(
  connection: postgres.Connection,
  amount: String,
) -> Result(postgres.Returned(String), postgres.QueryError) {
  "SELECT $1::numeric + 0.01"
  |> postgres.query
  |> postgres.parameter(postgres.numeric_text(amount))
  |> postgres.numeric_as_text
  |> postgres.returning(decode.at([0], postgres.numeric_text_decoder()))
  |> postgres.execute(connection)
}
```

`add_one_cent(connection, "12345678901234567.89")` gives `"12345678901234567.90"`. The values come from `dream_postgres_client` 1.1.0 and `dream_postgres_driver` 1.1.0.

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

`schema_fingerprint(connection, tables)` runs `schema_fingerprint_sql` and gives the SHA-256 hash of its text, as 64 lowercase hexadecimal digits. The text holds these facts of each table or view, and of each child table and partition: the kind of the relation, the view definition and its `check_option`, each column with its position, type, `NOT NULL`, default, identity and generated kind, and the expression of a generated column, each constraint with its kind, name, validated flag and definition, each index with its unique and valid flags and definition, each rule, row-level `BEFORE` and `INSTEAD OF` triggers, row level security and each policy with its roles, `USING` and `WITH CHECK`, and each type that a column uses: domains with their `NOT NULL` and constraints, enum labels, composite fields and range subtypes. A missing table gives a line of its own, not an error.

The position of a column is its place among the columns that are not dropped, in the order of `SELECT *`. The generated decoders read columns by position, so a change of the order changes the fingerprint. A dropped column changes the position of each column after it, and nothing else. The text holds no OIDs and no attribute numbers, so two databases that the same migrations made give the same fingerprint. The query pins `search_path`, `TimeZone`, `DateStyle`, `IntervalStyle`, `extra_float_digits`, `quote_all_identifiers`, `bytea_output`, `standard_conforming_strings` and `lc_monetary` while it reads the catalog, and then sets the earlier values back. So the settings of the connection do not change the text. PostgreSQL 17 and 18 keep more `NOT NULL` facts as constraints, so the fingerprint of one schema is different on PostgreSQL 16, on 17, and on 18 and later. Generate the modules against the major version of PostgreSQL that the app uses.

`check_schema` gives `SchemaChanged(mismatches)` with each module that differs, or `SchemaUnreadable(module, error)` when a query fails. `format_schema_check_error` gives a message that names each module and its tables, and tells you to regenerate them.

## Testing

- 545 tests run, 0 failed, 100.0% line coverage (655 of 655 lines). The run took 1 minute 5 seconds of wall time, and the runner reports 2 minutes 11 seconds of test time. 4 tests run at a time, and the 20 SSL tests run one at a time (Apple M1 Max, 10 cores, 64 GB, macOS 26.5.1, OTP 29, Gleam 1.19.2)
- The exact `numeric` functions: `dream_postgres_driver` 1.1.0 compares 2,000 random values in each direction with the text of the server on PostgreSQL 16, 17, 18 and 19, with no difference
- The 109 tests of the new helpers passed on PostgreSQL 16, 17, 18 and 19, with `DREAM_POSTGRES_TEST_URL` set to each server
- The fingerprint tests show that the fingerprint does not change when the same DDL makes the tables again with new OIDs, when a dropped column left a gap in the attribute numbers, when a statement-level or `AFTER` trigger is added, or when a session setting is different (each of the nine pinned settings, in a transaction and for a whole session). Each kind of schema change changes it: two columns that swap places, a dropped `NOT NULL`, a new `CHECK`, a renamed or validated constraint, a new type, a unique index that becomes a plain index, a new partial unique index, a rule, a changed view or materialized view, a renamed composite field, a new range subtype, a new row-level `BEFORE` or `INSTEAD OF` trigger, a view that gets `WITH CHECK OPTION`, a changed expression of a generated column, row level security on or forced, a changed policy `USING`, `WITH CHECK` or role, an identity or generated column, a new partition, child table or parent, a changed domain, domain over domain or enum label. One test compares the exact canonical text of a schema with each kind of fact

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
