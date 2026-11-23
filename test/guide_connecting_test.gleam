//// Tests for the snippets of the connecting guide
//// (docs/guides/connecting.md). Each test runs a snippet and asserts the
//// exact value that the guide shows. The "with a database" tests run
//// queries on the test PostgreSQL server. The other pools start on a local
//// port where no database listens.

import dream_postgres/client as postgres
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/database
import fixtures/database_url
import fixtures/test_database
import gleam/erlang/process
import gleam/option.{Some}
import gleam/result
import pog
import snippets/guide_connecting_builder_ssl
import snippets/guide_connecting_explain_url_error.{explain}
import snippets/guide_connecting_pool_config
import snippets/guide_connecting_supervised

fn explain_url(url: String) -> Result(Nil, String) {
  postgres.parse_config(process.new_name("guide_test"), url)
  |> result.replace(Nil)
  |> result.map_error(explain)
}

pub fn tests() -> TestSuite {
  describe("connecting guide", [
    with_database_tests(),
    explain_tests(),
    pool_tests(),
    pitfall_tests(),
  ])
}

fn explain_tests() {
  group("explain", [
    it("explains a parameter from a hosting provider", fn() {
      // Act
      let explained =
        explain_url(
          "postgresql://app:secret@db.example.com/app?sslmode=require&channel_binding=require",
        )

      // Assert
      explained
      |> should
      |> be_equal(Error(
        "DATABASE_URL has the parameter channel_binding. Remove it.",
      ))
      |> or_fail_with("Expected the channel_binding message")
    }),
    it("explains sslmode=prefer", fn() {
      // Act
      let explained =
        explain_url("postgresql://app:secret@db.example.com/app?sslmode=prefer")

      // Assert
      explained
      |> should
      |> be_equal(Error(
        "DATABASE_URL has sslmode=prefer. Use disable, require or verify-full.",
      ))
      |> or_fail_with("Expected the sslmode message")
    }),
    it("explains a password with an @ that is not encoded", fn() {
      // Act
      let explained = explain_url("postgresql://app:p@ss@db.example.com/app")

      // Assert
      explained
      |> should
      |> be_equal(Error(
        "DATABASE_URL is not a URL. Percent-encode @, :, / and # in the password.",
      ))
      |> or_fail_with("Expected the MalformedUrl message")
    }),
    it("explains a URL with no database name", fn() {
      // Act
      let explained = explain_url("postgresql://app:secret@db.example.com:5432")

      // Assert
      explained
      |> should
      |> be_equal(Error("DATABASE_URL has no database name"))
      |> or_fail_with("Expected the MissingDatabase message")
    }),
    it("explains a URL with another scheme", fn() {
      // Act
      let explained = explain_url("mysql://app:secret@db.example.com/app")

      // Assert
      explained
      |> should
      |> be_equal(Error("DATABASE_URL has the scheme mysql, not postgresql"))
      |> or_fail_with("Expected the UnsupportedScheme message")
    }),
    it("explains a URL without a scheme", fn() {
      // Act
      let explained = explain_url("db.example.com:5432/app")

      // Assert
      explained
      |> should
      |> be_equal(Error(
        "DATABASE_URL has the scheme db.example.com, not postgresql",
      ))
      |> or_fail_with("Expected the scheme to be the host")
    }),
    it("reads an encoded password", fn() {
      // Act
      let password =
        postgres.parse_config(
          process.new_name("guide_test"),
          "postgresql://app:p%40ss%2Fw0rd@db.example.com/app",
        )
        |> result.map(fn(config) { config.password })

      // Assert
      password
      |> should
      |> be_equal(Ok(Some("p@ss/w0rd")))
      |> or_fail_with("Expected the decoded password")
    }),
  ])
}

