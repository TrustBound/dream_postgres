//// The type catalog: one gleam_otp actor that knows what each type OID of
//// a server is, for the codecs.
////
//// A catalog starts empty. The first lookup that does not find its type
//// loads the catalog: the caller runs the catalog load of
//// `driver/housekeeping_sql` on its own connection, makes a table from the
//// rows, and gives the table to the catalog. The load runs in the
//// caller's process, never in the catalog's, so lookups of other callers
//// go on during a load, with the table of the last load.
////
//// Each lookup that does not find its type causes one load, and only one.
//// If the type is still not found after it, the lookup gives
//// `UnknownType` with the OID. A load that started before the lookup did
//// not find its type never counts for it: its snapshot can be older than
//// the type. So a lookup during a load starts a load of its own, and is
//// never skipped.
////
//// A table replaces the table of the catalog in one step, and only when
//// its load started after the load of the table that it replaces. So no
//// lookup sees a part of a load, and a slow old load never replaces the
//// table of a newer one.
////
//// The load runs on the caller's connection, in the caller's transaction
//// when it has one. So a type that the caller's transaction made is found
//// before the transaction commits. In a failed transaction the load fails
//// with the server's error.
////
//// How a pool uses the catalog: each pool starts one catalog when it
//// starts, with `start` or as a child of its supervisor with `supervised`,
//// and gives it to each caller with the connection that the caller
//// checked out. The catalog has no name and no shared table, so a new
//// pool always starts with an empty catalog and never uses the types of
//// an earlier pool. The catalog does not depend on one connection: any
//// connection of the pool can load it.
////
//// This module is internal to dream_postgres.

import dream_postgres/driver/catalog_table.{
  type CatalogTable, type RowError, find, find_underlying,
}
import dream_postgres/driver/connection/call.{type Connection}
import dream_postgres/driver/connection/extended_query as connection_extended_query
import dream_postgres/driver/connection/request_failure.{type HousekeepingError}
import dream_postgres/driver/housekeeping_sql
import dream_postgres/internal/cell.{type TypeDescription}
import gleam/erlang/process.{type Down, type Pid, type Subject}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result.{map_error, try}

// Types -----------------------------------------------------------------------

/// A catalog process.
pub opaque type Catalog {
  Catalog(subject: Subject(Message), pid: Pid)
}

/// What the catalog tells its subscriber.
pub type CatalogEvent {
  /// A lookup did not find its type, and its caller loads the catalog.
  /// Each load has the next number, from 1.
  LoadStarted(load_number: Int)
}

/// Why a lookup gave no description.
pub type CatalogError {
  /// The type is not in the catalog, also after the load that the lookup
  /// caused.
  UnknownType(type_id: Int)
  /// The catalog query failed on the caller's connection.
  LoadFailed(error: HousekeepingError)
  /// The rows of the catalog query do not make a table.
  UnreadableCatalog(error: RowError)
  /// The catalog process is gone.
  CatalogProcessDown
}

/// Which description a lookup gives.
type Resolution {
  /// The type as the catalog has it.
  AsNamed
  /// For a domain, the end of its chain of base types.
  ThroughDomains
}

type LookupAnswer {
  Found(description: TypeDescription)
  /// The type is not in the table. The caller loads the catalog, as the
  /// load with this number.
  LoadNeeded(load_number: Int)
}

type Message {
  Lookup(type_id: Int, resolution: Resolution, reply: Subject(LookupAnswer))
  InstallAndFind(
    load_number: Int,
    table: CatalogTable,
    type_id: Int,
    resolution: Resolution,
    reply: Subject(Option(TypeDescription)),
  )
  Stop(reply: Subject(Nil))
}

type State {
  State(
    table: CatalogTable,
    /// The number of the load that made `table`, or 0 before the first.
    installed_load: Int,
    /// The number of the last load that started.
    started_load: Int,
    events: Option(Subject(CatalogEvent)),
  )
}

// Starting and stopping -------------------------------------------------------

/// Starts an empty catalog process, linked to the caller.
///
/// ## Parameters
///
/// - `events`: where the catalog tells of each load, or `None`
///
/// ## Returns
///
/// - `Ok(Catalog)`: the catalog, with no type yet
/// - `Error(actor.StartError)`: the process did not start
pub fn start(
  events: Option(Subject(CatalogEvent)),
) -> Result(Catalog, actor.StartError) {
  start_process(events) |> result.map(started_catalog)
}

/// The catalog as a child of a gleam_otp supervisor, for example the
/// supervisor of a pool.
///
/// ## Parameters
///
/// - `events`: where the catalog tells of each load, or `None`
///
/// ## Returns
///
/// A worker child that starts an empty catalog. A restart starts an empty
/// catalog too.
pub fn supervised(
  events: Option(Subject(CatalogEvent)),
) -> ChildSpecification(Catalog) {
  supervision.worker(fn() { start_process(events) })
}

fn start_process(
  events: Option(Subject(CatalogEvent)),
) -> Result(actor.Started(Catalog), actor.StartError) {
  let state =
    State(
      table: catalog_table.empty(),
      installed_load: 0,
      started_load: 0,
      events:,
    )
  actor.new(state)
  |> actor.on_message(handle_message)
  |> actor.start
  |> result.map(with_catalog)
}

fn with_catalog(
  started: actor.Started(Subject(Message)),
) -> actor.Started(Catalog) {
  actor.Started(
    pid: started.pid,
    data: Catalog(subject: started.data, pid: started.pid),
  )
}

fn started_catalog(started: actor.Started(Catalog)) -> Catalog {
  started.data
}

