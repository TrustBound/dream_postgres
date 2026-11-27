//// The dream_errors value of each reason, and the accessors.

import dream_errors.{
  Conflict, Failed, Invalid, NotFound, Retry, Timeout, Unavailable,
}
import dream_postgres/error.{PostgresError, ServerError}
import dream_postgres/internal/cell
import dream_postgres/posix
import dream_postgres/sql_state
import dream_postgres/transaction
import dream_test/matchers.{be_equal, be_none, be_some, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/postgres_failure
import fixtures/server_error
import fixtures/server_reports
import gleam/json
import gleam/option.{None, Some}
import gleam/otp/actor

pub fn tests() -> TestSuite {
  describe("error", [
    group("to_dream_error of each reason", [
      it("a host that is not found is Unavailable", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.ConnectFailed(error.HostNotFound("db.example")),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Unavailable("the host db.example was not found", failure))
        |> or_fail_with(
          "Expected Unavailable with the message: the host db.example was not found",
        )
      }),
      it("a refused connection is Unavailable", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.ConnectFailed(error.ConnectionRefused("localhost", 5432)),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Unavailable(
          "localhost:5432 refused the connection",
          failure,
        ))
        |> or_fail_with(
          "Expected Unavailable with the message: localhost:5432 refused the connection",
        )
      }),
      it("a connect timeout is Unavailable", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.ConnectFailed(error.ConnectTimedOut("localhost", 5432)),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Unavailable(
          "localhost:5432 did not answer in time",
          failure,
        ))
        |> or_fail_with(
          "Expected Unavailable with the message: localhost:5432 did not answer in time",
        )
      }),
      it("a server with no TLS is Unavailable", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.ConnectFailed(error.TlsFailed(error.ServerHasNoTls)),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Unavailable(
          "the TLS handshake failed: the server does not offer TLS",
          failure,
        ))
        |> or_fail_with(
          "Expected Unavailable with the message: the TLS handshake failed: the server does not offer TLS",
        )
      }),
      it("an unknown authority is Unavailable", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.ConnectFailed(error.TlsFailed(error.UnknownAuthority)),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Unavailable(
          "the TLS handshake failed: no trusted authority signed the certificate",
          failure,
        ))
        |> or_fail_with(
          "Expected Unavailable with the message: the TLS handshake failed: no trusted authority signed the certificate",
        )
      }),
      it("an expired certificate is Unavailable", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.ConnectFailed(error.TlsFailed(error.CertificateExpired)),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Unavailable(
          "the TLS handshake failed: the certificate expired",
          failure,
        ))
        |> or_fail_with(
          "Expected Unavailable with the message: the TLS handshake failed: the certificate expired",
        )
      }),
      it("another TLS alert is Unavailable", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.ConnectFailed(
              error.TlsFailed(error.TlsAlert("bad record mac")),
            ),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Unavailable(
          "the TLS handshake failed: bad record mac",
          failure,
        ))
        |> or_fail_with(
          "Expected Unavailable with the message: the TLS handshake failed: bad record mac",
        )
      }),
      it("a refused login is Unavailable", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.ConnectFailed(
              error.LoginRefused(server_error.with_sql_state(
                sql_state.InvalidPassword,
                None,
              )),
            ),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Unavailable(
          "the database refused the login: the message (28P01)",
          failure,
        ))
        |> or_fail_with(
          "Expected Unavailable with the message: the database refused the login: the message (28P01)",
        )
      }),
      it("an unsupported login method is Unavailable", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.ConnectFailed(error.UnsupportedLoginMethod("gss")),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Unavailable(
          "the server asks for the login method gss, which is not supported",
          failure,
        ))
        |> or_fail_with(
          "Expected Unavailable with the message: the server asks for the login method gss, which is not supported",
        )
      }),
      it("an OS error at connect is Unavailable", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.ConnectFailed(error.OsRefused(posix.Econnrefused)),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Unavailable(
          "the operating system refused the connection (econnrefused)",
          failure,
        ))
        |> or_fail_with(
          "Expected Unavailable with the message: the operating system refused the connection (econnrefused)",
        )
      }),
      it("a connection closed after a deadline is Unavailable", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.ConnectionLost(
            error.ClosedAfterDeadline,
          ))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Unavailable(
          "the connection was closed after a deadline passed, because the cancel of that query was not confirmed",
          failure,
        ))
        |> or_fail_with(
          "Expected Unavailable with the message about the close after a deadline",
        )
      }),
      it("a connection the server closed is Unavailable", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.ConnectionLost(
            error.ClosedByServer,
          ))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Unavailable("the database closed the connection", failure))
        |> or_fail_with(
          "Expected Unavailable with the message: the database closed the connection",
        )
      }),
      it("a reset connection is Unavailable", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.ConnectionLost(error.Reset))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Unavailable("the connection was reset", failure))
        |> or_fail_with(
          "Expected Unavailable with the message: the connection was reset",
        )
      }),
      it("an OS error on the socket is Unavailable", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.ConnectionLost(error.OsError(posix.Ehostunreach)),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Unavailable("the connection failed (ehostunreach)", failure))
        |> or_fail_with(
          "Expected Unavailable with the message: the connection failed (ehostunreach)",
        )
      }),
      it("no free connection is Unavailable", fn() {
        // Arrange
        let failure = postgres_failure.with_reason(error.NoConnection)

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Unavailable(
          "no database connection was free in time",
          failure,
        ))
        |> or_fail_with(
          "Expected Unavailable with the message: no database connection was free in time",
        )
      }),
      it("a query timeout is Timeout", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.QueryTimeout(
            stopped_on_server: True,
          ))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Timeout("the query did not finish in time", failure))
        |> or_fail_with(
          "Expected Timeout with the message: the query did not finish in time",
        )
      }),
      it("a protocol violation is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.ProtocolViolation(
            "unknown message type 33",
          ))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "the server broke the protocol: unknown message type 33",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: the server broke the protocol: unknown message type 33",
        )
      }),
      it("a parameter count mismatch is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.ParameterCountMismatch(2, 1))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "the query has 2 parameters, and 1 were given",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: the query has 2 parameters, and 1 were given",
        )
      }),
      it("a parameter type mismatch is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.ParameterTypeMismatch(
            1,
            "int4",
            "text",
          ))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "parameter $1 is int4, and the query gives it with the text codec",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: parameter $1 is int4, and the query gives it with the text codec",
        )
      }),
      it("a column count mismatch is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.ColumnCountMismatch(2, 3))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "the row reader reads 2 columns, and the query returns 3",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: the row reader reads 2 columns, and the query returns 3",
        )
      }),
      it("a column type mismatch is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.ColumnTypeMismatch(
            3,
            "published",
            "bool",
            "int",
          ))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "column 3 (published) is bool, and the query reads it with the int codec",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: column 3 (published) is bool, and the query reads it with the int codec",
        )
      }),
      it("a column position out of range is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.NoColumnAtPosition(4, 3))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "the row reader reads column 4, and the query returns 3 columns",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: the row reader reads column 4, and the query returns 3 columns",
        )
      }),
      it("a missing column name is Failed", fn() {
        // Arrange
        let failure = postgres_failure.with_reason(error.NoColumnNamed("title"))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed("the query returns no column named title", failure))
        |> or_fail_with(
          "Expected Failed with the message: the query returns no column named title",
        )
      }),
      it("an ambiguous column name is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.AmbiguousColumnName("id", 2))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "2 columns are named id, so the row reader cannot read it by name",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: 2 columns are named id, so the row reader cannot read it by name",
        )
      }),
      it("a column read twice is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.ColumnReadTwice(1, "id"))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "the row reader reads column 1 (id) more than one time",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: the row reader reads column 1 (id) more than one time",
        )
      }),
      it("mixed column readers are Failed", fn() {
        // Arrange
        let failure = postgres_failure.with_reason(error.MixedColumnReaders)

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "the row reader mixes column with column_at or column_named",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: the row reader mixes column with column_at or column_named",
        )
      }),
      it("a statement that changes two times is Retry", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.StatementChangedDuringRun)

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Retry(
          "the statement changed during the run, because its tables or types changed",
          failure,
          None,
        ))
        |> or_fail_with(
          "Expected Retry with the message: the statement changed during the run, because its tables or types changed",
        )
      }),
      it("a reader that depends on a value is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.ReaderDependsOnValue(2))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "read 2 of the row reader chose its column or codec from a value it read",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: read 2 of the row reader chose its column or codec from a value it read",
        )
      }),
      it("a parameter that cannot be written is Invalid", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.EncodeFailed(
            2,
            "out of range for int2",
          ))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Invalid(
          "parameter $2 could not be written: out of range for int2",
          failure,
        ))
        |> or_fail_with(
          "Expected Invalid with the message: parameter $2 could not be written: out of range for int2",
        )
      }),
      it("an unexpected NULL is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.UnexpectedNull(1, "total"))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "column 1 (total) is NULL, and the query reads it as not NULL",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: column 1 (total) is NULL, and the query reads it as not NULL",
        )
      }),
      it("a value out of range is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.ValueOutOfRange(
            2,
            "starts_at",
            "infinity",
          ))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "column 2 (starts_at) holds infinity, which its codec cannot read",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: column 2 (starts_at) holds infinity, which its codec cannot read",
        )
      }),
      it("a value that cannot be read is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.DecodeFailed(
            1,
            "path",
            "not an ltree",
          ))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "column 1 (path) could not be read: not an ltree",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: column 1 (path) could not be read: not an ltree",
        )
      }),
      it("too many rows is Failed", fn() {
        // Arrange
        let failure = postgres_failure.with_reason(error.TooManyRows(2))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "the query returned 2 rows, and at most 1 was expected",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: the query returned 2 rows, and at most 1 was expected",
        )
      }),
      it("a commit that rolled back is Failed", fn() {
        // Arrange
        let failure = postgres_failure.with_reason(error.CommitRolledBack(None))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "the server rolled the transaction back at commit, because a statement in it failed",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: the server rolled the transaction back at commit, because a statement in it failed",
        )
      }),
      it("a request with no recording is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.RequestNotRecorded("SELECT 1"))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "the recording has no answer to the request: SELECT 1",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: the recording has no answer to the request: SELECT 1",
        )
      }),
      it("a recording that could not be written is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.RecordingNotWritten(
            "test/recordings/users.json",
            posix.Eacces,
          ))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "the recording test/recordings/users.json could not be written: eacces",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: the recording test/recordings/users.json could not be written: eacces",
        )
      }),
      it("a stopped recorder is Unavailable", fn() {
        // Arrange
        let failure = postgres_failure.with_reason(error.RecorderStopped)

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Unavailable("the recorder is stopped", failure))
        |> or_fail_with(
          "Expected Unavailable with the message: the recorder is stopped",
        )
      }),
      it("a request that is not the next recorded one is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.RequestNotMatched(
            "SELECT 1",
            "SELECT 2",
          ))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "the request is not the next request of the recording: SELECT 2, the recording has: SELECT 1",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: the request is not the next request of the recording: SELECT 2, the recording has: SELECT 1",
        )
      }),
      it("a missing recording is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.RecordingNotFound(
            "test/recordings/users.json",
          ))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "the recording test/recordings/users.json does not exist",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: the recording test/recordings/users.json does not exist",
        )
      }),
      it("a recording that could not be read is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.RecordingNotRead(
            "test/recordings/users.json",
            posix.Eacces,
          ))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "the recording test/recordings/users.json could not be read: eacces",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: the recording test/recordings/users.json could not be read: eacces",
        )
      }),
      it("a file that is not a recording is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.RecordingNotDecoded(
            "test/recordings/users.json",
            json.UnexpectedEndOfInput,
          ))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "the file test/recordings/users.json is not a recording of this format",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: the file test/recordings/users.json is not a recording of this format",
        )
      }),
      it("a recording that another recorder holds is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.RecordingInUse(
            "test/recordings/users.json",
          ))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "another recorder that runs holds the recording test/recordings/users.json",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: another recorder that runs holds the recording test/recordings/users.json",
        )
      }),
      it("a recorder process that did not start is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.RecorderNotStarted(
            actor.InitTimeout,
          ))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed("the process of the recorder did not start", failure))
        |> or_fail_with(
          "Expected Failed with the message: the process of the recorder did not start",
        )
      }),
      it("a pool with no database is Failed", fn() {
        // Arrange
        let failure = postgres_failure.with_reason(error.PoolHasNoDatabase)

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "the pool has no database, so it holds no connection",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: the pool has no database, so it holds no connection",
        )
      }),
      it("a secret column that could not be replaced is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.SecretColumnNotReplaced(
            "token",
            "the codec int does not take the type text",
          ))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "the secret column token could not be replaced: the codec int does not take the type text",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: the secret column token could not be replaced: the codec int does not take the type text",
        )
      }),
      it("an interceptor refusal is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.InterceptorFailed("read only"))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "an interceptor refused the query: read only",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: an interceptor refused the query: read only",
        )
      }),
    ]),
    group("to_dream_error of each server class", [
      it("a unique violation is Conflict", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.Server(server_error.with_sql_state(
              sql_state.UniqueViolation,
              Some("users_email_key"),
            )),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Conflict(
          "the message (23505, constraint users_email_key)",
          failure,
        ))
        |> or_fail_with(
          "Expected Conflict with the message: the message (23505, constraint users_email_key)",
        )
      }),
      it("a NOT NULL violation is Invalid", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.Server(server_error.with_sql_state(
              sql_state.NotNullViolation,
              None,
            )),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Invalid("the message (23502)", failure))
        |> or_fail_with(
          "Expected Invalid with the message: the message (23502)",
        )
      }),
      it("a check violation is Invalid", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.Server(server_error.with_sql_state(
              sql_state.CheckViolation,
              Some("price_positive"),
            )),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Invalid(
          "the message (23514, constraint price_positive)",
          failure,
        ))
        |> or_fail_with(
          "Expected Invalid with the message: the message (23514, constraint price_positive)",
        )
      }),
      it("a deadlock is Retry", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.Server(server_error.with_sql_state(
              sql_state.DeadlockDetected,
              None,
            )),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Retry("the message (40P01)", failure, None))
        |> or_fail_with("Expected Retry with the message: the message (40P01)")
      }),
      it("a serialization failure is Retry", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.Server(server_error.with_sql_state(
              sql_state.SerializationFailure,
              None,
            )),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Retry("the message (40001)", failure, None))
        |> or_fail_with("Expected Retry with the message: the message (40001)")
      }),
      it("an unknown statement completion is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.Server(server_error.with_sql_state(
              sql_state.StatementCompletionUnknown,
              None,
            )),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed("the message (40003)", failure))
        |> or_fail_with("Expected Failed with the message: the message (40003)")
      }),
      it("a cancelled query is Timeout", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.Server(server_error.with_sql_state(
              sql_state.QueryCanceled,
              None,
            )),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Timeout("the message (57014)", failure))
        |> or_fail_with(
          "Expected Timeout with the message: the message (57014)",
        )
      }),
      it("another operator intervention is Unavailable", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.Server(server_error.with_sql_state(
              sql_state.AdminShutdown,
              None,
            )),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Unavailable("the message (57P01)", failure))
        |> or_fail_with(
          "Expected Unavailable with the message: the message (57P01)",
        )
      }),
      it("a lock that is not free is Timeout", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.Server(server_error.with_sql_state(
              sql_state.LockNotAvailable,
              None,
            )),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Timeout("the message (55P03)", failure))
        |> or_fail_with(
          "Expected Timeout with the message: the message (55P03)",
        )
      }),
      it("another object state error is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.Server(server_error.with_sql_state(
              sql_state.ObjectInUse,
              None,
            )),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed("the message (55006)", failure))
        |> or_fail_with("Expected Failed with the message: the message (55006)")
      }),
      it("a data exception is Invalid", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.Server(server_error.with_sql_state(
              sql_state.InvalidTextRepresentation,
              None,
            )),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Invalid("the message (22P02)", failure))
        |> or_fail_with(
          "Expected Invalid with the message: the message (22P02)",
        )
      }),
      it("too many connections is Unavailable", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.Server(server_error.with_sql_state(
              sql_state.TooManyConnections,
              None,
            )),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Unavailable("the message (53300)", failure))
        |> or_fail_with(
          "Expected Unavailable with the message: the message (53300)",
        )
      }),
      it("a missing privilege is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.Server(server_error.with_sql_state(
              sql_state.InsufficientPrivilege,
              None,
            )),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed("the message (42501)", failure))
        |> or_fail_with("Expected Failed with the message: the message (42501)")
      }),
      it("a feature that is not supported is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.Server(server_error.with_sql_state(
              sql_state.FeatureNotSupported,
              None,
            )),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed("the message (0A000)", failure))
        |> or_fail_with("Expected Failed with the message: the message (0A000)")
      }),
      it("a successful completion code is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.Server(server_error.with_sql_state(
              sql_state.SuccessfulCompletion,
              None,
            )),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed("the message (00000)", failure))
        |> or_fail_with("Expected Failed with the message: the message (00000)")
      }),
      it("a code of an unlisted class is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.Server(server_error.with_sql_state(
              sql_state.Unlisted("99X99"),
              None,
            )),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed("the message (99X99)", failure))
        |> or_fail_with("Expected Failed with the message: the message (99X99)")
      }),
    ]),
    group("to_dream_error of each driver reason", [
      it("SQL that starts no COPY of the direction is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.CopyNotStarted(
            statement_ran: False,
          ))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "the SQL did not start a COPY of the direction asked for",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: the SQL did not start a COPY of the direction asked for",
        )
      }),
      it("a chunk for a COPY that ended is Failed", fn() {
        // Arrange
        let failure = postgres_failure.with_reason(error.CopyNotRunning)

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed("the COPY does not run any more", failure))
        |> or_fail_with(
          "Expected Failed with the message: the COPY does not run any more",
        )
      }),
      it("SQL that ran to its end and starts no COPY is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.CopyNotStarted(statement_ran: True))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "the SQL did not start a COPY of the direction asked for; the statement ran to its end, and outside a transaction it is committed",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: the SQL did not start a COPY of the direction asked for; the statement ran to its end, and outside a transaction it is committed",
        )
      }),
      it(
        "a COPY statement after two statements of a `run_sql` call is Failed",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.CopyStatementRefused(
              statements_run: 2,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "a COPY statement cannot run as a query; the SQL ran 2 of its statements before it, and outside a transaction they are committed",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: a COPY statement cannot run as a query; the SQL ran 2 of its statements before it, and outside a transaction they are committed",
          )
        },
      ),
      it("a query timeout with no confirmed stop is Timeout", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.QueryTimeout(
            stopped_on_server: False,
          ))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Timeout(
          "the query did not finish in time, and the server did not confirm that it stopped",
          failure,
        ))
        |> or_fail_with(
          "Expected Timeout with the message: the query did not finish in time, and the server did not confirm that it stopped",
        )
      }),
      it(
        "a later statement of a `run_sql` call that failed is the kind of its server error",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.SqlStatementFailed(
              statements_run: 1,
              server_error: server_error.with_sql_state(
                sql_state.UniqueViolation,
                Some("users_email_key"),
              ),
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Conflict(
            "the SQL failed after it ran 1 of its statements (outside a transaction they are committed): the message (23505, constraint users_email_key)",
            failure,
          ))
          |> or_fail_with(
            "Expected Conflict with the message: the SQL failed after it ran 1 of its statements (outside a transaction they are committed): the message (23505, constraint users_email_key)",
          )
        },
      ),
      it("a COPY statement is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.CopyStatementRefused(
            statements_run: 0,
          ))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed("a COPY statement cannot run as a query", failure))
        |> or_fail_with(
          "Expected Failed with the message: a COPY statement cannot run as a query",
        )
      }),
      it("a request that cannot be written is Invalid", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.RequestNotWritable(error.ZeroByteInString("query")),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Invalid(
          "the request could not be written: the query holds a zero byte",
          failure,
        ))
        |> or_fail_with(
          "Expected Invalid with the message: the request could not be written: the query holds a zero byte",
        )
      }),
      it("a connection process that is down is Unavailable", fn() {
        // Arrange
        let failure = postgres_failure.with_reason(error.ConnectionProcessDown)

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Unavailable("the connection process is gone", failure))
        |> or_fail_with(
          "Expected Unavailable with the message: the connection process is gone",
        )
      }),
      it("an unknown type is Failed", fn() {
        // Arrange
        let failure = postgres_failure.with_reason(error.UnknownType(90_000))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed("the database has no type with OID 90000", failure))
        |> or_fail_with(
          "Expected Failed with the message: the database has no type with OID 90000",
        )
      }),
      it("an unreadable catalog is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.UnreadableCatalog(error.CircularDomain(90_000)),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "the type catalog could not be read: the base types of domain 90000 come back to a domain of the chain",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: the type catalog could not be read: the base types of domain 90000 come back to a domain of the chain",
        )
      }),
      it("a catalog process that is down is Unavailable", fn() {
        // Arrange
        let failure = postgres_failure.with_reason(error.CatalogProcessDown)

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Unavailable("the type catalog process is gone", failure))
        |> or_fail_with(
          "Expected Unavailable with the message: the type catalog process is gone",
        )
      }),
      it("an undecodable server message is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.UndecodableServerMessage(error.UnknownMessageType(33)),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "the server broke the protocol: unknown message type 33",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: the server broke the protocol: unknown message type 33",
        )
      }),
      it("an unexpected server message is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.UnexpectedServerMessage(
            error.DataRow,
            error.AwaitingBindComplete,
          ))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "the server broke the protocol: it sent DataRow while the client waited for BindComplete",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: the server broke the protocol: it sent DataRow while the client waited for BindComplete",
        )
      }),
      it("an unexpected message between requests is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.UnexpectedIdleMessage(
            error.DataRow,
          ))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "the server broke the protocol: it sent DataRow between requests",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: the server broke the protocol: it sent DataRow between requests",
        )
      }),
    ]),
    group("each lost reason", [
      it(
        "the database read nothing within the send timeout, so the connection was closed",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.ConnectionLost(
              error.SendTimedOut,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Unavailable(
            "the database read nothing within the send timeout, so the connection was closed",
            failure,
          ))
          |> or_fail_with(
            "Expected Unavailable with the message: the database read nothing within the send timeout, so the connection was closed",
          )
        },
      ),
    ]),
    group("each TLS failure", [
      it(
        "the TLS handshake failed: the certificate does not name the host",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.ConnectFailed(error.TlsFailed(error.CertificateHostMismatch)),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Unavailable(
            "the TLS handshake failed: the certificate does not name the host",
            failure,
          ))
          |> or_fail_with(
            "Expected Unavailable with the message: the TLS handshake failed: the certificate does not name the host",
          )
        },
      ),
      it(
        "the TLS handshake failed: the authority file ca.pem could not be read (enoent)",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.ConnectFailed(
                error.TlsFailed(error.AuthorityFileUnreadable(
                  "ca.pem",
                  "enoent",
                )),
              ),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Unavailable(
            "the TLS handshake failed: the authority file ca.pem could not be read (enoent)",
            failure,
          ))
          |> or_fail_with(
            "Expected Unavailable with the message: the TLS handshake failed: the authority file ca.pem could not be read (enoent)",
          )
        },
      ),
      it(
        "the TLS handshake failed: the authority file ca.pem holds no certificate",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.ConnectFailed(
                error.TlsFailed(error.AuthorityFileEmpty("ca.pem")),
              ),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Unavailable(
            "the TLS handshake failed: the authority file ca.pem holds no certificate",
            failure,
          ))
          |> or_fail_with(
            "Expected Unavailable with the message: the TLS handshake failed: the authority file ca.pem holds no certificate",
          )
        },
      ),
      it(
        "the TLS handshake failed: the server answered the TLS request with an error",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.ConnectFailed(error.TlsFailed(
                error.TlsRequestAnsweredWithError,
              )),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Unavailable(
            "the TLS handshake failed: the server answered the TLS request with an error",
            failure,
          ))
          |> or_fail_with(
            "Expected Unavailable with the message: the TLS handshake failed: the server answered the TLS request with an error",
          )
        },
      ),
      it(
        "the TLS handshake failed: the server answered the TLS request with the byte 88",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.ConnectFailed(
                error.TlsFailed(error.UnexpectedTlsAnswer(88)),
              ),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Unavailable(
            "the TLS handshake failed: the server answered the TLS request with the byte 88",
            failure,
          ))
          |> or_fail_with(
            "Expected Unavailable with the message: the TLS handshake failed: the server answered the TLS request with the byte 88",
          )
        },
      ),
      it(
        "the TLS handshake failed: the server sent bytes before the TLS handshake",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.ConnectFailed(error.TlsFailed(error.BytesBeforeTlsHandshake)),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Unavailable(
            "the TLS handshake failed: the server sent bytes before the TLS handshake",
            failure,
          ))
          |> or_fail_with(
            "Expected Unavailable with the message: the TLS handshake failed: the server sent bytes before the TLS handshake",
          )
        },
      ),
    ]),
    group("each request fault", [
      it("the request could not be written: the query holds a zero byte", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.RequestNotWritable(error.ZeroByteInString("query")),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Invalid(
          "the request could not be written: the query holds a zero byte",
          failure,
        ))
        |> or_fail_with(
          "Expected Invalid with the message: the request could not be written: the query holds a zero byte",
        )
      }),
      it(
        "the request could not be written: the parameters has 70000 items, and at most 65535 can be sent",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.RequestNotWritable(error.TooManyItems("parameters", 70_000)),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Invalid(
            "the request could not be written: the parameters has 70000 items, and at most 65535 can be sent",
            failure,
          ))
          |> or_fail_with(
            "Expected Invalid with the message: the request could not be written: the parameters has 70000 items, and at most 65535 can be sent",
          )
        },
      ),
      it(
        "the request could not be written: the value -1 of the type OID is out of range",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.RequestNotWritable(error.NumberOutOfRange("type OID", -1)),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Invalid(
            "the request could not be written: the value -1 of the type OID is out of range",
            failure,
          ))
          |> or_fail_with(
            "Expected Invalid with the message: the request could not be written: the value -1 of the type OID is out of range",
          )
        },
      ),
      it(
        "the request could not be written: the cancel key has 2 bytes, and it must have 4 to 256",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.RequestNotWritable(error.SecretKeyLengthOutOfRange(2)),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Invalid(
            "the request could not be written: the cancel key has 2 bytes, and it must have 4 to 256",
            failure,
          ))
          |> or_fail_with(
            "Expected Invalid with the message: the request could not be written: the cancel key has 2 bytes, and it must have 4 to 256",
          )
        },
      ),
      it(
        "the request could not be written: a message of 5000000000 bytes is too long for its length field",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.RequestNotWritable(error.MessageTooLong(5_000_000_000)),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Invalid(
            "the request could not be written: a message of 5000000000 bytes is too long for its length field",
            failure,
          ))
          |> or_fail_with(
            "Expected Invalid with the message: the request could not be written: a message of 5000000000 bytes is too long for its length field",
          )
        },
      ),
    ]),
    group("each catalog fault", [
      it(
        "the type catalog could not be read: a row of 2 values does not have the shape of a catalog row",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.UnreadableCatalog(
                error.UnreadableRow([cell.Text(<<"x">>), cell.Null]),
              ),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the type catalog could not be read: a row of 2 values does not have the shape of a catalog row",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the type catalog could not be read: a row of 2 values does not have the shape of a catalog row",
          )
        },
      ),
      it(
        "the type catalog could not be read: type 90000 has the unknown kind x",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.UnreadableCatalog(error.UnknownTypeKind(90_000, "x")),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the type catalog could not be read: type 90000 has the unknown kind x",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the type catalog could not be read: type 90000 has the unknown kind x",
          )
        },
      ),
      it(
        "the type catalog could not be read: type 90000 has the part 90001, which the catalog does not have",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.UnreadableCatalog(error.MissingPart(90_000, 90_001)),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the type catalog could not be read: type 90000 has the part 90001, which the catalog does not have",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the type catalog could not be read: type 90000 has the part 90001, which the catalog does not have",
          )
        },
      ),
      it(
        "the type catalog could not be read: the base types of domain 90000 come back to a domain of the chain",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.UnreadableCatalog(error.CircularDomain(90_000)),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the type catalog could not be read: the base types of domain 90000 come back to a domain of the chain",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the type catalog could not be read: the base types of domain 90000 come back to a domain of the chain",
          )
        },
      ),
    ]),
    group("each message fault", [
      it("the server broke the protocol: unknown message type 33", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.UndecodableServerMessage(error.UnknownMessageType(33)),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "the server broke the protocol: unknown message type 33",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: the server broke the protocol: unknown message type 33",
        )
      }),
      it(
        "the server broke the protocol: message type 68 has the length 2, which is below 4",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.UndecodableServerMessage(error.InvalidMessageLength(68, 2)),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: message type 68 has the length 2, which is below 4",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: message type 68 has the length 2, which is below 4",
          )
        },
      ),
      it(
        "the server broke the protocol: the body of message type 68 does not have its layout",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.UndecodableServerMessage(error.InvalidMessageBody(68)),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: the body of message type 68 does not have its layout",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: the body of message type 68 does not have its layout",
          )
        },
      ),
      it(
        "the server broke the protocol: message type 84 holds text that is not UTF-8",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.UndecodableServerMessage(error.InvalidUtf8(84)),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: message type 84 holds text that is not UTF-8",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: message type 84 holds text that is not UTF-8",
          )
        },
      ),
      it(
        "the server broke the protocol: unknown authentication request 99",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.UndecodableServerMessage(error.UnknownAuthenticationRequest(
                99,
              )),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: unknown authentication request 99",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: unknown authentication request 99",
          )
        },
      ),
      it("the server broke the protocol: unknown transaction status 88", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.UndecodableServerMessage(error.UnknownTransactionStatus(88)),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "the server broke the protocol: unknown transaction status 88",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: the server broke the protocol: unknown transaction status 88",
        )
      }),
      it(
        "the server broke the protocol: message type 84 has the unknown format code 2",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.UndecodableServerMessage(error.UnknownFormatCode(84, 2)),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: message type 84 has the unknown format code 2",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: message type 84 has the unknown format code 2",
          )
        },
      ),
      it(
        "the server broke the protocol: the secret key has 2 bytes, and it must have 4 to 256",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.UndecodableServerMessage(error.InvalidSecretKeyLength(2)),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: the secret key has 2 bytes, and it must have 4 to 256",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: the secret key has 2 bytes, and it must have 4 to 256",
          )
        },
      ),
      it("the server broke the protocol: message type 69 has no field 67", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.UndecodableServerMessage(error.MissingReportField(69, 67)),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "the server broke the protocol: message type 69 has no field 67",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: the server broke the protocol: message type 69 has no field 67",
        )
      }),
      it(
        "the server broke the protocol: field 80 of message type 69 is not a number: x",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.UndecodableServerMessage(error.InvalidReportNumber(
                69,
                80,
                "x",
              )),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: field 80 of message type 69 is not a number: x",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: field 80 of message type 69 is not a number: x",
          )
        },
      ),
    ]),
    group("each server message kind", [
      it(
        "the server broke the protocol: it sent AuthenticationOk between requests",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedIdleMessage(
              error.AuthenticationOk,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent AuthenticationOk between requests",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent AuthenticationOk between requests",
          )
        },
      ),
      it(
        "the server broke the protocol: it sent AuthenticationKerberosV5 between requests",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedIdleMessage(
              error.AuthenticationKerberosV5,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent AuthenticationKerberosV5 between requests",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent AuthenticationKerberosV5 between requests",
          )
        },
      ),
      it(
        "the server broke the protocol: it sent AuthenticationCleartextPassword between requests",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedIdleMessage(
              error.AuthenticationCleartextPassword,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent AuthenticationCleartextPassword between requests",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent AuthenticationCleartextPassword between requests",
          )
        },
      ),
      it(
        "the server broke the protocol: it sent AuthenticationMD5Password between requests",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedIdleMessage(
              error.AuthenticationMd5Password,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent AuthenticationMD5Password between requests",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent AuthenticationMD5Password between requests",
          )
        },
      ),
      it(
        "the server broke the protocol: it sent AuthenticationGSS between requests",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedIdleMessage(
              error.AuthenticationGss,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent AuthenticationGSS between requests",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent AuthenticationGSS between requests",
          )
        },
      ),
      it(
        "the server broke the protocol: it sent AuthenticationGSSContinue between requests",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedIdleMessage(
              error.AuthenticationGssContinue,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent AuthenticationGSSContinue between requests",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent AuthenticationGSSContinue between requests",
          )
        },
      ),
      it(
        "the server broke the protocol: it sent AuthenticationSSPI between requests",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedIdleMessage(
              error.AuthenticationSspi,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent AuthenticationSSPI between requests",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent AuthenticationSSPI between requests",
          )
        },
      ),
      it(
        "the server broke the protocol: it sent AuthenticationSASL between requests",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedIdleMessage(
              error.AuthenticationSasl,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent AuthenticationSASL between requests",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent AuthenticationSASL between requests",
          )
        },
      ),
      it(
        "the server broke the protocol: it sent AuthenticationSASLContinue between requests",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedIdleMessage(
              error.AuthenticationSaslContinue,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent AuthenticationSASLContinue between requests",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent AuthenticationSASLContinue between requests",
          )
        },
      ),
      it(
        "the server broke the protocol: it sent AuthenticationSASLFinal between requests",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedIdleMessage(
              error.AuthenticationSaslFinal,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent AuthenticationSASLFinal between requests",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent AuthenticationSASLFinal between requests",
          )
        },
      ),
      it(
        "the server broke the protocol: it sent BackendKeyData between requests",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedIdleMessage(
              error.BackendKeyData,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent BackendKeyData between requests",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent BackendKeyData between requests",
          )
        },
      ),
      it(
        "the server broke the protocol: it sent BindComplete between requests",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedIdleMessage(
              error.BindComplete,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent BindComplete between requests",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent BindComplete between requests",
          )
        },
      ),
      it(
        "the server broke the protocol: it sent CloseComplete between requests",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedIdleMessage(
              error.CloseComplete,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent CloseComplete between requests",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent CloseComplete between requests",
          )
        },
      ),
      it(
        "the server broke the protocol: it sent CommandComplete between requests",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedIdleMessage(
              error.CommandComplete,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent CommandComplete between requests",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent CommandComplete between requests",
          )
        },
      ),
      it(
        "the server broke the protocol: it sent CopyData between requests",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedIdleMessage(
              error.CopyData,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent CopyData between requests",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent CopyData between requests",
          )
        },
      ),
      it(
        "the server broke the protocol: it sent CopyDone between requests",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedIdleMessage(
              error.CopyDone,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent CopyDone between requests",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent CopyDone between requests",
          )
        },
      ),
      it(
        "the server broke the protocol: it sent CopyInResponse between requests",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedIdleMessage(
              error.CopyInResponse,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent CopyInResponse between requests",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent CopyInResponse between requests",
          )
        },
      ),
      it(
        "the server broke the protocol: it sent CopyOutResponse between requests",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedIdleMessage(
              error.CopyOutResponse,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent CopyOutResponse between requests",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent CopyOutResponse between requests",
          )
        },
      ),
      it(
        "the server broke the protocol: it sent CopyBothResponse between requests",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedIdleMessage(
              error.CopyBothResponse,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent CopyBothResponse between requests",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent CopyBothResponse between requests",
          )
        },
      ),
      it(
        "the server broke the protocol: it sent DataRow between requests",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedIdleMessage(
              error.DataRow,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent DataRow between requests",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent DataRow between requests",
          )
        },
      ),
      it(
        "the server broke the protocol: it sent EmptyQueryResponse between requests",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedIdleMessage(
              error.EmptyQueryResponse,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent EmptyQueryResponse between requests",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent EmptyQueryResponse between requests",
          )
        },
      ),
      it(
        "the server broke the protocol: it sent ErrorResponse between requests",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedIdleMessage(
              error.ErrorResponse,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent ErrorResponse between requests",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent ErrorResponse between requests",
          )
        },
      ),
      it(
        "the server broke the protocol: it sent FunctionCallResponse between requests",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedIdleMessage(
              error.FunctionCallResponse,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent FunctionCallResponse between requests",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent FunctionCallResponse between requests",
          )
        },
      ),
      it(
        "the server broke the protocol: it sent NegotiateProtocolVersion between requests",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedIdleMessage(
              error.NegotiateProtocolVersion,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent NegotiateProtocolVersion between requests",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent NegotiateProtocolVersion between requests",
          )
        },
      ),
      it("the server broke the protocol: it sent NoData between requests", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.UnexpectedIdleMessage(error.NoData))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "the server broke the protocol: it sent NoData between requests",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: the server broke the protocol: it sent NoData between requests",
        )
      }),
      it(
        "the server broke the protocol: it sent NoticeResponse between requests",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedIdleMessage(
              error.NoticeResponse,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent NoticeResponse between requests",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent NoticeResponse between requests",
          )
        },
      ),
      it(
        "the server broke the protocol: it sent NotificationResponse between requests",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedIdleMessage(
              error.NotificationResponse,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent NotificationResponse between requests",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent NotificationResponse between requests",
          )
        },
      ),
      it(
        "the server broke the protocol: it sent ParameterDescription between requests",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedIdleMessage(
              error.ParameterDescription,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent ParameterDescription between requests",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent ParameterDescription between requests",
          )
        },
      ),
      it(
        "the server broke the protocol: it sent ParameterStatus between requests",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedIdleMessage(
              error.ParameterStatus,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent ParameterStatus between requests",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent ParameterStatus between requests",
          )
        },
      ),
      it(
        "the server broke the protocol: it sent ParseComplete between requests",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedIdleMessage(
              error.ParseComplete,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent ParseComplete between requests",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent ParseComplete between requests",
          )
        },
      ),
      it(
        "the server broke the protocol: it sent PortalSuspended between requests",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedIdleMessage(
              error.PortalSuspended,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent PortalSuspended between requests",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent PortalSuspended between requests",
          )
        },
      ),
      it(
        "the server broke the protocol: it sent ReadyForQuery between requests",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedIdleMessage(
              error.ReadyForQuery,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent ReadyForQuery between requests",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent ReadyForQuery between requests",
          )
        },
      ),
      it(
        "the server broke the protocol: it sent RowDescription between requests",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedIdleMessage(
              error.RowDescription,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent RowDescription between requests",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent RowDescription between requests",
          )
        },
      ),
    ]),
    group("each protocol step", [
      it(
        "the server broke the protocol: it sent NoData while the client waited for ParseComplete",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedServerMessage(
              error.NoData,
              error.AwaitingParseComplete,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent NoData while the client waited for ParseComplete",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent NoData while the client waited for ParseComplete",
          )
        },
      ),
      it(
        "the server broke the protocol: it sent NoData while the client waited for ParameterDescription",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedServerMessage(
              error.NoData,
              error.AwaitingParameterDescription,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent NoData while the client waited for ParameterDescription",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent NoData while the client waited for ParameterDescription",
          )
        },
      ),
      it(
        "the server broke the protocol: it sent NoData while the client waited for the columns of the statement",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedServerMessage(
              error.NoData,
              error.AwaitingStatementColumns,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent NoData while the client waited for the columns of the statement",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent NoData while the client waited for the columns of the statement",
          )
        },
      ),
      it(
        "the server broke the protocol: it sent NoData while the client waited for BindComplete",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedServerMessage(
              error.NoData,
              error.AwaitingBindComplete,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent NoData while the client waited for BindComplete",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent NoData while the client waited for BindComplete",
          )
        },
      ),
      it(
        "the server broke the protocol: it sent NoData while the client waited for the columns of the portal",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedServerMessage(
              error.NoData,
              error.AwaitingPortalColumns,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent NoData while the client waited for the columns of the portal",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent NoData while the client waited for the columns of the portal",
          )
        },
      ),
      it(
        "the server broke the protocol: it sent NoData while the client waited for the rows of the run",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedServerMessage(
              error.NoData,
              error.ReadingExecuteRows,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent NoData while the client waited for the rows of the run",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent NoData while the client waited for the rows of the run",
          )
        },
      ),
      it(
        "the server broke the protocol: it sent NoData while the client waited for the next result of the SQL",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedServerMessage(
              error.NoData,
              error.AwaitingStatementResult,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent NoData while the client waited for the next result of the SQL",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent NoData while the client waited for the next result of the SQL",
          )
        },
      ),
      it(
        "the server broke the protocol: it sent NoData while the client waited for the rows of a statement of the SQL",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedServerMessage(
              error.NoData,
              error.ReadingSqlRows,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent NoData while the client waited for the rows of a statement of the SQL",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent NoData while the client waited for the rows of a statement of the SQL",
          )
        },
      ),
      it(
        "the server broke the protocol: it sent NoData while the client waited for the data of a refused COPY",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedServerMessage(
              error.NoData,
              error.ReadingCopyOut,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent NoData while the client waited for the data of a refused COPY",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent NoData while the client waited for the data of a refused COPY",
          )
        },
      ),
      it(
        "the server broke the protocol: it sent NoData while the client waited for the end of a refused COPY",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedServerMessage(
              error.NoData,
              error.AwaitingCopyComplete,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent NoData while the client waited for the end of a refused COPY",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent NoData while the client waited for the end of a refused COPY",
          )
        },
      ),
      it(
        "the server broke the protocol: it sent NoData while the client waited for ReadyForQuery",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedServerMessage(
              error.NoData,
              error.AwaitingReadyForQuery,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent NoData while the client waited for ReadyForQuery",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent NoData while the client waited for ReadyForQuery",
          )
        },
      ),
      it(
        "the server broke the protocol: it sent NoData while the client waited for ReadyForQuery after an error",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedServerMessage(
              error.NoData,
              error.AwaitingReadyForQueryAfterError,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent NoData while the client waited for ReadyForQuery after an error",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent NoData while the client waited for ReadyForQuery after an error",
          )
        },
      ),
      it(
        "the server broke the protocol: it sent NoData while the client waited for CloseComplete",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedServerMessage(
              error.NoData,
              error.AwaitingCloseComplete,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent NoData while the client waited for CloseComplete",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent NoData while the client waited for CloseComplete",
          )
        },
      ),
      it(
        "the server broke the protocol: it sent NoData while the client waited for the end of a COPY FROM STDIN",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnexpectedServerMessage(
              error.NoData,
              error.CopyingIn,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the server broke the protocol: it sent NoData while the client waited for the end of a COPY FROM STDIN",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the server broke the protocol: it sent NoData while the client waited for the end of a COPY FROM STDIN",
          )
        },
      ),
    ]),
    group("each config fault", [
      it("the config is not valid: the host \"a b\" is not a valid host", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.InvalidConfig(error.InvalidHost("a b")),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Invalid(
          "the config is not valid: the host \"a b\" is not a valid host",
          failure,
        ))
        |> or_fail_with(
          "Expected Invalid with the message: the config is not valid: the host \"a b\" is not a valid host",
        )
      }),
      it("the config is not valid: the port 0 is not in 1 to 65535", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.InvalidConfig(error.InvalidPort(0)),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Invalid(
          "the config is not valid: the port 0 is not in 1 to 65535",
          failure,
        ))
        |> or_fail_with(
          "Expected Invalid with the message: the config is not valid: the port 0 is not in 1 to 65535",
        )
      }),
      it("the config is not valid: the pool size 0 is below 1", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.InvalidConfig(error.InvalidPoolSize(0)),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Invalid(
          "the config is not valid: the pool size 0 is below 1",
          failure,
        ))
        |> or_fail_with(
          "Expected Invalid with the message: the config is not valid: the pool size 0 is below 1",
        )
      }),
      it(
        "the config is not valid: the health check interval of 0 milliseconds is below 1",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.InvalidConfig(error.InvalidHealthCheckInterval(0)),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Invalid(
            "the config is not valid: the health check interval of 0 milliseconds is below 1",
            failure,
          ))
          |> or_fail_with(
            "Expected Invalid with the message: the config is not valid: the health check interval of 0 milliseconds is below 1",
          )
        },
      ),
      it(
        "the config is not valid: the connect timeout of 0 milliseconds is below 1",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.InvalidConfig(error.InvalidConnectTimeout(0)),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Invalid(
            "the config is not valid: the connect timeout of 0 milliseconds is below 1",
            failure,
          ))
          |> or_fail_with(
            "Expected Invalid with the message: the config is not valid: the connect timeout of 0 milliseconds is below 1",
          )
        },
      ),
      it(
        "the config is not valid: the setup timeout of 0 milliseconds is below 1",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.InvalidConfig(error.InvalidSetupTimeout(0)),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Invalid(
            "the config is not valid: the setup timeout of 0 milliseconds is below 1",
            failure,
          ))
          |> or_fail_with(
            "Expected Invalid with the message: the config is not valid: the setup timeout of 0 milliseconds is below 1",
          )
        },
      ),
      it(
        "the config is not valid: the cancel timeout of 0 milliseconds is below 1",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.InvalidConfig(error.InvalidCancelTimeout(0)),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Invalid(
            "the config is not valid: the cancel timeout of 0 milliseconds is below 1",
            failure,
          ))
          |> or_fail_with(
            "Expected Invalid with the message: the config is not valid: the cancel timeout of 0 milliseconds is below 1",
          )
        },
      ),
      it(
        "the config is not valid: the return rollback timeout of 0 milliseconds is below 1",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.InvalidConfig(error.InvalidReturnRollbackTimeout(0)),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Invalid(
            "the config is not valid: the return rollback timeout of 0 milliseconds is below 1",
            failure,
          ))
          |> or_fail_with(
            "Expected Invalid with the message: the config is not valid: the return rollback timeout of 0 milliseconds is below 1",
          )
        },
      ),
      it("the config is not valid: the user is empty", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.InvalidConfig(error.EmptyUser))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Invalid(
          "the config is not valid: the user is empty",
          failure,
        ))
        |> or_fail_with(
          "Expected Invalid with the message: the config is not valid: the user is empty",
        )
      }),
      it("the config is not valid: the password holds a zero byte", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.InvalidConfig(
            error.ZeroByteInPassword,
          ))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Invalid(
          "the config is not valid: the password holds a zero byte",
          failure,
        ))
        |> or_fail_with(
          "Expected Invalid with the message: the config is not valid: the password holds a zero byte",
        )
      }),
      it(
        "the config is not valid: the startup parameter application_name holds a zero byte",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.InvalidConfig(error.ZeroByteInParameter("application_name")),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Invalid(
            "the config is not valid: the startup parameter application_name holds a zero byte",
            failure,
          ))
          |> or_fail_with(
            "Expected Invalid with the message: the config is not valid: the startup parameter application_name holds a zero byte",
          )
        },
      ),
      it("the config is not valid: a startup parameter has an empty name", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.InvalidConfig(
            error.EmptyParameterName,
          ))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Invalid(
          "the config is not valid: a startup parameter has an empty name",
          failure,
        ))
        |> or_fail_with(
          "Expected Invalid with the message: the config is not valid: a startup parameter has an empty name",
        )
      }),
      it(
        "the config is not valid: the startup parameter timezone is given more than one time",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.InvalidConfig(error.DuplicateParameter("timezone")),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Invalid(
            "the config is not valid: the startup parameter timezone is given more than one time",
            failure,
          ))
          |> or_fail_with(
            "Expected Invalid with the message: the config is not valid: the startup parameter timezone is given more than one time",
          )
        },
      ),
      it(
        "the config is not valid: the client encoding LATIN1 is not UTF-8, and dream_postgres reads and writes only UTF-8",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.InvalidConfig(error.UnsupportedClientEncoding("LATIN1")),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Invalid(
            "the config is not valid: the client encoding LATIN1 is not UTF-8, and dream_postgres reads and writes only UTF-8",
            failure,
          ))
          |> or_fail_with(
            "Expected Invalid with the message: the config is not valid: the client encoding LATIN1 is not UTF-8, and dream_postgres reads and writes only UTF-8",
          )
        },
      ),
    ]),
    group("each pool and transaction reason", [
      it("the pool did not start: the pool process did not start in time", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.PoolStartFailed(
            error.PoolStartTimedOut,
          ))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "the pool did not start: the pool process did not start in time",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: the pool did not start: the pool process did not start in time",
        )
      }),
      it(
        "the pool did not start: the pool process refused to start: no supervisor",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.PoolStartFailed(error.PoolInitFailed("no supervisor")),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the pool did not start: the pool process refused to start: no supervisor",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the pool did not start: the pool process refused to start: no supervisor",
          )
        },
      ),
      it(
        "the pool did not start: the pool process exited during its start: killed",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.PoolStartFailed(error.PoolProcessExited("killed")),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the pool did not start: the pool process exited during its start: killed",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the pool did not start: the pool process exited during its start: killed",
          )
        },
      ),
      it(
        "a transaction inside a transaction runs as a savepoint, so it cannot set an isolation level or read only",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.OptionsInNestedTransaction)

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "a transaction inside a transaction runs as a savepoint, so it cannot set an isolation level or read only",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: a transaction inside a transaction runs as a savepoint, so it cannot set an isolation level or read only",
          )
        },
      ),
      it(
        "a step error and a failed rollback are Unavailable with both messages",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.RollbackAlsoFailed(
              step_error: error.to_dream_error(postgres_failure.with_reason(
                error.NoConnection,
              )),
              rollback_error: postgres_failure.with_reason(error.PoolStopped),
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Unavailable(
            "the rollback after a failed step failed. The step: no database connection was free in time. The rollback: the pool is stopped",
            failure,
          ))
          |> or_fail_with(
            "Expected Unavailable with the message of the step and of the rollback",
          )
        },
      ),
      it("the server answered the commit with the tags [COMMIT, COMMIT]", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.UnexpectedCommitAnswer(["COMMIT", "COMMIT"]),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "the server answered the commit with the tags [COMMIT, COMMIT]",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: the server answered the commit with the tags [COMMIT, COMMIT]",
        )
      }),
      it("a field with a codec in the text format is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.CopyNeedsBinaryCodec(
            1,
            "id",
            "ltree",
          ))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "column 1 (id) has the ltree codec in the text format, and a binary COPY needs a codec in the binary format",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: column 1 (id) has the ltree codec in the text format, and a binary COPY needs a codec in the binary format",
        )
      }),
      it("a COPY query with parameters is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.CopyQueryHasParameters(2))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "the query has 2 parameters, and a COPY statement takes none",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: the query has 2 parameters, and a COPY statement takes none",
        )
      }),
      it("COPY data with another signature is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.MalformedCopyStream(
            error.InvalidCopySignature,
          ))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "the server broke the protocol: the COPY data does not start with the binary COPY signature",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: the server broke the protocol: the COPY data does not start with the binary COPY signature",
        )
      }),
      it("COPY flags that the client cannot read are Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.MalformedCopyStream(error.UnsupportedCopyFlags(65_536)),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "the server broke the protocol: the COPY header sets the flags 65536, which the client cannot read",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: the server broke the protocol: the COPY header sets the flags 65536, which the client cannot read",
        )
      }),
      it("a COPY field count below -1 is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.MalformedCopyStream(error.InvalidCopyFieldCount(-2)),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "the server broke the protocol: a COPY tuple has the field count -2",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: the server broke the protocol: a COPY tuple has the field count -2",
        )
      }),
      it("a COPY field length below -1 is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.MalformedCopyStream(error.InvalidCopyFieldLength(-2)),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "the server broke the protocol: a COPY field has the length -2",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: the server broke the protocol: a COPY field has the length -2",
        )
      }),
      it("COPY data with no trailer is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.MalformedCopyStream(
            error.CopyStreamCutShort,
          ))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "the server broke the protocol: the COPY data ended before its trailer",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: the server broke the protocol: the COPY data ended before its trailer",
        )
      }),
      it("COPY data after the trailer is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.MalformedCopyStream(
            error.BytesAfterCopyTrailer,
          ))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "the server broke the protocol: the COPY data has bytes after its trailer",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: the server broke the protocol: the COPY data has bytes after its trailer",
        )
      }),
      it("the pool is stopped", fn() {
        // Arrange
        let failure = postgres_failure.with_reason(error.PoolStopped)

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Unavailable("the pool is stopped", failure))
        |> or_fail_with(
          "Expected Unavailable with the message: the pool is stopped",
        )
      }),
      it("a connection with no database to verify is Failed", fn() {
        // Arrange
        let failure = postgres_failure.with_reason(error.NoDatabaseToVerify)

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "the connection has no database to check the queries against",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: the connection has no database to check the queries against",
        )
      }),
      it("a channel name that is too long is Invalid", fn() {
        // Arrange
        let failure = postgres_failure.with_reason(error.ChannelTooLong("jobs"))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Invalid(
          "the channel name jobs has more than 63 bytes",
          failure,
        ))
        |> or_fail_with(
          "Expected Invalid with the message: the channel name jobs has more than 63 bytes",
        )
      }),
      it("a subject with no process is Invalid", fn() {
        // Arrange
        let failure = postgres_failure.with_reason(error.SubscriberHasNoProcess)

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Invalid(
          "the subject of the subscription has no process",
          failure,
        ))
        |> or_fail_with(
          "Expected Invalid with the message: the subject of the subscription has no process",
        )
      }),
      it("an unexpected answer to LISTEN is Failed", fn() {
        // Arrange
        let failure = postgres_failure.with_reason(error.UnexpectedListenAnswer)

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "the server broke the protocol: it answered LISTEN with an error after a result, or with a COPY",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: the server broke the protocol: it answered LISTEN with an error after a result, or with a COPY",
        )
      }),
      it("the listener is stopped", fn() {
        // Arrange
        let failure = postgres_failure.with_reason(error.ListenerStopped)

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Unavailable("the listener is stopped", failure))
        |> or_fail_with(
          "Expected Unavailable with the message: the listener is stopped",
        )
      }),
      it("a listener that did not start in time is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.ListenerStartFailed(
            error.ListenerStartTimedOut,
          ))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "the listener did not start: the listener process did not start in time",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: the listener did not start: the listener process did not start in time",
        )
      }),
      it("a listener that refused to start is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.ListenerStartFailed(error.ListenerInitFailed("no")),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "the listener did not start: the listener process refused to start: no",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: the listener did not start: the listener process refused to start: no",
        )
      }),
      it("a listener that exited during its start is Failed", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.ListenerStartFailed(error.ListenerProcessExited("killed")),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Failed(
          "the listener did not start: the listener process exited during its start: killed",
          failure,
        ))
        |> or_fail_with(
          "Expected Failed with the message: the listener did not start: the listener process exited during its start: killed",
        )
      }),
    ]),
    group("each connect failure of a login", [
      it(
        "the password has 5000 bytes, which is too long to send as a cleartext password",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.ConnectFailed(error.PasswordTooLong(5000)),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Unavailable(
            "the password has 5000 bytes, which is too long to send as a cleartext password",
            failure,
          ))
          |> or_fail_with(
            "Expected Unavailable with the message: the password has 5000 bytes, which is too long to send as a cleartext password",
          )
        },
      ),
      it(
        "the SCRAM login failed: the nonce of the server has 5000 bytes, which is too long for the SCRAM exchange",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.ConnectFailed(
                error.ScramFailed(error.ServerNonceTooLong(5000)),
              ),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Unavailable(
            "the SCRAM login failed: the nonce of the server has 5000 bytes, which is too long for the SCRAM exchange",
            failure,
          ))
          |> or_fail_with(
            "Expected Unavailable with the message: the SCRAM login failed: the nonce of the server has 5000 bytes, which is too long for the SCRAM exchange",
          )
        },
      ),
      it(
        "the config is not valid: the startup message has 2147483648 bytes, which is too long for its length field",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.InvalidConfig(error.StartupMessageTooLong(2_147_483_648)),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Invalid(
            "the config is not valid: the startup message has 2147483648 bytes, which is too long for its length field",
            failure,
          ))
          |> or_fail_with(
            "Expected Invalid with the message: the config is not valid: the startup message has 2147483648 bytes, which is too long for its length field",
          )
        },
      ),
      it(
        "the type catalog could not be read: the server answered the catalog query with a COPY or with an error after a result",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.UnreadableCatalog(
              error.UnexpectedCatalogAnswer,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Failed(
            "the type catalog could not be read: the server answered the catalog query with a COPY or with an error after a result",
            failure,
          ))
          |> or_fail_with(
            "Expected Failed with the message: the type catalog could not be read: the server answered the catalog query with a COPY or with an error after a result",
          )
        },
      ),
      it("db:5432 closed the connection during the connect", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.ConnectFailed(error.ConnectClosed("db", 5432)),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Unavailable(
          "db:5432 closed the connection during the connect",
          failure,
        ))
        |> or_fail_with(
          "Expected Unavailable with the message: db:5432 closed the connection during the connect",
        )
      }),
      it("the connection to db:5432 was reset during the connect", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.ConnectFailed(error.ConnectReset("db", 5432)),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Unavailable(
          "the connection to db:5432 was reset during the connect",
          failure,
        ))
        |> or_fail_with(
          "Expected Unavailable with the message: the connection to db:5432 was reset during the connect",
        )
      }),
      it(
        "a login message could not be sent: the database read nothing within the send timeout, so the connection was closed",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.ConnectFailed(error.LoginSendFailed(error.SendTimedOut)),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Unavailable(
            "a login message could not be sent: the database read nothing within the send timeout, so the connection was closed",
            failure,
          ))
          |> or_fail_with(
            "Expected Unavailable with the message: a login message could not be sent: the database read nothing within the send timeout, so the connection was closed",
          )
        },
      ),
      it("the TLS layer raised the alert bad_record_mac", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.ConnectionLost(error.TlsAlertRaised("bad_record_mac")),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Unavailable(
          "the TLS layer raised the alert bad_record_mac",
          failure,
        ))
        |> or_fail_with(
          "Expected Unavailable with the message: the TLS layer raised the alert bad_record_mac",
        )
      }),
      it(
        "the connection broke during the login: the connection was reset",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.ConnectFailed(error.ConnectionBroke(error.Reset)),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Unavailable(
            "the connection broke during the login: the connection was reset",
            failure,
          ))
          |> or_fail_with(
            "Expected Unavailable with the message: the connection broke during the login: the connection was reset",
          )
        },
      ),
      it(
        "the server asks for a password with the login method MD5, and the config has none",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.ConnectFailed(error.PasswordRequired("MD5")),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Unavailable(
            "the server asks for a password with the login method MD5, and the config has none",
            failure,
          ))
          |> or_fail_with(
            "Expected Unavailable with the message: the server asks for a password with the login method MD5, and the config has none",
          )
        },
      ),
      it(
        "the server sent DataRow at a step of the login that does not allow it",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.ConnectFailed(error.UnexpectedLoginMessage(error.DataRow)),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Unavailable(
            "the server sent DataRow at a step of the login that does not allow it",
            failure,
          ))
          |> or_fail_with(
            "Expected Unavailable with the message: the server sent DataRow at a step of the login that does not allow it",
          )
        },
      ),
      it(
        "the server broke the protocol during the login: unknown message type 1",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.ConnectFailed(
                error.UndecodableLoginMessage(error.UnknownMessageType(1)),
              ),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Unavailable(
            "the server broke the protocol during the login: unknown message type 1",
            failure,
          ))
          |> or_fail_with(
            "Expected Unavailable with the message: the server broke the protocol during the login: unknown message type 1",
          )
        },
      ),
      it("the connect and the login did not finish in time", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.ConnectFailed(error.SetupTimedOut))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Unavailable(
          "the connect and the login did not finish in time",
          failure,
        ))
        |> or_fail_with(
          "Expected Unavailable with the message: the connect and the login did not finish in time",
        )
      }),
      it("the connection process exited while it connected", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.ConnectFailed(
            error.SetupProcessExited,
          ))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Unavailable(
          "the connection process exited while it connected",
          failure,
        ))
        |> or_fail_with(
          "Expected Unavailable with the message: the connection process exited while it connected",
        )
      }),
      it(
        "the login settings are not valid: the password holds a zero byte",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.ConnectFailed(
              error.PasswordHasZeroByte,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Unavailable(
            "the login settings are not valid: the password holds a zero byte",
            failure,
          ))
          |> or_fail_with(
            "Expected Unavailable with the message: the login settings are not valid: the password holds a zero byte",
          )
        },
      ),
      it(
        "the login requires channel binding, and the connection has no TLS",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(error.ConnectFailed(
              error.ChannelBindingRequiresTls,
            ))

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Unavailable(
            "the login requires channel binding, and the connection has no TLS",
            failure,
          ))
          |> or_fail_with(
            "Expected Unavailable with the message: the login requires channel binding, and the connection has no TLS",
          )
        },
      ),
      it(
        "the login requires channel binding, and the server asks for MD5",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.ConnectFailed(error.ChannelBindingNotOffered("MD5")),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Unavailable(
            "the login requires channel binding, and the server asks for MD5",
            failure,
          ))
          |> or_fail_with(
            "Expected Unavailable with the message: the login requires channel binding, and the server asks for MD5",
          )
        },
      ),
      it("the server offers channel binding on a connection with no TLS", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(error.ConnectFailed(
            error.ChannelBindingOfferedWithoutTls,
          ))

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Unavailable(
          "the server offers channel binding on a connection with no TLS",
          failure,
        ))
        |> or_fail_with(
          "Expected Unavailable with the message: the server offers channel binding on a connection with no TLS",
        )
      }),
      it(
        "the server answers with the protocol version 3.9, which the client does not speak",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.ConnectFailed(error.UnsupportedProtocolVersion(3, 9)),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Unavailable(
            "the server answers with the protocol version 3.9, which the client does not speak",
            failure,
          ))
          |> or_fail_with(
            "Expected Unavailable with the message: the server answers with the protocol version 3.9, which the client does not speak",
          )
        },
      ),
    ]),
    group("each certificate fault", [
      it(
        "the certificate of the server gives no channel binding data: the certificate is not a DER X.509 certificate",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.ConnectFailed(error.CertificateHashFailed(
                error.InvalidCertificate,
              )),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Unavailable(
            "the certificate of the server gives no channel binding data: the certificate is not a DER X.509 certificate",
            failure,
          ))
          |> or_fail_with(
            "Expected Unavailable with the message: the certificate of the server gives no channel binding data: the certificate is not a DER X.509 certificate",
          )
        },
      ),
      it(
        "the certificate of the server gives no channel binding data: the signature algorithm 1.3.101.112 names no hash that channel binding can use",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.ConnectFailed(
                error.CertificateHashFailed(
                  error.UnsupportedSignatureAlgorithm([1, 3, 101, 112]),
                ),
              ),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Unavailable(
            "the certificate of the server gives no channel binding data: the signature algorithm 1.3.101.112 names no hash that channel binding can use",
            failure,
          ))
          |> or_fail_with(
            "Expected Unavailable with the message: the certificate of the server gives no channel binding data: the signature algorithm 1.3.101.112 names no hash that channel binding can use",
          )
        },
      ),
    ]),
    group("each SCRAM fault", [
      it(
        "the SCRAM login failed: the server-first-message does not have the form of RFC 5802",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.ConnectFailed(
                error.ScramFailed(error.InvalidServerFirstMessage(<<"x">>)),
              ),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Unavailable(
            "the SCRAM login failed: the server-first-message does not have the form of RFC 5802",
            failure,
          ))
          |> or_fail_with(
            "Expected Unavailable with the message: the SCRAM login failed: the server-first-message does not have the form of RFC 5802",
          )
        },
      ),
      it(
        "the SCRAM login failed: the server-first-message has the mandatory extension m=ext",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.ConnectFailed(
                error.ScramFailed(error.MandatoryExtension("m=ext")),
              ),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Unavailable(
            "the SCRAM login failed: the server-first-message has the mandatory extension m=ext",
            failure,
          ))
          |> or_fail_with(
            "Expected Unavailable with the message: the SCRAM login failed: the server-first-message has the mandatory extension m=ext",
          )
        },
      ),
      it(
        "the SCRAM login failed: the nonce of the server does not extend the nonce of the client",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.ConnectFailed(
                error.ScramFailed(error.ServerNonceMismatch("abc")),
              ),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Unavailable(
            "the SCRAM login failed: the nonce of the server does not extend the nonce of the client",
            failure,
          ))
          |> or_fail_with(
            "Expected Unavailable with the message: the SCRAM login failed: the nonce of the server does not extend the nonce of the client",
          )
        },
      ),
      it("the SCRAM login failed: the salt is not base64", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.ConnectFailed(error.ScramFailed(error.InvalidSalt("!"))),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Unavailable(
          "the SCRAM login failed: the salt is not base64",
          failure,
        ))
        |> or_fail_with(
          "Expected Unavailable with the message: the SCRAM login failed: the salt is not base64",
        )
      }),
      it("the SCRAM login failed: the iteration count 0 is not 1 or more", fn() {
        // Arrange
        let failure =
          postgres_failure.with_reason(
            error.ConnectFailed(
              error.ScramFailed(error.InvalidIterationCount("0")),
            ),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Unavailable(
          "the SCRAM login failed: the iteration count 0 is not 1 or more",
          failure,
        ))
        |> or_fail_with(
          "Expected Unavailable with the message: the SCRAM login failed: the iteration count 0 is not 1 or more",
        )
      }),
      it(
        "the SCRAM login failed: the server-final-message does not have the form of RFC 5802",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.ConnectFailed(
                error.ScramFailed(error.InvalidServerFinalMessage(<<"x">>)),
              ),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Unavailable(
            "the SCRAM login failed: the server-final-message does not have the form of RFC 5802",
            failure,
          ))
          |> or_fail_with(
            "Expected Unavailable with the message: the SCRAM login failed: the server-final-message does not have the form of RFC 5802",
          )
        },
      ),
      it(
        "the SCRAM login failed: the server ended the exchange with the error invalid-proof",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.ConnectFailed(
                error.ScramFailed(error.ServerReportedError("invalid-proof")),
              ),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Unavailable(
            "the SCRAM login failed: the server ended the exchange with the error invalid-proof",
            failure,
          ))
          |> or_fail_with(
            "Expected Unavailable with the message: the SCRAM login failed: the server ended the exchange with the error invalid-proof",
          )
        },
      ),
      it(
        "the SCRAM login failed: the signature of the server is wrong, so the server does not know the password",
        fn() {
          // Arrange
          let failure =
            postgres_failure.with_reason(
              error.ConnectFailed(error.ScramFailed(
                error.ServerSignatureMismatch,
              )),
            )

          // Act
          let found = error.to_dream_error(failure)

          // Assert
          found
          |> should
          |> be_equal(Unavailable(
            "the SCRAM login failed: the signature of the server is wrong, so the server does not know the password",
            failure,
          ))
          |> or_fail_with(
            "Expected Unavailable with the message: the SCRAM login failed: the signature of the server is wrong, so the server does not know the password",
          )
        },
      ),
    ]),
    group("the query name", [
      it("puts the query name in front of the message", fn() {
        // Arrange
        let failure =
          PostgresError(
            query_name: Some("user.create"),
            sql: Some("insert into users"),
            reason: error.Server(server_error.with_sql_state(
              sql_state.UniqueViolation,
              Some("users_email_key"),
            )),
          )

        // Act
        let found = error.to_dream_error(failure)

        // Assert
        found
        |> should
        |> be_equal(Conflict(
          "user.create: the message (23505, constraint users_email_key)",
          failure,
        ))
        |> or_fail_with(
          "Expected the query name user.create in front of the message",
        )
      }),
    ]),
    group("no_rows", [
      it("is NotFound with the query name", fn() {
        // Arrange
        let name = Some("user.find")

        // Act
        let found = error.no_rows(name)

        // Assert
        found
        |> should
        |> be_equal(NotFound("user.find: the query returned no row"))
        |> or_fail_with("Expected NotFound with the name user.find in front")
      }),
      it("is NotFound with no name", fn() {
        // Arrange
        let name = None

        // Act
        let found = error.no_rows(name)

        // Assert
        found
        |> should
        |> be_equal(NotFound("the query returned no row"))
        |> or_fail_with("Expected NotFound with no name in front")
      }),
    ]),
    group("server_error_from_report", [
      it("keeps every field of the report", fn() {
        // Arrange
        let report = server_reports.unique_violation("ERROR")

        // Act
        let found = error.server_error_from_report(report)

        // Assert
        found
        |> should
        |> be_equal(
          ServerError(
            severity: error.ErrorSeverity,
            sql_state: sql_state.UniqueViolation,
            message: "duplicate key value violates unique constraint",
            detail: Some("Key (email)=(a@b) already exists."),
            hint: Some("a hint"),
            position: Some(8),
            internal_position: Some(3),
            internal_query: Some("select 1"),
            context: Some("SQL function"),
            schema: Some("public"),
            table: Some("users"),
            column: Some("email"),
            data_type: Some("text"),
            constraint: Some("users_email_key"),
            file: Some("nbtinsert.c"),
            line: Some(666),
            routine: Some("_bt_check_unique"),
            localized_severity: "FEHLER",
            other_fields: [#(90, "a field of a newer server")],
          ),
        )
        |> or_fail_with(
          "Expected every field of the report in the server error",
        )
      }),
      it("reads the severity ERROR", fn() {
        // Arrange
        let report = server_reports.unique_violation("ERROR")

        // Act
        let found = error.server_error_from_report(report)

        // Assert
        found.severity
        |> should
        |> be_equal(error.ErrorSeverity)
        |> or_fail_with("Expected ErrorSeverity for the severity ERROR")
      }),
      it("reads the severity FATAL", fn() {
        // Arrange
        let report = server_reports.unique_violation("FATAL")

        // Act
        let found = error.server_error_from_report(report)

        // Assert
        found.severity
        |> should
        |> be_equal(error.FatalSeverity)
        |> or_fail_with("Expected FatalSeverity for the severity FATAL")
      }),
      it("reads the severity PANIC", fn() {
        // Arrange
        let report = server_reports.unique_violation("PANIC")

        // Act
        let found = error.server_error_from_report(report)

        // Assert
        found.severity
        |> should
        |> be_equal(error.PanicSeverity)
        |> or_fail_with("Expected PanicSeverity for the severity PANIC")
      }),
      it("reads the severity WARNING", fn() {
        // Arrange
        let report = server_reports.unique_violation("WARNING")

        // Act
        let found = error.server_error_from_report(report)

        // Assert
        found.severity
        |> should
        |> be_equal(error.WarningSeverity)
        |> or_fail_with("Expected WarningSeverity for the severity WARNING")
      }),
      it("reads the severity NOTICE", fn() {
        // Arrange
        let report = server_reports.unique_violation("NOTICE")

        // Act
        let found = error.server_error_from_report(report)

        // Assert
        found.severity
        |> should
        |> be_equal(error.NoticeSeverity)
        |> or_fail_with("Expected NoticeSeverity for the severity NOTICE")
      }),
      it("reads the severity DEBUG", fn() {
        // Arrange
        let report = server_reports.unique_violation("DEBUG")

        // Act
        let found = error.server_error_from_report(report)

        // Assert
        found.severity
        |> should
        |> be_equal(error.DebugSeverity)
        |> or_fail_with("Expected DebugSeverity for the severity DEBUG")
      }),
      it("reads the severity INFO", fn() {
        // Arrange
        let report = server_reports.unique_violation("INFO")

        // Act
        let found = error.server_error_from_report(report)

        // Assert
        found.severity
        |> should
        |> be_equal(error.InfoSeverity)
        |> or_fail_with("Expected InfoSeverity for the severity INFO")
      }),
      it("reads the severity LOG", fn() {
        // Arrange
        let report = server_reports.unique_violation("LOG")

        // Act
        let found = error.server_error_from_report(report)

        // Assert
        found.severity
        |> should
        |> be_equal(error.LogSeverity)
        |> or_fail_with("Expected LogSeverity for the severity LOG")
      }),
      it("reads the severity SHOUT", fn() {
        // Arrange
        let report = server_reports.unique_violation("SHOUT")

        // Act
        let found = error.server_error_from_report(report)

        // Assert
        found.severity
        |> should
        |> be_equal(error.UnlistedSeverity("SHOUT"))
        |> or_fail_with(
          "Expected UnlistedSeverity(\"SHOUT\") for the severity SHOUT",
        )
      }),
    ]),
    group("accessors", [
      it("reads the server error of a server failure", fn() {
        // Arrange
        let failure =
          error.to_dream_error(
            postgres_failure.with_reason(
              error.Server(server_error.with_sql_state(
                sql_state.UniqueViolation,
                Some("users_email_key"),
              )),
            ),
          )

        // Act
        let found = error.server_error(failure)

        // Assert
        found
        |> should
        |> be_some()
        |> be_equal(server_error.with_sql_state(
          sql_state.UniqueViolation,
          Some("users_email_key"),
        ))
        |> or_fail_with("Expected the unique violation of the server failure")
      }),
      it("reads the server error of a refused login", fn() {
        // Arrange
        let failure =
          error.to_dream_error(
            postgres_failure.with_reason(
              error.ConnectFailed(
                error.LoginRefused(server_error.with_sql_state(
                  sql_state.UniqueViolation,
                  Some("users_email_key"),
                )),
              ),
            ),
          )

        // Act
        let found = error.server_error(failure)

        // Assert
        found
        |> should
        |> be_some()
        |> be_equal(server_error.with_sql_state(
          sql_state.UniqueViolation,
          Some("users_email_key"),
        ))
        |> or_fail_with("Expected the unique violation of the refused login")
      }),
      it("reads the server error of the step of a failed rollback", fn() {
        // Arrange
        let step_error =
          error.to_dream_error(
            postgres_failure.with_reason(
              error.Server(server_error.with_sql_state(
                sql_state.UniqueViolation,
                Some("users_email_key"),
              )),
            ),
          )
        let failure =
          error.to_dream_error(transaction.keep_both(
            step_error,
            postgres_failure.with_reason(error.PoolStopped),
          ))

        // Act
        let found = error.server_error(failure)

        // Assert
        found
        |> should
        |> be_some()
        |> be_equal(server_error.with_sql_state(
          sql_state.UniqueViolation,
          Some("users_email_key"),
        ))
        |> or_fail_with("Expected the unique violation of the failed step")
      }),
      it("reads the server error of a commit that rolled back", fn() {
        // Arrange
        let failure =
          error.to_dream_error(
            postgres_failure.with_reason(
              error.CommitRolledBack(
                Some(server_error.with_sql_state(
                  sql_state.UniqueViolation,
                  Some("users_email_key"),
                )),
              ),
            ),
          )

        // Act
        let found = error.server_error(failure)

        // Assert
        found
        |> should
        |> be_some()
        |> be_equal(server_error.with_sql_state(
          sql_state.UniqueViolation,
          Some("users_email_key"),
        ))
        |> or_fail_with(
          "Expected the unique violation of the commit that rolled back",
        )
      }),
      it("has the server error of a later statement of a `run_sql` call", fn() {
        // Arrange
        let failure =
          error.to_dream_error(
            postgres_failure.with_reason(error.SqlStatementFailed(
              statements_run: 1,
              server_error: server_error.with_sql_state(
                sql_state.UniqueViolation,
                Some("users_email_key"),
              ),
            )),
          )

        // Act
        let found = error.server_error(failure)

        // Assert
        found
        |> should
        |> be_some()
        |> be_equal(server_error.with_sql_state(
          sql_state.UniqueViolation,
          Some("users_email_key"),
        ))
        |> or_fail_with(
          "Expected the unique violation of the `run_sql` call statement",
        )
      }),
      it("has no server error for a timeout", fn() {
        // Arrange
        let failure =
          error.to_dream_error(
            postgres_failure.with_reason(error.QueryTimeout(
              stopped_on_server: True,
            )),
          )

        // Act
        let found = error.server_error(failure)

        // Assert
        found
        |> should
        |> be_none()
        |> or_fail_with("Expected no server error for a query timeout")
      }),
      it("has no server error for NotFound", fn() {
        // Arrange
        let failure = error.no_rows(None)

        // Act
        let found = error.server_error(failure)

        // Assert
        found
        |> should
        |> be_none()
        |> or_fail_with("Expected no server error for NotFound")
      }),
      it("reads the SQLSTATE", fn() {
        // Arrange
        let failure =
          error.to_dream_error(
            postgres_failure.with_reason(
              error.Server(server_error.with_sql_state(
                sql_state.UniqueViolation,
                Some("users_email_key"),
              )),
            ),
          )

        // Act
        let found = error.sql_state(failure)

        // Assert
        found
        |> should
        |> be_some()
        |> be_equal(sql_state.UniqueViolation)
        |> or_fail_with("Expected the SQLSTATE UniqueViolation")
      }),
      it("reads the constraint name", fn() {
        // Arrange
        let failure =
          error.to_dream_error(
            postgres_failure.with_reason(
              error.Server(server_error.with_sql_state(
                sql_state.UniqueViolation,
                Some("users_email_key"),
              )),
            ),
          )

        // Act
        let found = error.constraint_name(failure)

        // Assert
        found
        |> should
        |> be_some()
        |> be_equal("users_email_key")
        |> or_fail_with("Expected the constraint name users_email_key")
      }),
      it("reads the table name", fn() {
        // Arrange
        let failure =
          error.to_dream_error(
            postgres_failure.with_reason(
              error.Server(server_error.with_sql_state(
                sql_state.UniqueViolation,
                Some("users_email_key"),
              )),
            ),
          )

        // Act
        let found = error.table_name(failure)

        // Assert
        found
        |> should
        |> be_some()
        |> be_equal("users")
        |> or_fail_with("Expected the table name users")
      }),
      it("reads the column name", fn() {
        // Arrange
        let failure =
          error.to_dream_error(
            postgres_failure.with_reason(
              error.Server(server_error.with_sql_state(
                sql_state.UniqueViolation,
                Some("users_email_key"),
              )),
            ),
          )

        // Act
        let found = error.column_name(failure)

        // Assert
        found
        |> should
        |> be_some()
        |> be_equal("email")
        |> or_fail_with("Expected the column name email")
      }),
      it("describes a failure for a log line", fn() {
        // Arrange
        let failure =
          error.to_dream_error(
            postgres_failure.with_reason(error.QueryTimeout(
              stopped_on_server: True,
            )),
          )

        // Act
        let found = error.describe(failure)

        // Assert
        found
        |> should
        |> be_equal("timeout: the query did not finish in time")
        |> or_fail_with(
          "Expected the kind timeout and the message of a query timeout",
        )
      }),
    ]),
  ])
}
