//// The sessions of the codec probes: one driver connection to each driver
//// server, with the server's type catalog, and the version that a group of
//// tests probes. Start them with `start` and stop them with `stop` in the
//// lifecycle hooks of a suite, and pick the version of a group with
//// `choose_version` in its `before_all`.

import dream_postgres/codecs/codec_type.{type DecodeIssue}
import dream_postgres/driver/cell.{
  type Cell, type TypeDescription, type TypeKind, Binary, Null, Text,
  TypeDescription,
}
import dream_postgres/driver/connection
import dream_postgres/driver/connection/backoff.{Backoff} as connection_backoff
import dream_postgres/driver/connection/call.{type Connection}
import dream_postgres/driver/connection/extended_query as connection_extended_query
import dream_postgres/driver/connection/outcome.{type Outcome}
import dream_postgres/driver/connection/settings.{ConnectionConfig} as connection_settings
import dream_postgres/driver/connection/simple_query as connection_simple_query
import dream_postgres/driver/connection/statement as connection_statement
import dream_postgres/driver/login.{PreferChannelBinding}
import dream_postgres/driver/message.{Protocol30}
import dream_postgres/driver/transport.{NoTls, TransportConfig}
import driver/servers.{type Server, driver_servers}
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string

/// One connection to one driver server, with the server's type catalog.
pub type ProbeSession {
  ProbeSession(
    version: Int,
    connection: Connection,
    types: Dict(Int, TypeDescription),
  )
}

/// The session of each driver server, and the version that the tests of a
/// group probe.
pub type ProbeSessions {
  ProbeSessions(sessions: List(ProbeSession), version: Int)
}

/// Why a read on the server gave no value.
pub type ReadFailure {
  /// The server refused the query, or the reply had no cell.
  ReadRefused(reason: String)
  /// The codec does not take the column's type.
  ReadNotAccepted(codec_name: String, type_name: String)
  /// The codec could not read the cell.
  ReadDecodeFailed(issue: DecodeIssue)
}

/// The deadline of each call on a probe connection.
pub const deadline_milliseconds = 5000

// The settings of each session, so the texts do not depend on the server's
// defaults, and the temporary types of the composite, enum and domain
// probes. The temporary types go away with the session.
const session_setup =
  "
SET TimeZone = 'UTC';
SET DateStyle = 'ISO, MDY';
SET IntervalStyle = 'postgres';
SET extra_float_digits = 1;
CREATE TYPE pg_temp.probe_mood AS ENUM ('sad', 'ok', 'happy');
CREATE TYPE pg_temp.probe_address AS (street text, number int4, note text);
CREATE DOMAIN pg_temp.probe_positive AS int4 CHECK (VALUE > 0);
CREATE DOMAIN pg_temp.probe_price AS numeric(10,2);
CREATE DOMAIN pg_temp.probe_span AS numrange;
CREATE DOMAIN pg_temp.probe_embedding AS vector(3);
CREATE DOMAIN pg_temp.probe_feeling AS pg_temp.probe_mood;
CREATE DOMAIN pg_temp.probe_home AS pg_temp.probe_address;
CREATE TYPE pg_temp.probe_line_item AS (amount numeric, quantity int4);
CREATE TYPE pg_temp.probe_order AS (item pg_temp.probe_line_item, note text);
CREATE TEMP TABLE probe_counts AS SELECT generate_series(1, 5) AS n;
ANALYZE probe_counts;
"

// Every type except the row types of tables, with the parts that a type
// description needs. The composite types are only the temporary ones.
const catalog_query =
  "
SELECT t.oid, n.nspname, t.typname, t.typtype, t.typcategory, t.typelem,
  t.typbasetype, coalesce(r.rngsubtype, 0), coalesce(m.rngtypid, 0),
  coalesce((SELECT string_agg(e.enumlabel, ',' ORDER BY e.enumsortorder)
    FROM pg_enum e WHERE e.enumtypid = t.oid), ''),
  coalesce((SELECT string_agg(a.attname || ':' || a.atttypid, ','
      ORDER BY a.attnum)
    FROM pg_attribute a
    WHERE a.attrelid = t.typrelid AND a.attnum > 0 AND NOT a.attisdropped),
    '')
