//// Tests for the snippets of the connecting guide
//// (docs/guides/connecting.md). Each test runs a snippet and asserts the
//// exact value that the guide shows. The "with a database" tests run
//// queries on the test PostgreSQL server. The other pools start on a local
//// port where no database listens.

import dream_postgres/client as postgres
import dream_postgres_client
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/database
import fixtures/database_url
import fixtures/output_file
import fixtures/test_database
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
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
    it("explains the URLs of the output file", fn() {
      // Arrange
      let urls = [
        "postgresql://app:secret@db.example.com/app?sslmode=require&channel_binding=require",
        "postgresql://app:secret@db.example.com/app?sslmode=prefer",
        "postgresql://app:secret@db.example.com/app?sslmod=require",
        "postgresql://app:p@ss@db.example.com/app",
        "postgresql://app:secret@db.example.com:5432",
        "mysql://app:secret@db.example.com/app",
        "db.example.com:5432/app",
      ]

      // Act
      let explained =
        list.map(urls, fn(url) {
          case explain_url(url) {
            Error(message) -> #(url, message)
            Ok(Nil) -> #(url, "Ok(Nil)")
          }
        })

      // Assert
      output_file.calls(explained)
      |> should
      |> be_equal(output_file.read("guide_connecting_explain"))
      |> or_fail_with("Expected the output file")
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
    it("pool_config gives the values of the output file", fn() {
      // Arrange
      let url =
        "postgresql://app:secret@[2001:db8::10]:6432/app?sslmode=verify-full&application_name=billing"

      // Act
      let config =
        guide_connecting_pool_config.pool_config(
          process.new_name("guide_test"),
          url,
          30,
        )

      // Assert
      config
      |> result.map(fn(config) {
        "pool_config(name, "
        <> string.inspect(url)
        <> ", 30)\n  host:                  "
        <> string.inspect(config.host)
        <> "\n  port:                  "
        <> int.to_string(config.port)
        <> "\n  ssl:                   "
        <> string.inspect(config.ssl)
        <> "\n  ip_version:            "
        <> string.inspect(config.ip_version)
        <> "\n  connection_parameters: "
        <> string.inspect(config.connection_parameters)
        <> "\n  pool_size:             "
        <> int.to_string(config.pool_size)
        <> "\n"
      })
      |> should
      |> be_equal(Ok(output_file.read("guide_connecting_pool_config")))
      |> or_fail_with("Expected the output file")
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
        #(
          "db.internal",
          "myapp",
          Some("secret"),
          20,
          dream_postgres_client.SslVerified,
          [
            #("application_name", "myapp-web"),
          ],
        ),
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
      |> be_equal(Ok(Error(dream_postgres_client.ConnectionUnavailable)))
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
        dream_postgres_client.SslDisabled,
        dream_postgres_client.Ipv4,
      ))
      |> or_fail_with("Expected the Pog defaults")
    }),
    it("sslmode=verify-ca gives SslVerifiedChainOnly, with no host check", fn() {
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
      |> be_equal(Ok(dream_postgres_client.SslVerifiedChainOnly))
      |> or_fail_with("Expected SslVerifiedChainOnly")
    }),
    it("host does not set IPv6 for an IPv6 address", fn() {
      // Act
      let config =
        postgres.new(process.new_name("guide_test"))
        |> postgres.host("2001:db8::10")

      // Assert
      config.ip_version
      |> should
      |> be_equal(dream_postgres_client.Ipv4)
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
    it("the server shows the application_name of the output file", fn() {
      // Act
      let answer =
        from_url_and_select(
          "?application_name=billing",
          "SELECT current_setting('application_name')",
        )

      // Assert
      answer
      |> should
      |> be_equal(output_file.read("guide_connecting_application_name"))
      |> or_fail_with("Expected the output file")
    }),
    it("the server applies the parameters of the output file", fn() {
      // Act
      let answer =
        from_url_and_select(
          "?search_path=app&timezone=UTC&application_name=billing",
          "SELECT current_setting('search_path') || '|' || current_setting('timezone') || '|' || current_setting('application_name')",
        )

      // Assert
      answer
      |> should
      |> be_equal(output_file.read("guide_connecting_server_parameters"))
      |> or_fail_with("Expected the output file")
    }),
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

// Starts a pool from the test server URL with the query string `query`,
// runs `sql` (a query that returns one text column) and stops the pool.
// Gives the URL, the query and the answer as the guide shows them.
fn from_url_and_select(query: String, sql: String) -> String {
  let url = test_database.url() <> query
  let answer = {
    use <- test_database.with_own_pools()
    postgres.from_url(url)
    |> result.map(test_database.texts(_, sql))
  }
  let shown = case answer {
    Ok(Ok([value])) -> string.inspect(value)
    other -> string.inspect(other)
  }
  output_file.calls([
    #("from_url(" <> string.inspect(url) <> ")\n" <> sql, shown),
  ])
}
