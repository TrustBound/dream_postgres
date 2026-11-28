//// The options of a pool: TLS, the statement cache, the notices subject
//// and the pool events subject, with the mapping of each to the driver.

import dream_postgres/codec
import dream_postgres/config.{
  AuthorityCertificates, AuthorityFile, CacheStatements, CheckAuthority,
  CheckAuthorityAndHost, ConnectFailed, Connected, Disconnected, Free, Held,
  NoCertificateCheck, NoStatementCache, Reconnected, Refused, Replacing,
  Returned, Stopping, SystemAuthorities, TlsOff, TlsPreferred, TlsRequired,
  Waiting, cancel_timeout, connect_timeout, default_config,
  health_check_interval, return_rollback_timeout, setup_timeout,
}
import dream_postgres/driver/connection/event as connection_event
import dream_postgres/driver/connection/settings as connection_settings
import dream_postgres/driver/pool/pool_event
import dream_postgres/driver/pool/pool_failure
import dream_postgres/driver/transport
import dream_postgres/error
import dream_postgres/pool.{
  named_connection, start_pool, supervised, with_connection,
} as postgres_pool
import dream_postgres/query.{all, one, query, run_sql}
import dream_postgres/row.{single}
import dream_test/matchers.{
  be_equal, be_error, be_ok, contain, or_fail_with, should,
}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import driver/servers.{first_driver_server, server_without_tls}
import fixtures/driver_tls
import fixtures/postgres_failure
import fixtures/server_pools
import fixtures/server_reports
import gleam/erlang/process
import gleam/list
import gleam/result
import matchers/extract_driver_times.{extract_driver_times}
import matchers/extract_notice_message.{extract_notice_message}
import matchers/have_cause.{have_cause}
import matchers/have_reason.{have_reason}
import matchers/map_pool_event.{map_pool_event}
import matchers/map_server_notice.{map_server_notice}
import matchers/map_statement_cache.{map_statement_cache}
import matchers/map_tls.{map_tls}
import matchers/receive_all_messages.{receive_all_messages}
import matchers/receive_message.{receive_message}
import matchers/run_on_started_pool.{run_on_started_pool}
import matchers/run_on_supervised_pool.{run_on_supervised_pool}

/// The mapping of each option to the driver, with no server.
pub fn unit_tests() -> TestSuite {
  describe("the options of a pool, with no server", [
    tls_mapping_tests(),
    statement_cache_mapping_tests(),
    group("notices", [
      it("a notice report keeps its message", fn() {
        // Act and assert
        server_reports.unique_violation("NOTICE")
        |> should
        |> map_server_notice()
        |> extract_notice_message()
        |> be_equal("duplicate key value violates unique constraint")
        |> or_fail_with("Expected the message of the report")
      }),
    ]),
    pool_event_mapping_tests(),
    time_setting_tests(),
  ])
}

