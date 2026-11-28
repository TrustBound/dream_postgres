//// Queries: build one with its parameters, run it, and read its rows.
////
//// ### Create a post <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/posts.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
////
//// ```gleam
//// import dream_errors.{type Error}
//// import dream_postgres/codec.{int, text}
//// import dream_postgres/error.{type PostgresError}
//// import dream_postgres/pool.{type Connection}
//// import dream_postgres/query.{named, one, parameter, query}
//// import dream_postgres/row.{type Row, column, row}
////
//// pub type Post {
////   Post(id: Int, user_id: Int, title: String)
//// }
////
//// /// Reads the columns id, user_id and title, in this order, into a Post.
//// pub fn post_row() -> Row(Post) {
////   use id <- column(int)
////   use user_id <- column(int)
////   use title <- column(text)
////   row(Post(id:, user_id:, title:))
//// }
////
//// pub fn create(
////   connection: Connection,
////   user_id: Int,
////   title: String,
//// ) -> Result(Post, Error(PostgresError)) {
////   "INSERT INTO posts (user_id, title) VALUES ($1, $2)
//// RETURNING id, user_id, title"
////   |> query
////   |> named("post.create")
////   |> parameter(int, user_id)
////   |> parameter(text, title)
////   |> one(post_row(), connection)
//// }
//// ```

import dream_errors.{type Error}
import dream_postgres/codec.{type Codec}
import dream_postgres/error.{type PostgresError}
import dream_postgres/interceptor.{type Interceptor}
import dream_postgres/internal/connection_state.{
  chain_of, hold, lowest_layer, run_held_sql, secret_free_error,
}
import dream_postgres/internal/failure.{failure}
import dream_postgres/internal/query as internal_query
import dream_postgres/internal/runner.{type LowestLayer}
import dream_postgres/pool.{type Connection}
import dream_postgres/row.{type Row}
import gleam/option.{type Option, None, Some}
import gleam/result

/// A query: the SQL, its parameters, and an optional name.
pub type Query =
  internal_query.Query

/// A query of the SQL, with no parameters yet.
pub fn query(sql: String) -> Query {
  internal_query.query(sql)
}

/// Adds the next parameter: the first call gives `$1`, the next `$2`.
pub fn parameter(query: Query, codec: Codec(a), value: a) -> Query {
  internal_query.parameter(query, codec, value)
}

/// Adds the next parameter as `parameter` does, and marks it secret, for
/// a value such as a password or a token. A live run sends it as any other
/// parameter. A recorder never saves its value: the recording keeps only
/// its codec, and playback takes any value with that codec at that
/// position. `string.inspect` of the request that an interceptor gets
/// shows the parameter as `Secret`, never its value.
///
/// ### Check a password against its hash <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/password_check.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_errors.{type Error}
/// import dream_postgres/codec.{bool, text}
/// import dream_postgres/error.{type PostgresError}
/// import dream_postgres/pool.{type Connection}
/// import dream_postgres/query.{named, one, parameter, query, secret_parameter}
/// import dream_postgres/row.{single}
///
/// /// Checks a password against its stored SHA-256 hash in hex. The password
/// /// is a secret parameter, so a recording of this query never holds it.
/// pub fn password_matches(
///   connection: Connection,
///   password: String,
///   stored_hash: String,
/// ) -> Result(Bool, Error(PostgresError)) {
///   "SELECT encode(sha256(convert_to($1, 'UTF8')), 'hex') = $2"
///   |> query
///   |> named("password.matches")
///   |> secret_parameter(text, password)
///   |> parameter(text, stored_hash)
///   |> one(single(bool), connection)
/// }
/// ```
pub fn secret_parameter(query: Query, codec: Codec(a), value: a) -> Query {
  internal_query.secret_parameter(query, codec, value)
}

/// Gives the query a name, which errors and logs show with the SQL.
pub fn named(query: Query, name: String) -> Query {
  internal_query.named(query, name)
}

/// Runs a query and reads every row.
pub fn all(
  query: Query,
  reader: Row(a),
  connection: Connection,
) -> Result(List(a), Error(PostgresError)) {
  use executor, interceptors <- with_executor(connection, query)
  runner.all(query, reader, executor, interceptors)
}

/// Runs a query that gives exactly one row, and reads it. No row is
/// `NotFound`, and more than one row is `Failed`.
pub fn one(
  query: Query,
  reader: Row(a),
  connection: Connection,
) -> Result(a, Error(PostgresError)) {
  use executor, interceptors <- with_executor(connection, query)
  runner.one(query, reader, executor, interceptors)
}

/// Runs a query that gives at most one row, and reads it. More than one
/// row is `Failed`.
pub fn maybe_one(
  query: Query,
  reader: Row(a),
  connection: Connection,
) -> Result(Option(a), Error(PostgresError)) {
  use executor, interceptors <- with_executor(connection, query)
  runner.maybe_one(query, reader, executor, interceptors)
}

/// Runs a command and gives the row count of its tag, for example 3 for
/// `UPDATE 3`.
pub fn affected(
  query: Query,
  connection: Connection,
) -> Result(Int, Error(PostgresError)) {
  use executor, interceptors <- with_executor(connection, query)
  runner.affected(query, executor, interceptors)
}

fn with_executor(
  connection: Connection,
  query: Query,
  body: fn(LowestLayer, List(Interceptor)) -> Result(a, Error(PostgresError)),
) -> Result(a, Error(PostgresError)) {
  hold(connection, fn(held) { body(lowest_layer(held), chain_of(held)) })
  |> result.map_error(failure(
    internal_query.name(query),
    Some(internal_query.sql(query)),
    _,
  ))
  |> result.flatten
  |> result.map_error(secret_free_error(connection, _))
}

/// Runs SQL with the simple query protocol, for example several
/// statements at once, or a statement that has no parameters and no
/// result to read. The rows of the statements are not read. Outside a
/// transaction, the statements of one call run as one transaction, unless
/// the SQL has its own `BEGIN` or `COMMIT`.
pub fn run_sql(
  sql: String,
  connection: Connection,
) -> Result(Nil, Error(PostgresError)) {
  hold(connection, run_held_sql(_, sql))
  |> result.map_error(failure(None, Some(sql), _))
  |> result.flatten
  |> result.map_error(secret_free_error(connection, _))
  |> result.replace(Nil)
}
