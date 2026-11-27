# Pool tuning

This guide explains how the pool hands out connections, and how the pool size and the two timeouts change that. It also shows the other times of the pool, and the times that you cannot change.

## Table of Contents

- [How a call gets a connection](#how-a-call-gets-a-connection)
- [Set the size and the timeouts](#set-the-size-and-the-timeouts)
- [The pool size](#the-pool-size)
- [The checkout timeout](#the-checkout-timeout)
- [The query timeout](#the-query-timeout)
- [What the pool does between calls](#what-the-pool-does-between-calls)
- [Set the other times](#set-the-other-times)
- [Fixed times](#fixed-times)
- [Watch the pool](#watch-the-pool)

## How a call gets a connection

A pool has `pool_size` connections. Each call of `all`, `one`, `maybe_one`, `affected` or `run_sql` holds one connection for its run, and gives it back when the run ends. A transaction holds one connection from `BEGIN` to `COMMIT` or `ROLLBACK`. `with_connection` holds one connection for its whole callback.

When no connection is free, the call waits in a queue, oldest first. It gets the next connection that comes free, or an error when its wait passes the checkout timeout.

## Set the size and the timeouts

### A pool for many short queries <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/busy_service.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres.{type Config, checkout_timeout, pool_size, query_timeout}

/// A pool for a service with many short queries: 20 connections, at most
/// 2 seconds for each query, and at most 500 ms of wait for a free
/// connection.
pub fn busy_service(config: Config) -> Config {
  config
  |> pool_size(20)
  |> query_timeout(2000)
  |> checkout_timeout(500)
}
```

## The pool size

`pool_size` sets the number of connections. The default is 10, and a size below 1 is an `Invalid` error from `start`.

Each connection is one session on the server. The server refuses a session above its `max_connections` setting. So the sizes of all pools on all instances of your app, added together, must stay below that setting, with space for the sessions of other clients.

A call holds its connection while it runs. A transaction or a `with_connection` callback holds its connection also while your code runs between its queries. Keep slow work, such as a call to another service, out of a transaction, so that the connection comes back sooner.

## The checkout timeout

`checkout_timeout` sets the longest time that a call waits for a free connection. The default is 5000 ms.

When the wait passes, the call fails with `NoConnection`, an `Unavailable` error with the message "no database connection was free in time". The pool sends a `Refused` event.

While no connection is connected and the last connect failed, a call does not wait. It gets that connect error at once, as an `Unavailable` error.

## The query timeout

`query_timeout` sets the longest time that one query, or one command of a transaction, may take. The default is 5000 ms.

When the time passes, the client asks the server to cancel the query, and the call fails with `QueryTimeout`, a `Timeout` error. The message is "the query did not finish in time". When the server does not confirm the cancel, the message also says "the server did not confirm that it stopped".

A cancel that takes more than the cancel timeout, 2 seconds by default, stops, and the pool closes and replaces the connection. Each statement of a transaction has its own query timeout.

## What the pool does between calls

When a call gives back a connection, the pool rolls back a transaction that the call left open, before it hands the connection out again.

The pool also does a health check on each connection that was free and unused for a whole interval. A connection that a call used in the interval proved itself, so the check skips it.

A connection that fails the rollback or the health check is stopped, and a new connection takes its slot. A connection that lost its session goes to no call until it is connected again.

## Set the other times

Five more settings change the times of the pool. Each time is in milliseconds:

| Setting | Time | Default |
|---|---|---|
| `connect_timeout` | Longest time of each TCP connect, TLS answer and TLS handshake | 5000 |
| `setup_timeout` | Longest time of one setup: the TCP connect, TLS and the login together | 10_000 |
| `cancel_timeout` | Longest time of a cancel after a query timeout | 2000 |
| `health_check_interval` | Interval between health checks | 30_000 |
| `return_rollback_timeout` | Longest time of the rollback when a call gives back a connection | 5000 |

A value below 1 is an `InvalidConfig` error at `start` and at `supervised`, with the fault `InvalidConnectTimeout`, `InvalidSetupTimeout`, `InvalidCancelTimeout`, `InvalidHealthCheckInterval` or `InvalidReturnRollbackTimeout`. Nothing starts.

### A pool on a distant server <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/distant_server.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_postgres.{
  type Config, cancel_timeout, connect_timeout, health_check_interval, host,
  return_rollback_timeout, setup_timeout,
}

/// A pool on a server in another region: more time to connect and to log
/// in, less time for a cancel, and fewer health checks. Each time is in
/// milliseconds.
pub fn distant_server(config: Config) -> Config {
  config
  |> host("db.eu-west.example.com")
  |> connect_timeout(3000)
  |> setup_timeout(15_000)
  |> cancel_timeout(1000)
  |> health_check_interval(60_000)
  |> return_rollback_timeout(5000)
}
```

## Fixed times

These times are fixed in this version. No setting changes them.

| Time | Value |
|---|---|
| Longest time of a health check | 5 seconds |
| Longest time that a send waits while the server reads nothing | 5 seconds |
| Time that `stop` gives the calls that hold a connection | 5 seconds |

## Watch the pool

The pool events show how busy the pool is. A `Waiting(count)` event says that a call found no free connection, and how many calls wait. A `Refused(error)` event says that a call got no connection. Many `Waiting` events with a high count can mean that the pool is too small, or that calls hold their connections too long. The [connecting guide](connecting.md#pool-events) shows how to get the events.
