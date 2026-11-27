//// The pools of the client tests: one pool of the public client on each
//// driver server, and the version that a group of tests runs on. Start
//// them with `start` and stop them with `stop` in the lifecycle hooks of
//// a suite, and pick the version of a group with `choose_version` in its
//// `before_all`.

import dream_postgres.{type Config, type Connection}
import dream_postgres/error
import driver/servers.{type Server, driver_servers}
import gleam/int
import gleam/list
import gleam/result

/// One pool on one driver server.
pub type ServerPool {
  ServerPool(version: Int, port: Int, connection: Connection)
}

/// The pool of each driver server, and the version that the tests of a
/// group run on.
pub type ServerPools {
  ServerPools(pools: List(ServerPool), version: Int)
}

/// The config of a pool of 4 connections to the driver server on `port`,
/// with TLS off.
///
/// ## Example
///
/// ```gleam
/// server_pools.config(5441) |> dream_postgres.pool_size(1)
/// ```
pub fn config(port: Int) -> Config {
  dream_postgres.default_config()
  |> dream_postgres.host("localhost")
  |> dream_postgres.port(port)
  |> dream_postgres.database(servers.database)
  |> dream_postgres.user("dream")
  |> dream_postgres.password(servers.password)
  |> dream_postgres.pool_size(4)
  |> dream_postgres.tls(dream_postgres.TlsOff)
}

/// Starts one pool on each driver server. When one cannot start, the
/// others stop again. No version is chosen yet.
///
/// ## Example
///
/// ```gleam
/// context.setup(server_pools.start, teardown: server_pools.stop)
/// ```
pub fn start() -> Result(ServerPools, String) {
  let started = list.map(driver_servers(), start_pool)
  case result.all(started) {
    Ok(pools) -> Ok(ServerPools(pools:, version: 0))
    Error(reason) -> {
      started |> result.values |> list.each(stop_pool)
      Error(reason)
    }
  }
}

/// Stops each pool.
///
/// ## Example
///
/// ```gleam
/// context.setup(server_pools.start, teardown: server_pools.stop)
/// ```
pub fn stop(pools: ServerPools) -> Result(Nil, String) {
  list.each(pools.pools, stop_pool)
  Ok(Nil)
}

/// A `before_all` hook that makes `version` the version of the tests of a
/// group. The hook fails when no pool has that version.
///
/// ## Example
///
/// ```gleam
/// group("PostgreSQL 16", [before_all(server_pools.choose_version(16))])
/// ```
pub fn choose_version(
  version: Int,
) -> fn(ServerPools) -> Result(ServerPools, String) {
  fn(pools: ServerPools) {
    let chosen_pools = ServerPools(..pools, version:)
    chosen(chosen_pools) |> result.replace(chosen_pools)
  }
}

/// The pool of the chosen version.
///
/// ## Example
///
/// ```gleam
/// server_pools.chosen(pools)
/// // -> Ok(ServerPool(version: 16, ..))
/// ```
pub fn chosen(pools: ServerPools) -> Result(ServerPool, String) {
  list.find(pools.pools, fn(pool) { pool.version == pools.version })
  |> result.replace_error(
    "no pool for PostgreSQL " <> int.to_string(pools.version),
  )
}

fn start_pool(server: Server) -> Result(ServerPool, String) {
  config(server.port)
  |> dream_postgres.start
  |> result.map(ServerPool(server.version, server.port, _))
  |> result.map_error(error.describe)
}

fn stop_pool(pool: ServerPool) -> Nil {
  dream_postgres.stop(pool.connection)
}