FROM pg_type t
JOIN pg_namespace n ON n.oid = t.typnamespace
LEFT JOIN pg_range r ON r.rngtypid = t.oid
LEFT JOIN pg_range m ON m.rngmultitypid = t.oid
WHERE t.typtype <> 'c' OR n.nspname LIKE 'pg_temp%'
"

/// Starts one session on each driver server. When one cannot start, the
/// others stop again. No version is chosen yet.
///
/// ## Example
///
/// ```gleam
/// describe(
///   "codec probes",
///   context.setup(probe_sessions.start, teardown: probe_sessions.stop),
///   [],
/// )
/// ```
pub fn start() -> Result(ProbeSessions, String) {
  let started = list.map(driver_servers(), start_session)
  case result.all(started) {
    Ok(sessions) -> Ok(ProbeSessions(sessions:, version: 0))
    Error(reason) -> {
      started |> result.values |> stop_each
      Error(reason)
    }
  }
}

/// Stops the connection of each session.
///
/// ## Example
///
/// ```gleam
/// context.setup(probe_sessions.start, teardown: probe_sessions.stop)
/// ```
pub fn stop(sessions: ProbeSessions) -> Result(Nil, String) {
  stop_each(sessions.sessions)
  Ok(Nil)
}

/// A `before_all` hook that makes `version` the version of the tests of a
/// group. The hook fails when no session has that version.
///
/// ## Example
///
/// ```gleam
/// group("PostgreSQL 16", [before_all(probe_sessions.choose_version(16))])
/// ```
pub fn choose_version(
  version: Int,
) -> fn(ProbeSessions) -> Result(ProbeSessions, String) {
  fn(sessions: ProbeSessions) {
    let chosen_sessions = ProbeSessions(..sessions, version:)
    chosen(chosen_sessions) |> result.replace(chosen_sessions)
  }
}

/// The session of the chosen version.
///
/// ## Example
///
/// ```gleam
/// probe_sessions.chosen(sessions)
/// // -> Ok(ProbeSession(version: 16, ..))
/// ```
pub fn chosen(sessions: ProbeSessions) -> Result(ProbeSession, String) {
  list.find(sessions.sessions, fn(session) {
    session.version == sessions.version
  })
  |> result.replace_error(
    "no probe session for PostgreSQL " <> int.to_string(sessions.version),
  )
}

/// The lookup of the types of the session's catalog, as a codec needs it.
///
/// ## Example
///
/// ```gleam
/// codec_type.accepts(codec, description, probe_sessions.lookup(session))
/// ```
pub fn lookup(
  session: ProbeSession,
) -> fn(Int) -> Result(TypeDescription, Nil) {
  fn(type_id) { dict.get(session.types, type_id) }
}

/// The description of a type of the session's catalog.
///
/// ## Example
///
/// ```gleam
/// probe_sessions.type_of(session, 23)
/// // -> Ok(TypeDescription(id: 23, schema: "pg_catalog", name: "int4", ..))
/// ```
pub fn type_of(
  session: ProbeSession,
  type_id: Int,
) -> Result(TypeDescription, String) {
  dict.get(session.types, type_id)
  |> result.replace_error(
    "the type " <> int.to_string(type_id) <> " is unknown",
  )
}

/// The first cell of the first row of an outcome.
///
/// ## Example
///
/// ```gleam
/// probe_sessions.first_cell(outcome)
/// // -> Ok(Text(<<"7">>))
/// ```
pub fn first_cell(outcome: Outcome) -> Result(Cell, String) {
  outcome.result.rows
  |> list.first
  |> result.try(list.first)
  |> result.replace_error("the result has no cell")
}

fn stop_each(sessions: List(ProbeSession)) -> Nil {
  list.each(sessions, fn(session) { connection.stop(session.connection) })
}