/// Stops the catalog process.
///
/// ## Parameters
///
/// - `catalog`: the catalog to stop
///
/// ## Returns
///
/// `Nil`, also when the process is gone already.
pub fn stop(catalog: Catalog) -> Nil {
  ask(catalog, Stop) |> result.unwrap(Nil)
}

// Lookups ---------------------------------------------------------------------

/// The description of a type, as the server's catalog has it. A domain is
/// a `Domain` with the OID of its own base type.
///
/// ## Parameters
///
/// - `catalog`: the catalog of the pool
/// - `connection`: the caller's connection, for a load
/// - `type_id`: the type OID
/// - `deadline_milliseconds`: the longest time for the catalog query of a
///   load
///
/// ## Returns
///
/// - `Ok(TypeDescription)`: the schema, the name, the kind and the parts
/// - `Error(CatalogError)`: the type is unknown, the load failed, or the
///   catalog is gone
pub fn describe(
  catalog: Catalog,
  connection: Connection,
  type_id: Int,
  deadline_milliseconds: Int,
) -> Result(TypeDescription, CatalogError) {
  describe_with(catalog, connection, type_id, deadline_milliseconds, AsNamed)
}

/// The description of the type that holds the values of a type: for a
/// domain, the first type of its chain of base types that is not a domain,
/// and for any other type, the type itself.
///
/// ## Parameters
///
/// - `catalog`: the catalog of the pool
/// - `connection`: the caller's connection, for a load
/// - `type_id`: the type OID
/// - `deadline_milliseconds`: the longest time for the catalog query of a
///   load
///
/// ## Returns
///
/// - `Ok(TypeDescription)`: the description of the underlying type
/// - `Error(CatalogError)`: the type is unknown, the load failed, or the
///   catalog is gone
pub fn describe_underlying(
  catalog: Catalog,
  connection: Connection,
  type_id: Int,
  deadline_milliseconds: Int,
) -> Result(TypeDescription, CatalogError) {
  describe_with(
    catalog,
    connection,
    type_id,
    deadline_milliseconds,
    ThroughDomains,
  )
}

fn describe_with(
  catalog: Catalog,
  connection: Connection,
  type_id: Int,
  deadline_milliseconds: Int,
  resolution: Resolution,
) -> Result(TypeDescription, CatalogError) {
  use answer <- try(ask(catalog, Lookup(type_id, resolution, _)))
  case answer {
    Found(description:) -> Ok(description)
    LoadNeeded(load_number:) ->
      load_and_find(
        catalog,
        connection,
        load_number,
        type_id,
        deadline_milliseconds,
        resolution,
      )
  }
}

/// Runs the catalog query, gives the table to the catalog, and looks up
/// the type again in the catalog's table.
fn load_and_find(
  catalog: Catalog,
  connection: Connection,
  load_number: Int,
  type_id: Int,
  deadline_milliseconds: Int,
  resolution: Resolution,
) -> Result(TypeDescription, CatalogError) {
  use outcome <- try(
    connection_extended_query.run_housekeeping(
      connection,
      housekeeping_sql.catalog_load,
      deadline_milliseconds,
    )
    |> map_error(LoadFailed),
  )
  use table <- try(
    catalog_table.from_rows(outcome.result.rows) |> map_error(UnreadableCatalog),
  )
  use found <- try(
    ask(catalog, InstallAndFind(load_number, table, type_id, resolution, _)),
  )
  option.to_result(found, UnknownType(type_id))
}

/// Sends a message to the catalog and waits for the answer, or for the
/// end of the process. The catalog answers each message at once, with no
/// input or output, so the wait has no timeout.
fn ask(
  catalog: Catalog,
  make: fn(Subject(reply)) -> Message,
) -> Result(reply, CatalogError) {
  let answers = process.new_subject()
  let monitor = process.monitor(catalog.pid)
  process.send(catalog.subject, make(answers))
  let answer =
    process.new_selector()
    |> process.select_map(answers, Ok)
    |> process.select_specific_monitor(monitor, catalog_down)
    |> process.selector_receive_forever
  process.demonitor_process(monitor)
  answer
}

fn catalog_down(_down: Down) -> Result(reply, CatalogError) {
  Error(CatalogProcessDown)
}

// The process -----------------------------------------------------------------

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    Lookup(type_id:, resolution:, reply:) ->
      actor.continue(look_up(state, type_id, resolution, reply))
    InstallAndFind(load_number:, table:, type_id:, resolution:, reply:) -> {
      let state = install(state, load_number, table)
      process.send(reply, find_in(state.table, type_id, resolution))
      actor.continue(state)
    }
    Stop(reply:) -> {
      process.send(reply, Nil)
      actor.stop()
    }
  }
}

/// Answers with the description, or with the number of a new load.
fn look_up(
  state: State,
  type_id: Int,
  resolution: Resolution,
  reply: Subject(LookupAnswer),
) -> State {
  case find_in(state.table, type_id, resolution) {
    Some(description) -> {
      process.send(reply, Found(description))
      state
    }
    None -> {
      let load_number = state.started_load + 1
      option.map(state.events, process.send(_, LoadStarted(load_number)))
      process.send(reply, LoadNeeded(load_number))
      State(..state, started_load: load_number)
    }
  }
}

/// The table replaces the catalog's table only when its load started
/// after the load of the catalog's table.
fn install(state: State, load_number: Int, table: CatalogTable) -> State {
  case load_number > state.installed_load {
    True -> State(..state, table:, installed_load: load_number)
    False -> state
  }
}

fn find_in(
  table: CatalogTable,
  type_id: Int,
  resolution: Resolution,
) -> Option(TypeDescription) {
  case resolution {
    AsNamed -> find(table, type_id)
    ThroughDomains -> find_underlying(table, type_id)
  }
}
