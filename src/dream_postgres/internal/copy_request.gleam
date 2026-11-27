//// The request and answer forms of a COPY, so that a COPY goes through
//// the interceptors like a query: the table, the columns and the rows of
//// a `copy_from`, and the rows that a `copy_to` reads.
////
//// The rows of a `copy_to` are not in memory: the answer says where they
//// come from, and the reader of the COPY folds over them one at a time.
//// An interceptor that must see each row adds a watcher.

import dream_postgres/driver/connection.{type Connection}
import dream_postgres/error.{type Reason}
import dream_postgres/internal/cell.{type Cell}
import dream_postgres/internal/copy_stream
import dream_postgres/internal/query.{type Value}
import dream_postgres/secrets.{type Secrets}
import gleam/list
import gleam/option.{type Option, None, Some}

/// The table that a `copy_from` stores its rows in.
pub opaque type Table {
  /// A table found through the search path.
  Table(name: String)
  /// A table in a named schema.
  TableInSchema(schema: String, name: String)
}

/// A table found through the search path. The name is one identifier: a
/// dot in it is part of the name.
pub fn table(name: String) -> Table {
  Table(name:)
}

/// A table in the schema. Each part is quoted on its own.
pub fn table_in_schema(schema: String, name: String) -> Table {
  TableInSchema(schema:, name:)
}

/// The table as SQL, each part quoted as an identifier.
pub fn table_sql(table: Table) -> String {
  case table {
    Table(name:) -> copy_stream.quote_identifier(name)
    TableInSchema(schema:, name:) ->
      copy_stream.quote_identifier(schema)
      <> "."
      <> copy_stream.quote_identifier(name)
  }
}

/// The rows of a `copy_from`, each made from a row of the app when it is
/// needed. A feed can be read more than one time: each read makes the
/// rows again from the start.
pub opaque type RowFeed {
  RowFeed(next: fn() -> Option(#(List(Value), RowFeed)))
}

/// The feed of the rows, each written with `write`.
pub fn feed(rows: List(a), write: fn(a) -> List(Value)) -> RowFeed {
  RowFeed(next: fn() {
    case rows {
      [] -> None
      [row, ..rest] -> Some(#(write(row), feed(rest, write)))
    }
  })
}

/// The fields of the next row and the feed of the rows after it, or
/// `None` after the last row.
pub fn next_row(feed: RowFeed) -> Option(#(List(Value), RowFeed)) {
  feed.next()
}

/// The feed with the fields of each row changed by `change`, which gets
/// the number of the row, from 0, and its fields.
pub fn map_rows(
  feed: RowFeed,
  change: fn(Int, List(Value)) -> List(Value),
) -> RowFeed {
  map_rows_from(feed, 0, change)
}

fn map_rows_from(
  feed: RowFeed,
  row_number: Int,
  change: fn(Int, List(Value)) -> List(Value),
) -> RowFeed {
  RowFeed(next: fn() {
    feed.next()
    |> option.map(fn(next) {
      #(
        change(row_number, next.0),
        map_rows_from(next.1, row_number + 1, change),
      )
    })
  })
}

/// The rows of the answer to a `copy_to`: where they come from, and the
/// watchers that see each of them.
pub type CopyRows {
  CopyRows(source: RowSource, watchers: List(RowWatcher))
}

/// Where the rows of a `copy_to` come from.
pub type RowSource {
  /// A binary `COPY (sql) TO STDOUT` on the connection, which starts when
  /// the reader of the COPY is checked. It must end before `deadline_at`,
  /// in the monotonic milliseconds of the driver. `host` and `port` name
  /// the server in errors.
  DatabaseRows(
    connection: Connection,
    sql: String,
    name: Option(String),
    deadline_at: Int,
    host: String,
    port: Int,
    /// The secrets of the config, for the text of the span of the COPY.
    secrets: Secrets,
  )
  /// Rows that are known already, such as the rows of a recording, and how
  /// the stream of them ended.
  RecordedRows(rows: List(List(Cell)), ending: Result(Nil, Reason))
}

/// A watcher of the rows of a `copy_to`. `take` gets the cells of each row
/// before the row is read, and gives the watcher for the next row.
/// `finish` gets how the stream ended. An error of `finish` is the error
/// of the COPY, when the COPY itself did not fail.
pub type RowWatcher {
  RowWatcher(
    take: fn(List(Cell)) -> RowWatcher,
    finish: fn(Result(Nil, Reason)) -> Result(Nil, Reason),
  )
}

/// The rows with one more watcher, after the watchers they have.
pub fn watch(rows: CopyRows, watcher: RowWatcher) -> CopyRows {
  CopyRows(..rows, watchers: list.append(rows.watchers, [watcher]))
}

/// The rows with the rows of a recording changed. The rows of a database
/// are read one at a time while they arrive, so they do not change.
pub fn change_recorded_rows(
  rows: CopyRows,
  change: fn(List(List(Cell))) -> List(List(Cell)),
) -> CopyRows {
  case rows.source {
    RecordedRows(rows: recorded, ending:) ->
      CopyRows(..rows, source: RecordedRows(rows: change(recorded), ending:))
    DatabaseRows(..) -> rows
  }
}