fn start_session(server: Server) -> Result(ProbeSession, String) {
  use address <- result.try(
    transport.address("localhost", server.port)
    |> result.map_error(string.inspect),
  )
  use login_config <- result.try(
    login.new(
      user: "dream",
      database: servers.database,
      password: login.password(servers.password),
      parameters: [],
      channel_binding: PreferChannelBinding,
      protocol_version: Protocol30,
    )
    |> result.map_error(string.inspect),
  )
  use started <- result.try(
    connection.start(ConnectionConfig(
      transport: TransportConfig(address, NoTls, 5000, 500),
      login: login_config,
      setup_timeout_milliseconds: 5000,
      cancel_timeout_milliseconds: 2000,
      reconnect: Backoff(10, 60_000, connection_backoff.full_jitter),
      events: None,
      notifications: None,
      notices: None,
      statements: connection_settings.CacheStatements(limit: 512),
    ))
    |> result.map_error(string.inspect),
  )
  case prepare_session(started) {
    Ok(types) ->
      Ok(ProbeSession(version: server.version, connection: started, types:))
    Error(reason) -> {
      connection.stop(started)
      Error(reason)
    }
  }
}

fn prepare_session(
  started: Connection,
) -> Result(Dict(Int, TypeDescription), String) {
  use _ <- result.try(
    connection_simple_query.run_simple_query(
      started,
      connection_statement.statement(session_setup),
      deadline_milliseconds,
    )
    |> result.map_error(string.inspect),
  )
  use outcome <- result.try(
    connection_extended_query.run(
      started,
      connection_statement.statement(catalog_query),
      [],
      [],
      deadline_milliseconds,
    )
    |> result.map_error(string.inspect),
  )
  use descriptions <- result.try(list.try_map(outcome.result.rows, catalog_row))
  Ok(
    descriptions
    |> list.map(fn(description) { #(description.id, description) })
    |> dict.from_list,
  )
}

fn catalog_row(cells: List(Cell)) -> Result(TypeDescription, String) {
  use texts <- result.try(list.try_map(cells, catalog_text))
  case texts {
    [
      id,
      schema,
      name,
      type_code,
      category,
      element,
      base,
      subtype,
      range_type,
      labels,
      fields,
    ] -> {
      use id <- result.try(catalog_int(id))
      use kind <- result.try(type_kind(
        type_code,
        category,
        [element, base, subtype, range_type],
        labels,
        fields,
      ))
      Ok(TypeDescription(id:, schema:, name:, kind:))
    }
    _ -> Error("a catalog row has " <> int.to_string(list.length(texts)))
  }
}

fn type_kind(
  type_code: String,
  category: String,
  type_ids: List(String),
  labels: String,
  fields: String,
) -> Result(TypeKind, String) {
  use parsed <- result.try(list.try_map(type_ids, catalog_int))
  case type_code, category, parsed {
    "b", "A", [element, _, _, _] -> Ok(cell.Array(element))
    "b", _, _ -> Ok(cell.Base)
    "e", _, _ -> Ok(cell.Enum(string.split(labels, ",")))
    "c", _, _ ->
      string.split(fields, ",")
      |> list.try_map(composite_field)
      |> result.map(cell.Composite)
    "d", _, [_, base, _, _] -> Ok(cell.Domain(base))
    "r", _, [_, _, subtype, _] -> Ok(cell.Range(subtype))
    "m", _, [_, _, _, range_type] -> Ok(cell.Multirange(range_type))
    _, _, _ -> Ok(cell.Pseudo)
  }
}

fn composite_field(text: String) -> Result(#(String, Int), String) {
  use #(name, type_id) <- result.try(
    string.split_once(text, ":")
    |> result.replace_error("a composite field has no type: " <> text),
  )
  catalog_int(type_id) |> result.map(fn(id) { #(name, id) })
}

fn catalog_text(value: Cell) -> Result(String, String) {
  case value {
    Text(bytes:) ->
      bit_array.to_string(bytes)
      |> result.replace_error("a catalog cell is not UTF-8")
    Binary(..) | Null -> Error("a catalog cell is not text")
  }
}

fn catalog_int(text: String) -> Result(Int, String) {
  int.parse(text) |> result.replace_error("not an integer: " <> text)
}