fn time_setting_tests() {
  group("the time settings", [
    it("the defaults reach the driver", fn() {
      // Act and assert
      default_config()
      |> should
      |> extract_driver_times()
      |> be_equal(#(5000, 10_000, 2000, 30_000, 5000))
      |> or_fail_with("Expected 5000, 10_000, 2000, 30_000 and 5000")
    }),
    it("connect_timeout reaches the transport of the driver", fn() {
      // Act and assert
      default_config()
      |> connect_timeout(3000)
      |> should
      |> extract_driver_times()
      |> be_equal(#(3000, 10_000, 2000, 30_000, 5000))
      |> or_fail_with("Expected the connect timeout 3000")
    }),
    it("setup_timeout reaches the connection of the driver", fn() {
      // Act and assert
      default_config()
      |> setup_timeout(15_000)
      |> should
      |> extract_driver_times()
      |> be_equal(#(5000, 15_000, 2000, 30_000, 5000))
      |> or_fail_with("Expected the setup timeout 15_000")
    }),
    it("cancel_timeout reaches the connection of the driver", fn() {
      // Act and assert
      default_config()
      |> cancel_timeout(1000)
      |> should
      |> extract_driver_times()
      |> be_equal(#(5000, 10_000, 1000, 30_000, 5000))
      |> or_fail_with("Expected the cancel timeout 1000")
    }),
    it("health_check_interval reaches the driver pool", fn() {
      // Act and assert
      default_config()
      |> health_check_interval(60_000)
      |> should
      |> extract_driver_times()
      |> be_equal(#(5000, 10_000, 2000, 60_000, 5000))
      |> or_fail_with("Expected the health check interval 60_000")
    }),
    it("return_rollback_timeout reaches the driver pool", fn() {
      // Act and assert
      default_config()
      |> return_rollback_timeout(7000)
      |> should
      |> extract_driver_times()
      |> be_equal(#(5000, 10_000, 2000, 30_000, 7000))
      |> or_fail_with("Expected the return rollback timeout 7000")
    }),
    ..list.flat_map(
      [
        #(
          "connect_timeout",
          connect_timeout(default_config(), 0),
          error.InvalidConnectTimeout(0),
        ),
        #(
          "setup_timeout",
          setup_timeout(default_config(), 0),
          error.InvalidSetupTimeout(0),
        ),
        #(
          "cancel_timeout",
          cancel_timeout(default_config(), -5),
          error.InvalidCancelTimeout(-5),
        ),
        #(
          "health_check_interval",
          health_check_interval(default_config(), 0),
          error.InvalidHealthCheckInterval(0),
        ),
        #(
          "return_rollback_timeout",
          return_rollback_timeout(default_config(), 0),
          error.InvalidReturnRollbackTimeout(0),
        ),
      ],
      fn(refused) {
        let #(setter_name, config, fault) = refused
        [
          it(setter_name <> " below 1 is InvalidConfig at start", fn() {
            // Act and assert
            config
            |> start_pool
            |> should
            |> be_error()
            |> have_cause()
            |> have_reason()
            |> be_equal(error.InvalidConfig(fault))
            |> or_fail_with("Expected InvalidConfig at start")
          }),
          it(setter_name <> " below 1 is InvalidConfig at supervised", fn() {
            // Act and assert
            config
            |> supervised(name: process.new_name("refused_time_setting"))
            |> should
            |> be_error()
            |> have_cause()
            |> have_reason()
            |> be_equal(error.InvalidConfig(fault))
            |> or_fail_with("Expected InvalidConfig at supervised")
          }),
        ]
      },
    )
  ])
}

fn tls_mapping_tests() {
  group("TLS", [
    it("TlsOff is no TLS", fn() {
      // Act and assert
      TlsOff
      |> should
      |> map_tls()
      |> be_equal(transport.NoTls)
      |> or_fail_with("Expected NoTls")
    }),
    it("TlsPreferred prefers TLS", fn() {
      // Act and assert
      TlsPreferred
      |> should
      |> map_tls()
      |> be_equal(transport.PreferTls)
      |> or_fail_with("Expected PreferTls")
    }),
    it("a direct TLS with no check negotiates directly", fn() {
      // Act and assert
      TlsRequired(check: NoCertificateCheck, direct: True)
      |> should
      |> map_tls()
      |> be_equal(transport.RequireTls(
        transport.NoCertificateCheck,
        transport.DirectNegotiation,
      ))
      |> or_fail_with("Expected RequireTls with no check, negotiated directly")
    }),
    it("a check of the system authorities asks the server first", fn() {
      // Act and assert
      TlsRequired(check: CheckAuthority(SystemAuthorities), direct: False)
      |> should
      |> map_tls()
      |> be_equal(transport.RequireTls(
        transport.CheckAuthority(transport.SystemAuthorities),
        transport.PostgresNegotiation,
      ))
      |> or_fail_with("Expected RequireTls with the system authorities")
    }),
    it("a check of the authority file and the host keeps the path", fn() {
      // Act and assert
      TlsRequired(
        check: CheckAuthorityAndHost(AuthorityFile("ca.crt")),
        direct: False,
      )
      |> should
      |> map_tls()
      |> be_equal(transport.RequireTls(
        transport.CheckAuthorityAndHost(transport.AuthorityFile("ca.crt")),
        transport.PostgresNegotiation,
      ))
      |> or_fail_with("Expected RequireTls with the authority file")
    }),
    it("a check of authority certificates keeps the certificates", fn() {
      // Act and assert
      TlsRequired(
        check: CheckAuthority(AuthorityCertificates([<<1, 2, 3>>])),
        direct: False,
      )
      |> should
      |> map_tls()
      |> be_equal(transport.RequireTls(
        transport.CheckAuthority(transport.AuthorityCertificates([<<1, 2, 3>>])),
        transport.PostgresNegotiation,
      ))
      |> or_fail_with("Expected RequireTls with the certificates")
    }),
  ])
}

fn statement_cache_mapping_tests() {
  group("the statement cache", [
    it("CacheStatements keeps its limit", fn() {
      // Act and assert
      CacheStatements(limit: 64)
      |> should
      |> map_statement_cache()
      |> be_equal(connection_settings.CacheStatements(limit: 64))
      |> or_fail_with("Expected CacheStatements(64)")
    }),
    it("NoStatementCache prepares unnamed statements", fn() {
      // Act and assert
      NoStatementCache
      |> should
      |> map_statement_cache()
      |> be_equal(connection_settings.UnnamedStatements)
      |> or_fail_with("Expected UnnamedStatements")
    }),
  ])
}

fn pool_event_mapping_tests() {
  group("pool events", [
    it("a member that connected is Connected", fn() {
      // Act and assert
      pool_event.MemberConnected(slot: 1)
      |> should
      |> map_pool_event("db", 5432)
      |> be_equal(Connected(slot: 1))
      |> or_fail_with("Expected Connected(1)")
    }),
    it("a member that lost its session is Disconnected with the reason", fn() {
      // Act and assert
      pool_event.MemberDisconnected(
        slot: 2,
        error: connection_event.ConnectionLost(
          connection_event.ClosedAfterDeadline,
        ),
      )
      |> should
      |> map_pool_event("db", 5432)
      |> be_equal(Disconnected(
        slot: 2,
        reason: postgres_failure.without_query(error.ConnectionLost(
          error.ClosedAfterDeadline,
        )),
      ))
      |> or_fail_with("Expected Disconnected(2) with ClosedAfterDeadline")
    }),
    it("a member that connected again is Reconnected", fn() {
      // Act and assert
      pool_event.MemberReconnected(slot: 3)
      |> should
      |> map_pool_event("db", 5432)
      |> be_equal(Reconnected(slot: 3))
      |> or_fail_with("Expected Reconnected(3)")
    }),
    it("a failed connect is ConnectFailed with the reason", fn() {
      // Act and assert
      pool_event.MemberConnectFailed(
        slot: 0,
        error: connection_event.SetupTimedOut,
      )
      |> should
      |> map_pool_event("db", 5432)
      |> be_equal(ConnectFailed(
        slot: 0,
        error: postgres_failure.without_query(error.ConnectFailed(
          error.SetupTimedOut,
        )),
      ))
      |> or_fail_with("Expected ConnectFailed(0) with SetupTimedOut")
    }),
    it("a member that is replaced is Replacing", fn() {
      // Act and assert
      pool_event.MemberReplacing(slot: 1)
      |> should
      |> map_pool_event("db", 5432)
      |> be_equal(Replacing(slot: 1))
      |> or_fail_with("Expected Replacing(1)")
    }),
    it("a free member is Free", fn() {
      // Act and assert
      pool_event.MemberFree(slot: 1)
      |> should
      |> map_pool_event("db", 5432)
      |> be_equal(Free(slot: 1))
      |> or_fail_with("Expected Free(1)")
    }),
    it("a hold that waits is Waiting with the count", fn() {
      // Act and assert
      pool_event.HoldWaiting(waiting: 4)
      |> should
      |> map_pool_event("db", 5432)
      |> be_equal(Waiting(count: 4))
      |> or_fail_with("Expected Waiting(4)")
    }),
    it("a held member is Held", fn() {
      // Act and assert
      pool_event.MemberHeld(slot: 2)
      |> should
      |> map_pool_event("db", 5432)
      |> be_equal(Held(slot: 2))
      |> or_fail_with("Expected Held(2)")
    }),
    it("a returned member is Returned", fn() {
      // Act and assert
      pool_event.MemberReturned(slot: 2)
      |> should
      |> map_pool_event("db", 5432)
      |> be_equal(Returned(slot: 2))
      |> or_fail_with("Expected Returned(2)")
    }),
    it("a refused hold is Refused with the reason", fn() {
      // Act and assert
      pool_event.HoldRefused(error: pool_failure.HoldDeadlinePassed)
      |> should
      |> map_pool_event("db", 5432)
      |> be_equal(
        Refused(error: postgres_failure.without_query(error.NoConnection)),
      )
      |> or_fail_with("Expected Refused with NoConnection")
    }),
    it("a pool that stops is Stopping", fn() {
      // Act and assert
      pool_event.PoolStopping
      |> should
      |> map_pool_event("db", 5432)
      |> be_equal(Stopping)
      |> or_fail_with("Expected Stopping")
    }),
  ])
}

/// The options of a pool on the driver servers.
pub fn tests() -> TestSuite {
  describe("the options of a pool, on a server", [
    tls_tests(),
    statement_cache_tests(),
    notice_tests(),
    pool_event_tests(),
  ])
}

fn tls_tests() {
  group("TLS", [
    it("TlsRequired with the test authority connects", fn() {
      // Arrange
      let required =
        TlsRequired(
          check: CheckAuthorityAndHost(AuthorityFile(
            driver_tls.certificate_authority,
          )),
          direct: False,
        )

      // Act and assert
      server_pools.config(first_driver_server.port)
      |> config.tls(required)
      |> should
      |> run_on_started_pool(fn(connection) {
        query("SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()")
        |> one(single(codec.bool), connection)
      })
      |> be_ok()
      |> be_equal(True)
      |> or_fail_with("Expected a connection over TLS")
    }),
    it("TlsOff connects with no TLS", fn() {
      // Act and assert
      server_pools.config(first_driver_server.port)
      |> config.tls(TlsOff)
      |> should
      |> run_on_started_pool(fn(connection) {
        query("SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()")
        |> one(single(codec.bool), connection)
      })
      |> be_ok()
      |> be_equal(False)
      |> or_fail_with("Expected a connection with no TLS")
    }),
    it("the default refuses a server with no TLS", fn() {
      // Act and assert
      config.default_config()
      |> config.port(server_without_tls)
      |> config.pool_size(1)
      |> should
      |> run_on_started_pool(fn(connection) {
        query("SELECT 1") |> all(single(codec.int), connection)
      })
      |> be_error()
      |> have_cause()
      |> have_reason()
      |> be_equal(error.ConnectFailed(error.TlsFailed(error.ServerHasNoTls)))
      |> or_fail_with("Expected the TLS failure ServerHasNoTls")
    }),
  ])
}

fn statement_cache_tests() {
  group("the statement cache", [
    it("NoStatementCache runs queries with no named statement", fn() {
      // Act and assert
      server_pools.config(first_driver_server.port)
      |> config.statement_cache(NoStatementCache)
      |> should
      |> run_on_started_pool(fn(connection) {
        with_connection(connection, fn(held) {
          use _rows <- result.try(
            query("SELECT 1") |> all(single(codec.int), held),
          )
          query("SELECT count(*)::int FROM pg_prepared_statements")
          |> one(single(codec.int), held)
        })
      })
      |> be_ok()
      |> be_ok()
      |> be_equal(0)
      |> or_fail_with("Expected no named statement on the connection")
    }),
  ])
}

fn notice_tests() {
  group("notices", [
    it("the NOTICE of a statement reaches the subject", fn() {
      // Arrange
      let notices = process.new_subject()

      // Act and assert
      server_pools.config(first_driver_server.port)
      |> config.notices(notices)
      |> should
      |> run_on_started_pool(fn(connection) {
        run_sql("DROP TABLE IF EXISTS missing_table_x", connection)
      })
      |> receive_message(notices, within: 5000)
      |> extract_notice_message()
      |> be_equal("table \"missing_table_x\" does not exist, skipping")
      |> or_fail_with("Expected the notice of the DROP")
    }),
  ])
}

fn pool_event_tests() {
  group("pool events", [
    it("Connected arrives after the start", fn() {
      // Arrange
      let events = process.new_subject()

      // Act and assert
      server_pools.config(first_driver_server.port)
      |> config.pool_size(1)
      |> config.pool_events(events)
      |> should
      |> run_on_started_pool(fn(connection) {
        query("SELECT 1") |> all(single(codec.int), connection)
      })
      |> receive_all_messages(events, within: 100)
      |> contain(Connected(slot: 0))
      |> or_fail_with("Expected Connected(0)")
    }),
    it("Held arrives when a query holds the connection", fn() {
      // Arrange
      let events = process.new_subject()

      // Act and assert
      server_pools.config(first_driver_server.port)
      |> config.pool_size(1)
      |> config.pool_events(events)
      |> should
      |> run_on_started_pool(fn(connection) {
        query("SELECT 1") |> all(single(codec.int), connection)
      })
      |> receive_all_messages(events, within: 100)
      |> contain(Held(slot: 0))
      |> or_fail_with("Expected Held(0)")
    }),
    it("Returned arrives when the query ends", fn() {
      // Arrange
      let events = process.new_subject()

      // Act and assert
      server_pools.config(first_driver_server.port)
      |> config.pool_size(1)
      |> config.pool_events(events)
      |> should
      |> run_on_started_pool(fn(connection) {
        query("SELECT 1") |> all(single(codec.int), connection)
      })
      |> receive_all_messages(events, within: 100)
      |> contain(Returned(slot: 0))
      |> or_fail_with("Expected Returned(0)")
    }),
    it("Stopping arrives before stop returns", fn() {
      // Arrange
      let events = process.new_subject()

      // Act and assert
      server_pools.config(first_driver_server.port)
      |> config.pool_size(1)
      |> config.pool_events(events)
      |> should
      |> run_on_started_pool(fn(connection) {
        query("SELECT 1") |> all(single(codec.int), connection)
      })
      |> receive_all_messages(events, within: 0)
      |> contain(Stopping)
      |> or_fail_with("Expected Stopping")
    }),
    it("a stop of a pool that stopped already does nothing", fn() {
      // Act and assert
      server_pools.config(first_driver_server.port)
      |> config.pool_size(1)
      |> should
      |> run_on_started_pool(postgres_pool.stop_pool)
      |> be_equal(Nil)
      |> or_fail_with("Expected the second stop to do nothing")
    }),
    it("a supervised pool sends its events", fn() {
      // Arrange
      let events = process.new_subject()
      let name = process.new_name("supervised_pool_events")

      // Act and assert
      server_pools.config(first_driver_server.port)
      |> config.pool_size(1)
      |> config.pool_events(events)
      |> should
      |> run_on_supervised_pool(name, fn(_supervisor) {
        all(query("SELECT 1"), single(codec.int), named_connection(name))
      })
      |> receive_all_messages(events, within: 200)
      |> contain(Held(slot: 0))
      |> or_fail_with("Expected Held(0) from the supervised pool")
    }),
  ])
}
