//// `config_from_url`: the config of each form of a valid URL, the typed
//// fault of each URL that is not valid, and messages with no password. A
//// config holds a function, which two configs do not share, so configs
//// are compared as the text that `string.inspect` prints.

import dream_errors.{Invalid}
import dream_postgres.{config_from_url}
import dream_postgres/error.{InvalidConfig, InvalidDatabaseUrl, PostgresError}
import dream_test/matchers.{be_equal, be_error, be_ok, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/database_urls.{type ConfigExample, type FaultExample}
import gleam/list
import gleam/option.{None}
import gleam/string
import matchers/extract_printed.{extract_printed}
import matchers/have_message.{have_message}
import matchers/not_contain_text.{not_contain_text}

/// The database URL tests, with no database.
pub fn tests() -> TestSuite {
  describe("config_from_url", [
    group(
      "a valid URL gives its config",
      list.map(database_urls.configs(), fn(example: ConfigExample) {
        it(example.url, fn() {
          // Act and assert
          config_from_url(example.url)
          |> should
          |> be_ok()
          |> extract_printed()
          |> be_equal(string.inspect(example.config))
          |> or_fail_with("Expected the config of " <> example.url)
        })
      }),
    ),
    group(
      "a URL that is not valid gives its typed fault",
      list.map(database_urls.faults(), fn(example: FaultExample) {
        it(example.url, fn() {
          // Act and assert
          config_from_url(example.url)
          |> should
          |> be_error()
          |> be_equal(Invalid(
            "the config is not valid: the database URL is not valid: "
              <> example.message,
            PostgresError(
              query_name: None,
              sql: None,
              reason: InvalidConfig(InvalidDatabaseUrl(example.fault)),
            ),
          ))
          |> or_fail_with("Expected the fault of " <> example.url)
        })
      }),
    ),
    it("the message of a fault holds no password", fn() {
      // Act and assert
      config_from_url("postgres://ada:hunter2@db.example.com:0/app")
      |> should
      |> be_error()
      |> have_message()
      |> not_contain_text("hunter2")
      |> or_fail_with("Expected no password in the message")
    }),
  ])
}
