//// Tests for what the guides say about the SSL modes, against a real
//// PostgreSQL 16 server with SSL on (`fixtures/ssl_database`).
////
//// Some tests read the TLS alert reports that OTP's `ssl` application logs
//// for every pool of the BEAM, so this suite runs one test at a time.

import dream_postgres/client as postgres
import dream_postgres_client
import dream_test/matchers.{be_between, be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/clock
import fixtures/output_file
import fixtures/ssl_database.{matching_host, other_address, url}
import fixtures/test_database
import gleam/erlang/process
import gleam/list
import gleam/result
import gleam/string
import snippets/guide_connecting_private_ca.{connect_with_private_ca}

const ssl_sql = "SELECT ssl::text FROM pg_stat_ssl WHERE pid = pg_backend_pid()"

pub fn tests() -> TestSuite {
  describe("a real PostgreSQL 16 server with SSL on", [
    disable_tests(),
    require_tests(),
    untrusted_ca_tests(),
    trusted_ca_tests(),
  ])
}

fn disable_tests() {
  group("sslmode=disable", [
    it("connects without TLS", fn() {
      // Act
      let ssl =
        ssl_database.ssl_in_use(url(host: matching_host, sslmode: "disable"))

      // Assert
      ssl
      |> should
      |> be_equal(Ok(Ok(["false"])))
      |> or_fail_with("Expected a connection without TLS")
    }),
  ])
}

fn require_tests() {
  group("sslmode=require", [
    it("connects with TLS", fn() {
      // Act
      let ssl =
        ssl_database.ssl_in_use(url(host: matching_host, sslmode: "require"))

      // Assert
      ssl
      |> should
      |> be_equal(Ok(Ok(["true"])))
      |> or_fail_with("Expected a connection with TLS")
    }),
    it("check gives Ok(Nil)", fn() {
      // Act
      let checked = {
        use <- test_database.with_own_pools()
        postgres.from_url(url(host: matching_host, sslmode: "require"))
        |> result.map(postgres.check)
      }

      // Assert
      checked
      |> should
      |> be_equal(Ok(Ok(Nil)))
      |> or_fail_with("Expected Ok(Nil) from check over TLS")
    }),
    it("connects with TLS 1.3", fn() {
      // Act
      let version =
        ssl_database.query_texts(
          url(host: matching_host, sslmode: "require"),
          "SELECT version FROM pg_stat_ssl WHERE pid = pg_backend_pid()",
        )

      // Assert
      version
      |> should
      |> be_equal(Ok(Ok(["TLSv1.3"])))
      |> or_fail_with("Expected TLSv1.3")
    }),
    it("application_name from the URL reaches the server over TLS", fn() {
      // Act
      let name =
        ssl_database.query_texts(
          url(host: matching_host, sslmode: "require")
            <> "&application_name=billing",
          "SELECT current_setting('application_name')",
        )

      // Assert
      name
      |> should
      |> be_equal(Ok(Ok(["billing"])))
      |> or_fail_with("Expected the application name from the URL")
    }),
    it(
      "connects to an address the certificate does not name, from an unknown CA",
      fn() {
        // Act
        let ssl =
          ssl_database.ssl_in_use(url(host: other_address, sslmode: "require"))

        // Assert
        ssl
        |> should
        |> be_equal(Ok(Ok(["true"])))
        |> or_fail_with("Expected a connection with TLS and no check")
      },
    ),
  ])
}

fn untrusted_ca_tests() {
  group("the verify modes when the client does not trust the CA", [
    it("verify-full gives ConnectionUnavailable", fn() {
      // Act
      let ssl =
        ssl_database.ssl_in_use(url(host: matching_host, sslmode: "verify-full"))

      // Assert
      ssl
      |> should
      |> be_equal(Ok(Error(dream_postgres_client.ConnectionUnavailable)))
      |> or_fail_with("Expected ConnectionUnavailable")
    }),
    it("verify-ca gives ConnectionUnavailable", fn() {
      // Act
      let ssl =
        ssl_database.ssl_in_use(url(host: matching_host, sslmode: "verify-ca"))

      // Assert
      ssl
      |> should
      |> be_equal(Ok(Error(dream_postgres_client.ConnectionUnavailable)))
      |> or_fail_with("Expected ConnectionUnavailable")
    }),
    it("verify-full logs the reason as a notice", fn() {
      // Act
      let alerts =
        ssl_database.tls_alerts(fn() {
          ssl_database.ssl_in_use(url(
            host: matching_host,
            sslmode: "verify-full",
          ))
        })

      // Assert
      list.first(alerts)
      |> result.map(level_and_guide_line)
      |> should
      |> be_equal(Ok(#("notice", tls_notice_of_guide(0))))
      |> or_fail_with("Expected an Unknown CA notice")
    }),
    it("verify-full gives the error after about 2 seconds", fn() {
      // Arrange
      let started_at = clock.now_in_milliseconds()

      // Act
      let _ssl =
        ssl_database.ssl_in_use(url(host: matching_host, sslmode: "verify-full"))
      let elapsed = clock.now_in_milliseconds() - started_at

      // Assert
      elapsed
      |> should
      |> be_between(1500, 3500)
      |> or_fail_with("Expected the error after 1.5 to 3.5 seconds")
    }),
  ])
}

fn trusted_ca_tests() {
  group("the verify modes with the test CA in sslrootcert", [
    it("verify-full connects with TLS to the name of the certificate", fn() {
      // Act
      let ssl =
        ssl_with_test_ca(url(host: matching_host, sslmode: "verify-full"))

      // Assert
      ssl
      |> should
      |> be_equal(Ok(Ok(["true"])))
      |> or_fail_with("Expected a verified connection with TLS")
    }),
    it(
      "verify-full gives ConnectionUnavailable for an address the certificate does not name",
      fn() {
        // Act
        let ssl =
          ssl_with_test_ca(url(host: other_address, sslmode: "verify-full"))

        // Assert
        ssl
        |> should
        |> be_equal(Ok(Error(dream_postgres_client.ConnectionUnavailable)))
        |> or_fail_with("Expected ConnectionUnavailable")
      },
    ),
    it("verify-full logs a host name that does not match as a notice", fn() {
      // Act
      let alerts =
        ssl_database.tls_alerts(fn() {
          ssl_with_test_ca(url(host: other_address, sslmode: "verify-full"))
        })

      // Assert
      list.first(alerts)
      |> result.map(level_and_guide_line)
      |> should
      |> be_equal(Ok(#("notice", tls_notice_of_guide(1))))
      |> or_fail_with("Expected a Bad Certificate notice")
    }),
    it(
      "verify-ca connects with TLS to an address the certificate does not name",
      fn() {
        // Act
        let ssl =
          ssl_with_test_ca(url(host: other_address, sslmode: "verify-ca"))

        // Assert
        ssl
        |> should
        |> be_equal(Ok(Ok(["true"])))
        |> or_fail_with("Expected a connection with TLS and a chain check")
      },
    ),
    it("verify-ca connects with TLS to the name of the certificate", fn() {
      // Act
      let ssl = ssl_with_test_ca(url(host: matching_host, sslmode: "verify-ca"))

      // Assert
      ssl
      |> should
      |> be_equal(Ok(Ok(["true"])))
      |> or_fail_with("Expected a verified connection with TLS")
    }),
    it(
      "require with a CA file connects with TLS to an address the certificate does not name",
      fn() {
        // Act
        let ssl = ssl_with_test_ca(url(host: other_address, sslmode: "require"))

        // Assert
        ssl
        |> should
        |> be_equal(Ok(Ok(["true"])))
        |> or_fail_with("Expected a connection with TLS and a chain check")
      },
    ),
    it("a CA file of one pool does not change the CA list of other pools", fn() {
      // Act
      let connected = {
        use <- test_database.with_own_pools()
        let _pool =
          ssl_with_test_ca(url(host: matching_host, sslmode: "verify-full"))
        // The CA list of the system does not hold the test CA
        ssl_database.ssl_in_use(url(host: matching_host, sslmode: "verify-full"))
      }

      // Assert
      connected
      |> should
      |> be_equal(Ok(Error(dream_postgres_client.ConnectionUnavailable)))
      |> or_fail_with("Expected ConnectionUnavailable without the CA file")
    }),
    it(
      "connect_with_private_ca connects with TLS to the name of the certificate",
      fn() {
        // Arrange
        let assert Ok(config) =
          postgres.parse_config(
            process.new_name("ssl_test"),
            url(host: matching_host, sslmode: "disable"),
          )

        // Act
        let ssl = {
          use <- test_database.with_own_pools()
          connect_with_private_ca(config, ssl_database.ca_file)
          |> result.map(test_database.texts(_, ssl_sql))
        }

        // Assert
        ssl
        |> should
        |> be_equal(Ok(Ok(["true"])))
        |> or_fail_with("Expected a verified connection with TLS")
      },
    ),
    it("connect_with_private_ca answers as the output file shows", fn() {
      // Arrange
      let assert Ok(config) =
        postgres.parse_config(
          process.new_name("ssl_test"),
          url(host: matching_host, sslmode: "disable"),
        )

      // Act
      let answers = {
        use <- test_database.with_own_pools()
        [
          #(
            "connect_with_private_ca(config, \"test/fixtures/ssl/missing.crt\")",
            connect_with_private_ca(config, "test/fixtures/ssl/missing.crt")
              |> result.replace(Nil)
              |> string.inspect,
          ),
          #(
            "connect_with_private_ca(config, \"README.md\")",
            connect_with_private_ca(config, "README.md")
              |> result.replace(Nil)
              |> string.inspect,
          ),
        ]
      }

      // Assert
      output_file.calls(answers)
      |> should
      |> be_equal(output_file.read("guide_connecting_ca_file_errors"))
      |> or_fail_with("Expected the output file")
    }),
    it("from_url gives PoolStartExited for a CA file that does not exist", fn() {
      // Act
      let connected = {
        use <- test_database.with_own_pools()
        postgres.from_url(
          url(host: matching_host, sslmode: "verify-full")
          <> "&sslrootcert=test/fixtures/ssl/missing.crt",
        )
        |> result.replace(Nil)
      }

      // Assert
      connected
      |> should
      |> be_equal(Error(postgres.PoolStartExited))
      |> or_fail_with("Expected PoolStartExited")
    }),
  ])
}

// Starts a pool from `url` with the test CA in `sslrootcert`, asks the
// server whether the connection uses TLS, and stops the pool.
fn ssl_with_test_ca(
  url: String,
) -> Result(
  Result(List(String), dream_postgres_client.QueryError),
  postgres.FromUrlError,
) {
  ssl_database.ssl_in_use(url <> "&sslrootcert=" <> ssl_database.ca_file)
}

// Keeps the level of a TLS alert report, and writes its text as the
// connecting guide shows it: `...` in place of the text between
// "TLS client: " and " generated CLIENT ALERT: ", which names a line of
// OTP's source and changes from one OTP release to the next.
fn level_and_guide_line(alert: #(String, String)) -> #(String, String) {
  let #(level, text) = alert
  #(level, guide_line(text))
}

fn guide_line(text: String) -> String {
  case string.split_once(text, " generated CLIENT ALERT: ") {
    Ok(#(before, reason)) -> hide_source_line(text, before, reason)
    Error(Nil) -> text
  }
}

fn hide_source_line(text: String, before: String, reason: String) -> String {
  case string.starts_with(before, "TLS client: ") {
    True -> "TLS client: ... generated CLIENT ALERT: " <> reason
    False -> text
  }
}

// Gives the line at `index` (from 0) of the output file of the TLS notices
// that the connecting guide shows.
fn tls_notice_of_guide(index: Int) -> String {
  output_file.read("guide_connecting_tls_notices")
  |> string.split("\n")
  |> list.drop(index)
  |> list.first()
  |> result.unwrap("")
}
