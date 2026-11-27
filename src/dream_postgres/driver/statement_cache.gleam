//// The named prepared statements of one connection, by their SQL, with the
//// description that the server gave when it prepared each one.
////
//// The cache holds at most its limit of statements. Before a new
//// statement is prepared on a full cache, the least recently used one
//// leaves it, and its name waits in the list of names to close on the
//// server, which the connection process closes in the same round trip
//// as its next Parse. A statement that
//// the server says changed or does not exist (SQLSTATE 0A000 or 26000)
//// is forgotten the same way.
////
//// The cache is a pure value: the connection process keeps it in its
//// state, and a new session starts with an empty one.
////
//// This module is internal to dream_postgres.

import dream_postgres/internal/cell.{type StatementDescription}
import gleam/dict.{type Dict}
import gleam/int.{to_string}
import gleam/list.{fold}
import gleam/option.{type Option, None, Some}

/// The number of statements a connection keeps when its settings name no
/// other limit.
pub const default_limit = 512

/// The prepared statements of one connection.
pub opaque type StatementCache {
  StatementCache(
    limit: Int,
    entries: Dict(String, Entry),
    /// Counts each use, so the least recently used entry has the lowest
    /// `last_used`.
    clock: Int,
    /// The number for the next statement name.
    next_name: Int,
    /// The names to close on the server, oldest first.
    stale: List(String),
  )
}

type Entry {
  Entry(name: String, description: StatementDescription, last_used: Int)
}

/// A statement of the cache: its name on the server and its description.
pub type CachedStatement {
  CachedStatement(name: String, description: StatementDescription)
}

/// An empty cache.
///
/// ## Parameters
///
/// - `limit`: the most statements to keep, 1 or more
///
/// ## Returns
///
/// A cache with no statements.
pub fn new(limit: Int) -> StatementCache {
  StatementCache(
    limit: int.max(limit, 1),
    entries: dict.new(),
    clock: 0,
    next_name: 1,
    stale: [],
  )
}

/// Finds the statement of `sql`, and marks it as used now.
///
/// ## Parameters
///
/// - `cache`: the cache
/// - `sql`: the SQL of the statement
///
/// ## Returns
///
/// The cache with the use counted, and the statement or `None`.
pub fn lookup(
  cache: StatementCache,
  sql: String,
) -> #(StatementCache, Option(CachedStatement)) {
  case dict.get(cache.entries, sql) {
    Ok(entry) -> #(touch(cache, sql, entry), Some(cached(entry)))
    Error(Nil) -> #(cache, None)
  }
}

fn touch(cache: StatementCache, sql: String, entry: Entry) -> StatementCache {
  let used = Entry(..entry, last_used: cache.clock)
  StatementCache(
    ..cache,
    entries: dict.insert(cache.entries, sql, used),
    clock: cache.clock + 1,
  )
}

fn cached(entry: Entry) -> CachedStatement {
  CachedStatement(name: entry.name, description: entry.description)
}

/// Gives a new statement name, which no statement of this cache had.
///
/// ## Parameters
///
/// - `cache`: the cache
///
/// ## Returns
///
/// The cache and the name, for example `dream_postgres_1`.
pub fn new_name(cache: StatementCache) -> #(StatementCache, String) {
  let name = "dream_postgres_" <> to_string(cache.next_name)
  #(StatementCache(..cache, next_name: cache.next_name + 1), name)
}

/// Keeps a statement that the server prepared. Call `make_room` before
/// the prepare, so the cache never holds more than its limit.
///
/// ## Parameters
///
/// - `cache`: the cache
/// - `sql`: the SQL of the statement
/// - `name`: its name on the server
/// - `description`: what the server said about it
///
/// ## Returns
///
/// The cache with the statement.
pub fn insert(
  cache: StatementCache,
  sql: String,
  name: String,
  description: StatementDescription,
) -> StatementCache {
  let entry = Entry(name:, description:, last_used: cache.clock)
  StatementCache(
    ..cache,
    entries: dict.insert(cache.entries, sql, entry),
    clock: cache.clock + 1,
  )
}

/// Makes room for one more statement: when the cache is full, the least
/// recently used statement leaves it, and its name goes to the names to
/// close.
///
/// ## Parameters
///
/// - `cache`: the cache
///
/// ## Returns
///
/// The cache, with room for one more statement.
pub fn make_room(cache: StatementCache) -> StatementCache {
  let full = dict.size(cache.entries) >= cache.limit
  case full, dict.to_list(cache.entries) {
    True, [first, ..others] -> forget(cache, least_recent(first, others))
    _, _ -> cache
  }
}

fn least_recent(
  first: #(String, Entry),
  others: List(#(String, Entry)),
) -> String {
  let #(sql, _entry) = fold(others, first, older_entry)
  sql
}

fn older_entry(
  oldest: #(String, Entry),
  candidate: #(String, Entry),
) -> #(String, Entry) {
  case { candidate.1 }.last_used < { oldest.1 }.last_used {
    True -> candidate
    False -> oldest
  }
}

/// Removes the statement of `sql`, and puts its name in the names to
/// close. A statement that is not in the cache changes nothing.
///
/// ## Parameters
///
/// - `cache`: the cache
/// - `sql`: the SQL of the statement
///
/// ## Returns
///
/// The cache without the statement.
pub fn forget(cache: StatementCache, sql: String) -> StatementCache {
  case dict.get(cache.entries, sql) {
    Ok(entry) ->
      StatementCache(
        ..cache,
        entries: dict.delete(cache.entries, sql),
        stale: list.append(cache.stale, [entry.name]),
      )
    Error(Nil) -> cache
  }
}

/// Takes every name to close on the server, oldest first.
///
/// ## Parameters
///
/// - `cache`: the cache
///
/// ## Returns
///
/// The cache with no names to close, and the names.
pub fn take_stale(cache: StatementCache) -> #(StatementCache, List(String)) {
  #(StatementCache(..cache, stale: []), cache.stale)
}