fn pool_tests() {
  group("pool", [
    it("pool_config reads SSL, IPv6 and the application name", fn() {
      // Act
      let config =
        guide_connecting_pool_config.pool_config(
          process.new_name("guide_test"),
          "postgresql://app:secret@[2001:db8::10]:6432/app?sslmode=verify-full&application_name=billing",
          30,
        )

      // Assert
      config
      |> result.map(fn(config) {
        #(
          config.host,
          config.port,
          config.ssl,
          config.ip_version,
          config.connection_parameters,
          config.pool_size,
        )
      })
      |> should
      |> be_equal(
        Ok(#(
          "2001:db8::10",
          6432,
          pog.SslVerified,
          pog.Ipv6,
          [#("application_name", "billing")],
          30,
        )),
      )
      |> or_fail_with("Expected every value of the URL")
    }),
    it("connect_pool starts a pool when no database listens", fn() {
      // Act
      let connected =
        guide_connecting_pool_config.connect_pool(
          database_url.unused_database_url(),
          5,
        )

      // Assert
      result.is_ok(connected)
      |> should
      |> be_equal(True)
      |> or_fail_with("Expected the pool to start")
    }),
    it("production_config sets SSL and the application name", fn() {
      // Act
      let config =
        guide_connecting_builder_ssl.production_config(
          process.new_name("guide_test"),
          "db.internal",
          "secret",
        )

      // Assert
      #(
        config.host,
        config.user,
        config.password,
        config.pool_size,
        config.ssl,
        config.connection_parameters,
      )
      |> should
      |> be_equal(
        #("db.internal", "myapp", Some("secret"), 20, pog.SslVerified, [
          #("application_name", "myapp-web"),
        ]),
      )
      |> or_fail_with("Expected every value of the builder")
    }),
    it("start_supervised gives a connection to the named pool", fn() {
      // Act
      let answer =
        guide_connecting_supervised.start_supervised(
          database_url.unused_database_url(),
        )
        |> result.map(database.run_select_one)

      // Assert
      answer
      |> should
      |> be_equal(Ok(Error(pog.ConnectionUnavailable)))
      |> or_fail_with("Expected a query on the named pool")
    }),
    it("start_supervised explains a bad URL", fn() {
      // Act
      let started =
        guide_connecting_supervised.start_supervised("postgresql://app@db/")

      // Assert
      started
      |> result.replace(Nil)
      |> should
      |> be_equal(Error("DATABASE_URL has no database name"))
      |> or_fail_with("Expected the MissingDatabase message")
    }),
  ])
}

fn pitfall_tests() {
  group("pitfalls", [
    it("new keeps the Pog defaults the guide lists", fn() {
      // Act
      let config = postgres.new(process.new_name("guide_test"))

      // Assert
      #(
        config.host,
        config.port,
        config.database,
        config.user,
        config.password,
        config.pool_size,
        config.ssl,
        config.ip_version,
      )
      |> should
      |> be_equal(#(
        "127.0.0.1",
        5432,
        "postgres",
        "postgres",
        option.None,
        10,
        pog.SslDisabled,
        pog.Ipv4,
      ))
      |> or_fail_with("Expected the Pog defaults")
    }),
    it("sslmode=verify-ca gives SslVerified, as verify-full does", fn() {
      // Act
      let ssl =
        postgres.parse_config(
          process.new_name("guide_test"),
          "postgresql://app:secret@10.0.0.5/app?sslmode=verify-ca",
        )
        |> result.map(fn(config) { config.ssl })

      // Assert
      ssl
      |> should
      |> be_equal(Ok(pog.SslVerified))
      |> or_fail_with("Expected SslVerified")
    }),
    it("host does not set IPv6 for an IPv6 address", fn() {
      // Act
      let config =
        postgres.new(process.new_name("guide_test"))
        |> postgres.host("2001:db8::10")

      // Assert
      config.ip_version
      |> should
      |> be_equal(pog.Ipv4)
      |> or_fail_with("Expected the builder to keep Ipv4")
    }),
    it("connect with a pool name in use returns an error", fn() {
      // Arrange
      let config =
        postgres.new(process.new_name("guide_test"))
        |> postgres.port(database_url.unused_port())
      let assert Ok(_first) = postgres.connect(config)

      // Act
      let second = postgres.connect(config)

      // Assert
      result.is_error(second)
      |> should
      |> be_equal(True)
      |> or_fail_with("Expected the second pool not to start")
    }),
    it("parse_config keeps the Pog default pool size of 10", fn() {
      // Act
      let pool_size =
        postgres.parse_config(
          process.new_name("guide_test"),
          "postgresql://app:secret@db.example.com/app",
        )
        |> result.map(fn(config) { config.pool_size })

      // Assert
      pool_size
      |> should
      |> be_equal(Ok(10))
      |> or_fail_with("Expected the Pog default of 10 from parse_config")
    }),
  ])
}

fn with_database_tests() {
  group("with a database", [
    it("connect_pool gives a pool that runs a query", fn() {
      // Act
      let user = {
        use <- test_database.with_own_pools()
        guide_connecting_pool_config.connect_pool(test_database.url(), 2)
        |> result.map(test_database.texts(_, "SELECT current_user::text"))
      }

      // Assert
      user
      |> should
      |> be_equal(Ok(Ok([test_database.config().user])))
      |> or_fail_with("Expected the user of the test database")
    }),
    it("start_supervised gives a connection that runs a query", fn() {
      // Act
      let user = {
        use <- test_database.with_own_pools()
        guide_connecting_supervised.start_supervised(test_database.url())
        |> result.map(test_database.texts(_, "SELECT current_user::text"))
      }

      // Assert
      user
      |> should
      |> be_equal(Ok(Ok([test_database.config().user])))
      |> or_fail_with("Expected the user of the test database")
    }),
  ])
}
