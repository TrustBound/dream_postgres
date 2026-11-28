//// The errors of dream_postgres.
////
//// Every function that runs a query returns
//// `Result(a, dream_errors.Error(PostgresError))`. The dream_errors variant
//// says what kind of failure it is, and the `PostgresError` cause keeps
//// everything that is known about it: the query's name, its SQL text, and
//// the exact reason, with every field that PostgreSQL sent.
////
//// The accessors of this module read the most used details in one call:
////
//// ### Tell a missing field apart from other failures <a href="https://github.com/TrustBound/dream_postgres/blob/3.0.0/test/snippets/signup_errors.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
////
//// ```gleam
//// import dream_errors.{type Error}
//// import dream_postgres/error.{type PostgresError, column_name, sql_state}
//// import dream_postgres/sql_state.{NotNullViolation}
//// import gleam/option.{Some}
////
//// pub type SignupError {
////   /// The form has no value for this column.
////   MissingField(column: String)
////   /// Any other failure of the database.
////   DatabaseFailed(error: Error(PostgresError))
//// }
////
//// pub fn signup_error(error: Error(PostgresError)) -> SignupError {
////   case sql_state(error), column_name(error) {
////     Some(NotNullViolation), Some(column) -> MissingField(column)
////     _, _ -> DatabaseFailed(error)
////   }
//// }
//// ```

import dream_errors.{
  type Error, Conflict, Failed, Invalid, NotFound, Retry, Timeout, Unavailable,
}
import dream_postgres/driver/cell.{type Cell, type ServerReport, ServerReport}
import dream_postgres/error/messages.{
  column_text, statement_ran_text, statements_run_text, timeout_message,
}
import dream_postgres/posix.{type Posix}
import dream_postgres/sql_state.{
  type SqlState, CardinalityViolationClass, CaseNotFoundClass,
  ConfigurationFileErrorClass, ConnectionExceptionClass, DataExceptionClass,
  DeadlockDetected, DependentPrivilegeDescriptorsStillExistClass,
  DiagnosticsExceptionClass, ExternalRoutineExceptionClass,
  ExternalRoutineInvocationExceptionClass, FeatureNotSupportedClass,
  ForeignDataWrapperErrorClass, InsufficientResourcesClass,
  IntegrityConstraintViolationClass, InternalErrorClass,
  InvalidAuthorizationSpecificationClass, InvalidCatalogNameClass,
  InvalidCursorNameClass, InvalidCursorStateClass, InvalidGrantorClass,
  InvalidRoleSpecificationClass, InvalidSchemaNameClass,
  InvalidSqlStatementNameClass, InvalidTransactionInitiationClass,
  InvalidTransactionStateClass, InvalidTransactionTerminationClass,
  LocatorExceptionClass, LockNotAvailable, NoDataClass,
  ObjectNotInPrerequisiteStateClass, OperatorInterventionClass,
  PlPgsqlErrorClass, ProgramLimitExceededClass, QueryCanceled,
  SavepointExceptionClass, SerializationFailure, SnapshotFailureClass,
  SqlRoutineExceptionClass, SqlStatementNotYetCompleteClass,
  SuccessfulCompletionClass, SyntaxErrorOrAccessRuleViolationClass,
  SystemErrorClass, TransactionRollbackClass, TriggeredActionExceptionClass,
  TriggeredDataChangeViolationClass, UniqueViolation, UnlistedClass,
  WarningClass, WithCheckOptionViolationClass, XqueryErrorClass,
}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string

/// Everything that is known about a failure of dream_postgres.
pub type PostgresError {
  PostgresError(
    /// The name that `named` gave the query, if any.
    query_name: Option(String),
    /// The SQL text of the query, if the failure belongs to a query. The
    /// parameters are never kept here, because they can hold secrets.
    sql: Option(String),
    /// What went wrong.
    reason: Reason,
  )
}

/// What went wrong.
pub type Reason {
  /// PostgreSQL refused the query, or a command of the connection.
  ///
  /// The error does not say what state the transaction is in after it,
  /// because that follows from where the statement ran: outside a
  /// transaction there is none, and inside one a refused statement always
  /// leaves the transaction failed, so only a rollback can follow. `commit`
  /// reads the state from the connection itself.
  Server(ServerError)
  /// No connection to the server could be made.
  ConnectFailed(ConnectFailure)
  /// The connection broke while it was in use.
  ConnectionLost(LostReason)
  /// No connection of the pool was free before the deadline.
  NoConnection
  /// The query did not finish before its deadline. `stopped_on_server`
  /// says whether the query is known to run no more: the server confirmed
  /// its cancel, or no call of it was running. `False` means that the
  /// server did not confirm a cancel, so the query can still be running
  /// there, or the connection was closed.
  QueryTimeout(stopped_on_server: Bool)
  /// The server sent something that the protocol does not allow.
  ProtocolViolation(detail: String)
  /// The query has `expected` parameters, and `got` were given.
  ParameterCountMismatch(expected: Int, got: Int)
  /// The codec of a parameter does not take the type that PostgreSQL gave
  /// that parameter. `position` counts from 1, like `$1`.
  ParameterTypeMismatch(position: Int, database_type: String, codec: String)
  /// The row reader reads `expected` columns, and the result has `got`.
  ColumnCountMismatch(expected: Int, got: Int)
  /// The codec of a column does not take the column's type. `position`
  /// counts from 1.
  ColumnTypeMismatch(
    position: Int,
    name: String,
    database_type: String,
    codec: String,
  )
  /// `column_at` asked for a position that the result does not have.
  NoColumnAtPosition(position: Int, columns: Int)
  /// `column_named` asked for a name that the result does not have.
  NoColumnNamed(name: String)
  /// `column_named` asked for a name that more than one column has.
  AmbiguousColumnName(name: String, count: Int)
  /// The row reader reads the same column more than one time.
  ColumnReadTwice(position: Int, name: String)
  /// The row reader mixes `column` with `column_at` or `column_named`.
  MixedColumnReaders
  /// The row reader read other columns, or used other codecs, for a row
  /// than the check before the run found. A reader must not choose its
  /// columns or codecs from a value it read. `read` counts the reads of
  /// the row from 1.
  ReaderDependsOnValue(read: Int)
  /// The statement changed during the run, because its tables or types
  /// changed: the server made it prepare again two times in a row, or at
  /// a point where the client cannot check it again. Running the query
  /// again may succeed.
  StatementChangedDuringRun
  /// A codec could not write a parameter. `position` counts from 1.
  EncodeFailed(position: Int, reason: String)
  /// A column that the codec reads as never NULL was NULL.
  UnexpectedNull(position: Int, name: String)
  /// A value does not fit the codec, for example `infinity` read with a
  /// codec for finite timestamps.
  ValueOutOfRange(position: Int, name: String, value: String)
  /// A codec could not read a value.
  DecodeFailed(position: Int, name: String, reason: String)
  /// `one` or `maybe_one` got more than one row.
  TooManyRows(count: Int)
  /// The server answered the commit with a rollback, because an earlier
  /// statement of the transaction failed.
  CommitRolledBack(cause: Option(ServerError))
  /// An interceptor refused the query with its own reason.
  InterceptorFailed(reason: String)
  /// A connection of a recorder in playback mode got a request after the
  /// last request of its recording.
  RequestNotRecorded(sql: String)
  /// A connection of a recorder in playback mode got a request that is
  /// not the next request of its recording: the key of `recorder.match_on`
  /// is not the same. `recorded_sql` is the SQL of the next recorded
  /// request, and `sql` is the SQL of the request, both with the text
  /// secrets replaced.
  RequestNotMatched(recorded_sql: String, sql: String)
  /// A recorder in record mode could not write its recording file at
  /// `path`.
  RecordingNotWritten(path: String, reason: Posix)
  /// A recorder in playback mode found no recording file at `path`.
  RecordingNotFound(path: String)
  /// A recorder could not read its recording file at `path`.
  RecordingNotRead(path: String, reason: Posix)
  /// The file at `path` is not a recording of this format.
  RecordingNotDecoded(path: String, reason: json.DecodeError)
  /// Another recorder that runs holds the recording file at `path`.
  RecordingInUse(path: String)
  /// The process of the recorder did not start.
  RecorderNotStarted(reason: actor.StartError)
  /// The recorder of the connection is stopped.
  RecorderStopped
  /// The pool has no database, so it holds no connection: a pool under a
  /// supervisor whose recorder is in playback mode answers from the
  /// recording in place of a connection.
  PoolHasNoDatabase
  /// A recorder could not write the replacement value of a secret column
  /// of `secrets.column`, so the answer is not saved.
  SecretColumnNotReplaced(column: String, reason: String)
  /// A COPY statement went to a query runner or a `run_sql` call. A query runner
  /// and a `run_sql` call do not run COPY. `statements_run` is the number of
  /// statements of the `run_sql` call that ran before it. Outside a transaction,
  /// they are committed.
  CopyStatementRefused(statements_run: Int)
  /// The SQL of `copy_from` or `copy_to` did not start a COPY of that
  /// direction. `statement_ran` is `True` when the statement ran to its
  /// end: a statement that is not a COPY, or a COPY to the client given to
  /// `copy_from`, whose rows were dropped. Outside a transaction, its
  /// changes are committed. It is `False` for a COPY from the client given
  /// to `copy_to`, which stored no row.
  CopyNotStarted(statement_ran: Bool)
  /// PostgreSQL refused a later statement of a `run_sql` call, after
  /// `statements_run` statements of it ran. Outside a transaction, the
  /// statements that ran are committed.
  SqlStatementFailed(statements_run: Int, server_error: ServerError)
  /// A chunk or the end came for a COPY that does not run any more.
  CopyNotRunning
  /// The request could not be written to the server, for example SQL that
  /// holds a zero byte.
  RequestNotWritable(fault: RequestFault)
  /// The process that owns the connection is gone.
  ConnectionProcessDown
  /// The database has no type with this OID, also after the type catalog
  /// loaded again.
  UnknownType(type_id: Int)
  /// The rows of the type catalog query do not make a catalog.
  UnreadableCatalog(fault: CatalogFault)
  /// The process that keeps the type catalog is gone.
  CatalogProcessDown
  /// The server sent bytes that are not a valid message.
  UndecodableServerMessage(fault: MessageFault)
  /// The server sent a valid message that the protocol does not allow at
  /// this step of a request. The contents of the message are not kept,
  /// because they can hold the values of rows.
  UnexpectedServerMessage(message: ServerMessageKind, step: ProtocolStep)
  /// The server sent a message between requests that is not a parameter
  /// change, a notice, a notification or an error.
  UnexpectedIdleMessage(message: ServerMessageKind)
  /// A setting of the config is not valid. Nothing was started.
  InvalidConfig(fault: ConfigFault)
  /// The pool process did not start.
  PoolStartFailed(failure: PoolStartFailure)
  /// The pool is stopped, or it is gone.
  PoolStopped
  /// `verify` was given a connection with no database, such as the
  /// connection of a recorder in playback mode, so no query was checked.
  NoDatabaseToVerify
  /// A transaction inside a transaction sets an isolation level or read
  /// only. It runs as a savepoint, and a savepoint cannot change them.
  OptionsInNestedTransaction
  /// The server answered `COMMIT` with other command tags than `COMMIT`
  /// or `ROLLBACK`.
  UnexpectedCommitAnswer(tags: List(String))
  /// A step of a transaction failed, and the `ROLLBACK` after it (or the
  /// `ROLLBACK TO SAVEPOINT` of a nested transaction) also failed.
  /// `dream_postgres/transaction.keep_both` gives this reason: it keeps
  /// the error of the step and the error of the rollback.
  RollbackAlsoFailed(
    step_error: Error(PostgresError),
    rollback_error: PostgresError,
  )
  /// A field of `copy_from`, or a column that the row reader of `copy_to`
  /// reads, has a codec in the text format. A binary COPY needs a codec in
  /// the binary format, as every codec of `dream_postgres/codecs` is except
  /// `custom`. `position` counts from 1.
  CopyNeedsBinaryCodec(position: Int, name: String, codec: String)
  /// The query of `copy_to` has `count` parameters. PostgreSQL takes no
  /// parameters in a COPY statement, so nothing was sent.
  CopyQueryHasParameters(count: Int)
  /// The binary COPY data that the server sent is not valid.
  MalformedCopyStream(fault: CopyStreamFault)
  /// The channel name of `listen` has more than 63 bytes. PostgreSQL cuts
  /// such a name short, so its notifications would come with another name.
  /// Nothing was sent.
  ChannelTooLong(channel: String)
  /// The subject of `listen` has no process: it has a name that no process
  /// has.
  SubscriberHasNoProcess
  /// The server answered a `LISTEN` as no PostgreSQL server does: with an
  /// error after a first result, or with a COPY.
  UnexpectedListenAnswer
  /// The listener is stopped, or it is gone.
  ListenerStopped
  /// The listener process did not start.
  ListenerStartFailed(failure: ListenerStartFailure)
}

/// Why the listener process did not start.
pub type ListenerStartFailure {
  /// The listener process did not start in time.
  ListenerStartTimedOut
  /// The listener process refused to start, with its message.
  ListenerInitFailed(message: String)
  /// The listener process exited during its start.
  ListenerProcessExited(reason: String)
}

/// Why the binary COPY data of the server is not valid.
pub type CopyStreamFault {
  /// The data does not start with the signature of the binary COPY
  /// format.
  InvalidCopySignature
  /// The header sets a flag that the client cannot read, for example the
  /// flag of OID columns.
  UnsupportedCopyFlags(flags: Int)
  /// A tuple gives a field count below -1. A count of -1 is the trailer.
  InvalidCopyFieldCount(count: Int)
  /// A field gives a length below -1. A length of -1 is NULL.
  InvalidCopyFieldLength(length: Int)
  /// The data ended before its trailer.
  CopyStreamCutShort
  /// Bytes came after the trailer.
  BytesAfterCopyTrailer
}

/// Why a setting of the config is not valid.
pub type ConfigFault {
  /// The host is empty, or holds a space, a control character or a
  /// character outside ASCII.
  InvalidHost(host: String)
  /// The port is outside 1 to 65535.
  InvalidPort(port: Int)
  /// The pool size is below 1.
  InvalidPoolSize(size: Int)
  /// The health check interval is below 1 millisecond.
  InvalidHealthCheckInterval(milliseconds: Int)
  /// The connect timeout is below 1 millisecond.
  InvalidConnectTimeout(milliseconds: Int)
  /// The setup timeout is below 1 millisecond.
  InvalidSetupTimeout(milliseconds: Int)
  /// The cancel timeout is below 1 millisecond.
  InvalidCancelTimeout(milliseconds: Int)
  /// The return rollback timeout is below 1 millisecond.
  InvalidReturnRollbackTimeout(milliseconds: Int)
  /// The user name is empty.
  EmptyUser
  /// The password holds a zero byte.
  ZeroByteInPassword
  /// A startup parameter name or value holds a zero byte. The user and
  /// the database are startup parameters too.
  ZeroByteInParameter(name: String)
  /// A startup parameter has an empty name.
  EmptyParameterName
  /// A startup parameter is given two times.
  DuplicateParameter(name: String)
  /// A `client_encoding` other than UTF-8.
  UnsupportedClientEncoding(value: String)
  /// The startup message of the login settings has `length` bytes, which
  /// is too long for its 32-bit length field.
  StartupMessageTooLong(length: Int)
  /// The URL of `url.config_from_url` is not valid.
  InvalidDatabaseUrl(fault: UrlFault)
}

/// Why the URL of `url.config_from_url` is not valid. No fault
/// holds the password of the URL.
pub type UrlFault {
  /// The URL has no `://` after its scheme.
  MissingScheme
  /// The scheme is not `postgres` or `postgresql`.
  UnsupportedScheme(scheme: String)
  /// The URL names more than one host, as libpq takes for a fallback
  /// list. dream_postgres connects to one host.
  MultipleHosts
  /// A host in square brackets has no closing bracket, or has text after
  /// the bracket that is not `:` and a port.
  MalformedBracketedHost
  /// The host is an absolute path: libpq takes it as the directory of a
  /// Unix socket. dream_postgres connects only over TCP.
  UnixSocketHost(path: String)
  /// The URL has no host: libpq takes it as the default Unix socket.
  /// dream_postgres connects only over TCP.
  UnixSocketNotSupported
  /// The port is not a number in 1 to 65535.
  InvalidUrlPort(port: String)
  /// A part of the URL has a `%` that is not followed by two hex digits,
  /// or decodes to bytes that are not UTF-8.
  InvalidPercentEncoding(part: UrlPart)
  /// A query parameter has no `=`.
  ParameterWithoutValue(name: String)
  /// A query parameter that the client does not take, such as
  /// `connect_timeout` or `application_name`.
  UnsupportedParameter(name: String)
  /// A query parameter is given more than one time.
  ParameterGivenTwice(name: String)
  /// The `sslmode` is not a mode of libpq.
  UnknownSslMode(mode: String)
  /// The `sslmode` is a mode of libpq that the client does not have:
  /// `allow`.
  UnsupportedSslMode(mode: String)
  /// The `sslnegotiation` is not `postgres` or `direct`.
  UnknownSslNegotiation(negotiation: String)
  /// `sslnegotiation=direct` with an `sslmode` below `require`. libpq
  /// refuses it too, because the connection could fall back to plain TCP.
  DirectNegotiationNeedsRequiredTls(mode: String)
  /// An `sslrootcert` file with an `sslmode` that checks no certificate.
  RootCertificateNeedsCertificateCheck(mode: String)
  /// `sslrootcert=system` with an `sslmode` below `verify-full`. libpq
  /// refuses it too, because anyone can get a certificate that the system
  /// trusts for a host they own.
  SystemRootCertificateNeedsVerifyFull(mode: String)
}

/// A part of a database URL.
pub type UrlPart {
  UrlUser
  UrlPassword
  UrlHost
  UrlDatabase
  UrlParameters
}

/// Why the pool process did not start.
pub type PoolStartFailure {
  /// The pool process did not finish its start in time.
  PoolStartTimedOut
  /// The pool process refused to start, with its message.
  PoolInitFailed(message: String)
  /// The pool process exited during its start, with its exit reason.
  PoolProcessExited(reason: String)
}

/// Why the certificate of the server gives no channel binding data.
pub type CertificateFault {
  /// The bytes are not the DER form of an X.509 certificate.
  InvalidCertificate
  /// The signature algorithm of the certificate names no hash function
  /// that channel binding can use. The value is its object identifier.
  UnsupportedSignatureAlgorithm(object_identifier: List(Int))
}

/// Why the SCRAM exchange of a login failed.
pub type ScramFault {
  /// The server-first-message does not have the form of RFC 5802.
  InvalidServerFirstMessage(message: BitArray)
  /// The server-first-message starts with the reserved attribute `m=`.
  MandatoryExtension(attribute: String)
  /// The nonce of the server does not start with the nonce of the client,
  /// or adds nothing to it.
  ServerNonceMismatch(server_nonce: String)
  /// The nonce of the server has `length` bytes, too many for the
  /// client-final-message to fit in a SASL message.
  ServerNonceTooLong(length: Int)
  /// The salt is not base64.
  InvalidSalt(salt: String)
  /// The iteration count is not a whole number of 1 or more.
  InvalidIterationCount(iteration_count: String)
  /// The server-final-message is not `v=<signature>` or `e=<error>`.
  InvalidServerFinalMessage(message: BitArray)
  /// The server ended the exchange with an error, for example
  /// `invalid-proof`.
  ServerReportedError(error: String)
  /// The signature of the server is not the one that the password gives,
  /// so the server does not know the password.
  ServerSignatureMismatch
}

/// Why a request could not be written to the server.
pub type RequestFault {
  /// A string field holds a zero byte, which would end it early.
  ZeroByteInString(field: String)
  /// A list has more items than a 16-bit count can give (65535).
  TooManyItems(field: String, count: Int)
  /// A number is outside the range of its wire field.
  NumberOutOfRange(field: String, value: Int)
  /// A cancel secret key shorter than 4 or longer than 256 bytes.
  SecretKeyLengthOutOfRange(length: Int)
  /// A value or a message is longer than a 32-bit length can give.
  MessageTooLong(length: Int)
}

/// Why the rows of the type catalog query do not make a catalog.
pub type CatalogFault {
  /// A row that does not have the shape of the catalog query's rows.
  UnreadableRow(row: List(Cell))
  /// A type whose `typtype` is not one that PostgreSQL 16 to 19 have.
  UnknownTypeKind(type_id: Int, kind: String)
  /// A part of a type that is not a type of the rows.
  MissingPart(type_id: Int, part_type_id: Int)
  /// A domain whose chain of base types comes back to a domain of the
  /// chain.
  CircularDomain(type_id: Int)
  /// The server answered the catalog query as no PostgreSQL server
  /// answers it: with a COPY, or with an error after a result.
  UnexpectedCatalogAnswer
}

/// Why bytes from the server are not a valid message.
pub type MessageFault {
  /// A type byte that names no backend message.
  UnknownMessageType(type_byte: Int)
  /// A length field below 4, the size of the length field itself.
  InvalidMessageLength(type_byte: Int, length: Int)
  /// The body does not have the layout of its message type, or has bytes
  /// after its last field.
  InvalidMessageBody(type_byte: Int)
  /// A text field that is not valid UTF-8.
  InvalidUtf8(type_byte: Int)
  /// An Authentication message with a request code that the protocol does
  /// not define.
  UnknownAuthenticationRequest(code: Int)
  /// A ReadyForQuery status that is not `I`, `T` or `E`.
  UnknownTransactionStatus(status_byte: Int)
  /// A format code that is not 0 (text) or 1 (binary).
  UnknownFormatCode(type_byte: Int, code: Int)
  /// A BackendKeyData secret key shorter than 4 or longer than 256 bytes.
  InvalidSecretKeyLength(length: Int)
  /// An ErrorResponse or NoticeResponse without a field that is always
  /// present: `S`, `V`, `C` or `M`.
  MissingReportField(type_byte: Int, field_code: Int)
  /// A report field that must be a decimal integer (`P`, `p` or `L`) but is
  /// not.
  InvalidReportNumber(type_byte: Int, field_code: Int, value: String)
}

/// The kind of a message that the server sent, by its name in the
/// PostgreSQL protocol.
pub type ServerMessageKind {
  AuthenticationOk
  AuthenticationKerberosV5
  AuthenticationCleartextPassword
  AuthenticationMd5Password
  AuthenticationGss
  AuthenticationGssContinue
  AuthenticationSspi
  AuthenticationSasl
  AuthenticationSaslContinue
  AuthenticationSaslFinal
  BackendKeyData
  BindComplete
  CloseComplete
  CommandComplete
  CopyData
  CopyDone
  CopyInResponse
  CopyOutResponse
  CopyBothResponse
  DataRow
  EmptyQueryResponse
  ErrorResponse
  FunctionCallResponse
  NegotiateProtocolVersion
  NoData
  NoticeResponse
  NotificationResponse
  ParameterDescription
  ParameterStatus
  ParseComplete
  PortalSuspended
  ReadyForQuery
  RowDescription
}

/// What the client waited for when an unexpected message came.
pub type ProtocolStep {
  /// ParseComplete, the answer to Parse.
  AwaitingParseComplete
  /// ParameterDescription, the first answer to a Describe of a statement.
  AwaitingParameterDescription
  /// RowDescription or NoData, the second answer to a Describe of a
  /// statement.
  AwaitingStatementColumns
  /// BindComplete, the answer to Bind.
  AwaitingBindComplete
  /// RowDescription or NoData, the answer to a Describe of a portal.
  AwaitingPortalColumns
  /// DataRow, or the end of an Execute.
  ReadingExecuteRows
  /// The start of the next result of a `run_sql` call.
  AwaitingStatementResult
  /// DataRow or CommandComplete of a statement of a `run_sql` call.
  ReadingSqlRows
  /// CopyData or CopyDone, in a COPY that the client refused.
  ReadingCopyOut
  /// The end of a COPY that the client refused.
  AwaitingCopyComplete
  /// ReadyForQuery, after the last answer of a request.
  AwaitingReadyForQuery
  /// ReadyForQuery, after an ErrorResponse.
  AwaitingReadyForQueryAfterError
  AwaitingCloseComplete
  CopyingIn
}

/// Every field of an error that PostgreSQL sent.
pub type ServerError {
  ServerError(
    severity: Severity,
    sql_state: SqlState,
    message: String,
    detail: Option(String),
    hint: Option(String),
    /// A 1-based character position in the query text.
    position: Option(Int),
    internal_position: Option(Int),
    internal_query: Option(String),
    /// The call stack of the error, for example the function that raised it.
    context: Option(String),
    schema: Option(String),
    table: Option(String),
    column: Option(String),
    data_type: Option(String),
    constraint: Option(String),
    file: Option(String),
    line: Option(Int),
    routine: Option(String),
    /// The severity in the server's language.
    localized_severity: String,
    /// Any field that this record does not name, with its type byte.
    other_fields: List(#(Int, String)),
  )
}

/// The severity of a server error or notice.
pub type Severity {
  ErrorSeverity
  FatalSeverity
  PanicSeverity
  WarningSeverity
  NoticeSeverity
  DebugSeverity
  InfoSeverity
  LogSeverity
  /// A severity that this module does not name.
  UnlistedSeverity(name: String)
}

/// Why no connection could be made.
pub type ConnectFailure {
  /// The host name did not resolve.
  HostNotFound(host: String)
  /// The host refused the connection.
  ConnectionRefused(host: String, port: Int)
  /// No answer came before the connect deadline.
  ConnectTimedOut(host: String, port: Int)
  /// The TLS handshake failed.
  TlsFailed(reason: TlsFailure)
  /// The server refused the login or the session, with its error.
  LoginRefused(ServerError)
  /// The server asked for a login method that dream_postgres does not have.
  UnsupportedLoginMethod(name: String)
  /// The operating system refused the connection.
  OsRefused(error: Posix)
  /// The connection broke during the login.
  ConnectionBroke(reason: LostReason)
  /// The server closed the connection during the TCP connect or the TLS
  /// handshake.
  ConnectClosed(host: String, port: Int)
  /// The connection was reset during the TCP connect or the TLS
  /// handshake, for example by a proxy or a firewall.
  ConnectReset(host: String, port: Int)
  /// A login message could not be sent, for example because the server
  /// read nothing of it within the send timeout.
  LoginSendFailed(reason: LostReason)
  /// The server asks for a password with this login method, and the
  /// config has none.
  PasswordRequired(method: String)
  /// The server sent a message during the login that the login does not
  /// expect at that step.
  UnexpectedLoginMessage(message: ServerMessageKind)
  /// The server sent bytes during the login that are not a valid message.
  UndecodableLoginMessage(fault: MessageFault)
  /// The server asks for a cleartext password, and the password has
  /// `length` bytes, more than the driver sends. No password went to the
  /// server.
  PasswordTooLong(length: Int)
  /// The connect and the login did not finish within the setup timeout.
  SetupTimedOut
  /// The connection process exited while it connected.
  SetupProcessExited
  /// The password that the config gave at login time holds a zero byte.
  /// No password went to the server.
  PasswordHasZeroByte
  /// The login requires channel binding, and the connection has no TLS.
  ChannelBindingRequiresTls
  /// The login requires channel binding, and the server asks for a login
  /// method that does not bind to the channel.
  ChannelBindingNotOffered(method: String)
  /// The server offers channel binding on a connection with no TLS, so
  /// something between the client and the server may have removed it.
  ChannelBindingOfferedWithoutTls
  /// The certificate of the server gives no channel binding data.
  CertificateHashFailed(fault: CertificateFault)
  /// The SCRAM exchange failed.
  ScramFailed(fault: ScramFault)
  /// The server answers with a protocol version that the client does not
  /// speak.
  UnsupportedProtocolVersion(major_version: Int, minor_version: Int)
}

/// Why a TLS handshake failed.
pub type TlsFailure {
  /// The server does not speak TLS, and the config requires it.
  ServerHasNoTls
  /// No trusted authority signed the server's certificate.
  UnknownAuthority
  /// The server's certificate expired.
  CertificateExpired
  /// Any other TLS alert, with its name.
  TlsAlert(name: String)
  /// The server's certificate does not name the host that the connection
  /// asked for.
  CertificateHostMismatch
  /// The file of trusted authorities could not be read, with the error of
  /// the operating system.
  AuthorityFileUnreadable(path: String, reason: String)
  /// The file of trusted authorities holds no certificate.
  AuthorityFileEmpty(path: String)
  /// The server answered the TLS request with an error. Its text is not
  /// kept, because the server is not yet authenticated.
  TlsRequestAnsweredWithError
  /// The answer to the TLS request was not `S`, `N` or `E`.
  UnexpectedTlsAnswer(answer_byte: Int)
  /// The server sent bytes before the TLS handshake, which did not come
  /// over TLS.
  BytesBeforeTlsHandshake
}

/// Why a connection broke while it was in use.
pub type LostReason {
  /// The server closed the connection.
  ClosedByServer
  /// The client closed the connection because a deadline passed and the
  /// cancel of that query was not confirmed in time.
  ClosedAfterDeadline
  /// The connection was reset.
  Reset
  /// The TLS layer of the open connection sent or got an alert, for
  /// example `bad_record_mac`.
  TlsAlertRaised(alert: String)
  /// The operating system reported an error on the socket.
  OsError(error: Posix)
  /// The server read nothing within the send timeout of the connection.
  SendTimedOut
}

/// The dream_errors value of a failure, with the failure as its cause.
///
/// Every reason has its own clause. A server error maps by its SQLSTATE
/// class: every class has its own clause, so a new class of a newer server
/// is `Failed` only because `UnlistedClass` says so.
pub fn to_dream_error(error: PostgresError) -> Error(PostgresError) {
  let PostgresError(query_name:, sql: _, reason:) = error
  let prefix = case query_name {
    Some(name) -> name <> ": "
    None -> ""
  }
  case reason {
    Server(server_error) -> server_to_dream_error(prefix, server_error, error)
    ConnectFailed(failure) ->
      Unavailable(prefix <> connect_failure_message(failure), error)
    ConnectionLost(lost) ->
      Unavailable(prefix <> lost_reason_message(lost), error)
    NoConnection ->
      Unavailable(prefix <> "no database connection was free in time", error)
    QueryTimeout(stopped_on_server:) ->
      Timeout(prefix <> timeout_message(stopped_on_server), error)
    ProtocolViolation(detail:) ->
      Failed(prefix <> "the server broke the protocol: " <> detail, error)
    ParameterCountMismatch(expected:, got:) ->
      Failed(
        prefix
          <> "the query has "
          <> int.to_string(expected)
          <> " parameters, and "
          <> int.to_string(got)
          <> " were given",
        error,
      )
    ParameterTypeMismatch(position:, database_type:, codec:) ->
      Failed(
        prefix
          <> "parameter $"
          <> int.to_string(position)
          <> " is "
          <> database_type
          <> ", and the query gives it with the "
          <> codec
          <> " codec",
        error,
      )
    ColumnCountMismatch(expected:, got:) ->
      Failed(
        prefix
          <> "the row reader reads "
          <> int.to_string(expected)
          <> " columns, and the query returns "
          <> int.to_string(got),
        error,
      )
    ColumnTypeMismatch(position:, name:, database_type:, codec:) ->
      Failed(
        prefix
          <> column_text(position, name)
          <> " is "
          <> database_type
          <> ", and the query reads it with the "
          <> codec
          <> " codec",
        error,
      )
    NoColumnAtPosition(position:, columns:) ->
      Failed(
        prefix
          <> "the row reader reads column "
          <> int.to_string(position)
          <> ", and the query returns "
          <> int.to_string(columns)
          <> " columns",
        error,
      )
    NoColumnNamed(name:) ->
      Failed(prefix <> "the query returns no column named " <> name, error)
    AmbiguousColumnName(name:, count:) ->
      Failed(
        prefix
          <> int.to_string(count)
          <> " columns are named "
          <> name
          <> ", so the row reader cannot read it by name",
        error,
      )
    ColumnReadTwice(position:, name:) ->
      Failed(
        prefix
          <> "the row reader reads "
          <> column_text(position, name)
          <> " more than one time",
        error,
      )
    MixedColumnReaders ->
      Failed(
        prefix <> "the row reader mixes column with column_at or column_named",
        error,
      )
    StatementChangedDuringRun ->
      Retry(
        prefix
          <> "the statement changed during the run, because its tables or types changed",
        error,
        None,
      )
    ReaderDependsOnValue(read:) ->
      Failed(
        prefix
          <> "read "
          <> int.to_string(read)
          <> " of the row reader chose its column or codec from a value it read",
        error,
      )
    EncodeFailed(position:, reason:) ->
      Invalid(
        prefix
          <> "parameter $"
          <> int.to_string(position)
          <> " could not be written: "
          <> reason,
        error,
      )
    UnexpectedNull(position:, name:) ->
      Failed(
        prefix
          <> column_text(position, name)
          <> " is NULL, and the query reads it as not NULL",
        error,
      )
    ValueOutOfRange(position:, name:, value:) ->
      Failed(
        prefix
          <> column_text(position, name)
          <> " holds "
          <> value
          <> ", which its codec cannot read",
        error,
      )
    DecodeFailed(position:, name:, reason:) ->
      Failed(
        prefix
          <> column_text(position, name)
          <> " could not be read: "
          <> reason,
        error,
      )
    TooManyRows(count:) ->
      Failed(
        prefix
          <> "the query returned "
          <> int.to_string(count)
          <> " rows, and at most 1 was expected",
        error,
      )
    CommitRolledBack(cause: _) ->
      Failed(
        prefix
          <> "the server rolled the transaction back at commit, because a statement in it failed",
        error,
      )
    InterceptorFailed(reason:) ->
      Failed(prefix <> "an interceptor refused the query: " <> reason, error)
    RequestNotRecorded(sql:) ->
      Failed(
        prefix <> "the recording has no answer to the request: " <> sql,
        error,
      )
    RecordingNotWritten(path:, reason:) ->
      Failed(
        prefix
          <> "the recording "
          <> path
          <> " could not be written: "
          <> posix.name(reason),
        error,
      )
    RequestNotMatched(recorded_sql:, sql:) ->
      Failed(
        prefix
          <> "the request is not the next request of the recording: "
          <> sql
          <> ", the recording has: "
          <> recorded_sql,
        error,
      )
    RecordingNotFound(path:) ->
      Failed(prefix <> "the recording " <> path <> " does not exist", error)
    RecordingNotRead(path:, reason:) ->
      Failed(
        prefix
          <> "the recording "
          <> path
          <> " could not be read: "
          <> posix.name(reason),
        error,
      )
    RecordingNotDecoded(path:, reason: _) ->
      Failed(
        prefix <> "the file " <> path <> " is not a recording of this format",
        error,
      )
    RecordingInUse(path:) ->
      Failed(
        prefix <> "another recorder that runs holds the recording " <> path,
        error,
      )
    RecorderNotStarted(reason: _) ->
      Failed(prefix <> "the process of the recorder did not start", error)
    RecorderStopped -> Unavailable(prefix <> "the recorder is stopped", error)
    PoolHasNoDatabase ->
      Failed(
        prefix <> "the pool has no database, so it holds no connection",
        error,
      )
    SecretColumnNotReplaced(column:, reason:) ->
      Failed(
        prefix
          <> "the secret column "
          <> column
          <> " could not be replaced: "
          <> reason,
        error,
      )
    CopyStatementRefused(statements_run:) ->
      Failed(
        prefix
          <> "a COPY statement cannot run as a query"
          <> statements_run_text(statements_run),
        error,
      )
    CopyNotStarted(statement_ran:) ->
      Failed(
        prefix
          <> "the SQL did not start a COPY of the direction asked for"
          <> statement_ran_text(statement_ran),
        error,
      )
    SqlStatementFailed(statements_run:, server_error:) ->
      server_to_dream_error(
        prefix
          <> "the SQL failed after it ran "
          <> int.to_string(statements_run)
          <> " of its statements (outside a transaction they are committed): ",
        server_error,
        error,
      )
    CopyNotRunning -> Failed(prefix <> "the COPY does not run any more", error)
    RequestNotWritable(fault:) ->
      Invalid(
        prefix
          <> "the request could not be written: "
          <> request_fault_message(fault),
        error,
      )
    ConnectionProcessDown ->
      Unavailable(prefix <> "the connection process is gone", error)
    UnknownType(type_id:) ->
      Failed(
        prefix <> "the database has no type with OID " <> int.to_string(type_id),
        error,
      )
    UnreadableCatalog(fault:) ->
      Failed(
        prefix
          <> "the type catalog could not be read: "
          <> catalog_fault_message(fault),
        error,
      )
    CatalogProcessDown ->
      Unavailable(prefix <> "the type catalog process is gone", error)
    UndecodableServerMessage(fault:) ->
      Failed(
        prefix
          <> "the server broke the protocol: "
          <> message_fault_message(fault),
        error,
      )
    UnexpectedServerMessage(message:, step:) ->
      Failed(
        prefix
          <> "the server broke the protocol: it sent "
          <> server_message_name(message)
          <> " while the client waited for "
          <> protocol_step_text(step),
        error,
      )
    UnexpectedIdleMessage(message:) ->
      Failed(
        prefix
          <> "the server broke the protocol: it sent "
          <> server_message_name(message)
          <> " between requests",
        error,
      )
    InvalidConfig(fault:) ->
      Invalid(
        prefix <> "the config is not valid: " <> config_fault_message(fault),
        error,
      )
    PoolStartFailed(failure:) ->
      Failed(
        prefix <> "the pool did not start: " <> pool_start_message(failure),
        error,
      )
    PoolStopped -> Unavailable(prefix <> "the pool is stopped", error)
    NoDatabaseToVerify ->
      Failed(
        prefix <> "the connection has no database to check the queries against",
        error,
      )
    OptionsInNestedTransaction ->
      Failed(
        prefix
          <> "a transaction inside a transaction runs as a savepoint, so it cannot set an isolation level or read only",
        error,
      )
    RollbackAlsoFailed(step_error:, rollback_error:) ->
      Unavailable(
        prefix
          <> "the rollback after a failed step failed. The step: "
          <> dream_errors.message(step_error)
          <> ". The rollback: "
          <> dream_errors.message(to_dream_error(rollback_error)),
        error,
      )
    UnexpectedCommitAnswer(tags:) ->
      Failed(
        prefix
          <> "the server answered the commit with the tags ["
          <> string.join(tags, ", ")
          <> "]",
        error,
      )
    CopyNeedsBinaryCodec(position:, name:, codec:) ->
      Failed(
        prefix
          <> column_text(position, name)
          <> " has the "
          <> codec
          <> " codec in the text format, and a binary COPY needs a codec in the binary format",
        error,
      )
    CopyQueryHasParameters(count:) ->
      Failed(
        prefix
          <> "the query has "
          <> int.to_string(count)
          <> " parameters, and a COPY statement takes none",
        error,
      )
    MalformedCopyStream(fault:) ->
      Failed(
        prefix
          <> "the server broke the protocol: "
          <> copy_stream_fault_message(fault),
        error,
      )
    ChannelTooLong(channel:) ->
      Invalid(
        prefix <> "the channel name " <> channel <> " has more than 63 bytes",
        error,
      )
    SubscriberHasNoProcess ->
      Invalid(prefix <> "the subject of the subscription has no process", error)
    UnexpectedListenAnswer ->
      Failed(
        prefix
          <> "the server broke the protocol: it answered LISTEN with an error after a result, or with a COPY",
        error,
      )
    ListenerStopped -> Unavailable(prefix <> "the listener is stopped", error)
    ListenerStartFailed(failure:) ->
      Failed(
        prefix
          <> "the listener did not start: "
          <> listener_start_message(failure),
        error,
      )
  }
}

fn listener_start_message(failure: ListenerStartFailure) -> String {
  case failure {
    ListenerStartTimedOut -> "the listener process did not start in time"
    ListenerInitFailed(message:) ->
      "the listener process refused to start: " <> message
    ListenerProcessExited(reason:) ->
      "the listener process exited during its start: " <> reason
  }
}

fn copy_stream_fault_message(fault: CopyStreamFault) -> String {
  case fault {
    InvalidCopySignature ->
      "the COPY data does not start with the binary COPY signature"
    UnsupportedCopyFlags(flags:) ->
      "the COPY header sets the flags "
      <> int.to_string(flags)
      <> ", which the client cannot read"
    InvalidCopyFieldCount(count:) ->
      "a COPY tuple has the field count " <> int.to_string(count)
    InvalidCopyFieldLength(length:) ->
      "a COPY field has the length " <> int.to_string(length)
    CopyStreamCutShort -> "the COPY data ended before its trailer"
    BytesAfterCopyTrailer -> "the COPY data has bytes after its trailer"
  }
}

fn config_fault_message(fault: ConfigFault) -> String {
  case fault {
    InvalidHost(host:) -> "the host \"" <> host <> "\" is not a valid host"
    InvalidPort(port:) ->
      "the port " <> int.to_string(port) <> " is not in 1 to 65535"
    InvalidPoolSize(size:) ->
      "the pool size " <> int.to_string(size) <> " is below 1"
    InvalidHealthCheckInterval(milliseconds:) ->
      "the health check interval of "
      <> int.to_string(milliseconds)
      <> " milliseconds is below 1"
    InvalidConnectTimeout(milliseconds:) ->
      "the connect timeout of "
      <> int.to_string(milliseconds)
      <> " milliseconds is below 1"
    InvalidSetupTimeout(milliseconds:) ->
      "the setup timeout of "
      <> int.to_string(milliseconds)
      <> " milliseconds is below 1"
    InvalidCancelTimeout(milliseconds:) ->
      "the cancel timeout of "
      <> int.to_string(milliseconds)
      <> " milliseconds is below 1"
    InvalidReturnRollbackTimeout(milliseconds:) ->
      "the return rollback timeout of "
      <> int.to_string(milliseconds)
      <> " milliseconds is below 1"
    EmptyUser -> "the user is empty"
    ZeroByteInPassword -> "the password holds a zero byte"
    ZeroByteInParameter(name:) ->
      "the startup parameter " <> name <> " holds a zero byte"
    EmptyParameterName -> "a startup parameter has an empty name"
    DuplicateParameter(name:) ->
      "the startup parameter " <> name <> " is given more than one time"
    UnsupportedClientEncoding(value:) ->
      "the client encoding "
      <> value
      <> " is not UTF-8, and dream_postgres reads and writes only UTF-8"
    StartupMessageTooLong(length:) ->
      "the startup message has "
      <> int.to_string(length)
      <> " bytes, which is too long for its length field"
    InvalidDatabaseUrl(fault:) ->
      "the database URL is not valid: " <> url_fault_message(fault)
  }
}

fn url_fault_message(fault: UrlFault) -> String {
  case fault {
    MissingScheme -> "it does not start with postgres:// or postgresql://"
    UnsupportedScheme(scheme:) ->
      "the scheme " <> scheme <> " is not postgres or postgresql"
    MultipleHosts ->
      "it names more than one host, and dream_postgres connects to one host"
    MalformedBracketedHost ->
      "the host in square brackets has no closing bracket, or text after it that is not a port"
    UnixSocketNotSupported ->
      "it has no host, which libpq takes as the default Unix socket, and dream_postgres connects only over TCP"
    UnixSocketHost(path:) ->
      "the host "
      <> path
      <> " is a Unix socket directory, and dream_postgres connects only over TCP"
    InvalidUrlPort(port:) ->
      "the port \"" <> port <> "\" is not a number in 1 to 65535"
    InvalidPercentEncoding(part:) ->
      "the "
      <> url_part_name(part)
      <> " has a % that is not followed by two hex digits, or is not UTF-8"
    ParameterWithoutValue(name:) ->
      "the parameter \"" <> name <> "\" has no value"
    UnsupportedParameter(name:) ->
      "the parameter " <> name <> " is not supported by dream_postgres"
    ParameterGivenTwice(name:) ->
      "the parameter " <> name <> " is given more than one time"
    UnknownSslMode(mode:) ->
      "the sslmode "
      <> mode
      <> " is not disable, prefer, require, verify-ca or verify-full"
    UnsupportedSslMode(mode:) ->
      "the sslmode " <> mode <> " is not supported: use prefer or require"
    UnknownSslNegotiation(negotiation:) ->
      "the sslnegotiation " <> negotiation <> " is not postgres or direct"
    DirectNegotiationNeedsRequiredTls(mode:) ->
      "sslnegotiation=direct needs the sslmode require, verify-ca or verify-full, not "
      <> mode
    RootCertificateNeedsCertificateCheck(mode:) ->
      "an sslrootcert file needs the sslmode require, verify-ca or verify-full, not "
      <> mode
    SystemRootCertificateNeedsVerifyFull(mode:) ->
      "sslrootcert=system needs the sslmode verify-full, not " <> mode
  }
}

fn url_part_name(part: UrlPart) -> String {
  case part {
    UrlUser -> "user"
    UrlPassword -> "password"
    UrlHost -> "host"
    UrlDatabase -> "database"
    UrlParameters -> "query"
  }
}

fn pool_start_message(failure: PoolStartFailure) -> String {
  case failure {
    PoolStartTimedOut -> "the pool process did not start in time"
    PoolInitFailed(message:) -> "the pool process refused to start: " <> message
    PoolProcessExited(reason:) ->
      "the pool process exited during its start: " <> reason
  }
}

fn certificate_fault_message(fault: CertificateFault) -> String {
  case fault {
    InvalidCertificate -> "the certificate is not a DER X.509 certificate"
    UnsupportedSignatureAlgorithm(object_identifier:) ->
      "the signature algorithm "
      <> string.join(list.map(object_identifier, int.to_string), ".")
      <> " names no hash that channel binding can use"
  }
}

fn scram_fault_message(fault: ScramFault) -> String {
  case fault {
    InvalidServerFirstMessage(message: _) ->
      "the server-first-message does not have the form of RFC 5802"
    MandatoryExtension(attribute:) ->
      "the server-first-message has the mandatory extension " <> attribute
    ServerNonceMismatch(server_nonce: _) ->
      "the nonce of the server does not extend the nonce of the client"
    ServerNonceTooLong(length:) ->
      "the nonce of the server has "
      <> int.to_string(length)
      <> " bytes, which is too long for the SCRAM exchange"
    InvalidSalt(salt: _) -> "the salt is not base64"
    InvalidIterationCount(iteration_count:) ->
      "the iteration count " <> iteration_count <> " is not 1 or more"
    InvalidServerFinalMessage(message: _) ->
      "the server-final-message does not have the form of RFC 5802"
    ServerReportedError(error: scram_error) ->
      "the server ended the exchange with the error " <> scram_error
    ServerSignatureMismatch ->
      "the signature of the server is wrong, so the server does not know the password"
  }
}

fn request_fault_message(fault: RequestFault) -> String {
  case fault {
    ZeroByteInString(field:) -> "the " <> field <> " holds a zero byte"
    TooManyItems(field:, count:) ->
      "the "
      <> field
      <> " has "
      <> int.to_string(count)
      <> " items, and at most 65535 can be sent"
    NumberOutOfRange(field:, value:) ->
      "the value "
      <> int.to_string(value)
      <> " of the "
      <> field
      <> " is out of range"
    SecretKeyLengthOutOfRange(length:) ->
      "the cancel key has "
      <> int.to_string(length)
      <> " bytes, and it must have 4 to 256"
    MessageTooLong(length:) ->
      "a message of "
      <> int.to_string(length)
      <> " bytes is too long for its length field"
  }
}

fn catalog_fault_message(fault: CatalogFault) -> String {
  case fault {
    UnreadableRow(row:) ->
      "a row of "
      <> int.to_string(list.length(row))
      <> " values does not have the shape of a catalog row"
    UnknownTypeKind(type_id:, kind:) ->
      "type " <> int.to_string(type_id) <> " has the unknown kind " <> kind
    MissingPart(type_id:, part_type_id:) ->
      "type "
      <> int.to_string(type_id)
      <> " has the part "
      <> int.to_string(part_type_id)
      <> ", which the catalog does not have"
    CircularDomain(type_id:) ->
      "the base types of domain "
      <> int.to_string(type_id)
      <> " come back to a domain of the chain"
    UnexpectedCatalogAnswer ->
      "the server answered the catalog query with a COPY or with an error after a result"
  }
}

fn message_fault_message(fault: MessageFault) -> String {
  case fault {
    UnknownMessageType(type_byte:) ->
      "unknown message type " <> int.to_string(type_byte)
    InvalidMessageLength(type_byte:, length:) ->
      "message type "
      <> int.to_string(type_byte)
      <> " has the length "
      <> int.to_string(length)
      <> ", which is below 4"
    InvalidMessageBody(type_byte:) ->
      "the body of message type "
      <> int.to_string(type_byte)
      <> " does not have its layout"
    InvalidUtf8(type_byte:) ->
      "message type "
      <> int.to_string(type_byte)
      <> " holds text that is not UTF-8"
    UnknownAuthenticationRequest(code:) ->
      "unknown authentication request " <> int.to_string(code)
    UnknownTransactionStatus(status_byte:) ->
      "unknown transaction status " <> int.to_string(status_byte)
    UnknownFormatCode(type_byte:, code:) ->
      "message type "
      <> int.to_string(type_byte)
      <> " has the unknown format code "
      <> int.to_string(code)
    InvalidSecretKeyLength(length:) ->
      "the secret key has "
      <> int.to_string(length)
      <> " bytes, and it must have 4 to 256"
    MissingReportField(type_byte:, field_code:) ->
      "message type "
      <> int.to_string(type_byte)
      <> " has no field "
      <> int.to_string(field_code)
    InvalidReportNumber(type_byte:, field_code:, value:) ->
      "field "
      <> int.to_string(field_code)
      <> " of message type "
      <> int.to_string(type_byte)
      <> " is not a number: "
      <> value
  }
}

fn server_message_name(message: ServerMessageKind) -> String {
  case message {
    AuthenticationOk -> "AuthenticationOk"
    AuthenticationKerberosV5 -> "AuthenticationKerberosV5"
    AuthenticationCleartextPassword -> "AuthenticationCleartextPassword"
    AuthenticationMd5Password -> "AuthenticationMD5Password"
    AuthenticationGss -> "AuthenticationGSS"
    AuthenticationGssContinue -> "AuthenticationGSSContinue"
    AuthenticationSspi -> "AuthenticationSSPI"
    AuthenticationSasl -> "AuthenticationSASL"
    AuthenticationSaslContinue -> "AuthenticationSASLContinue"
    AuthenticationSaslFinal -> "AuthenticationSASLFinal"
    BackendKeyData -> "BackendKeyData"
    BindComplete -> "BindComplete"
    CloseComplete -> "CloseComplete"
    CommandComplete -> "CommandComplete"
    CopyData -> "CopyData"
    CopyDone -> "CopyDone"
    CopyInResponse -> "CopyInResponse"
    CopyOutResponse -> "CopyOutResponse"
    CopyBothResponse -> "CopyBothResponse"
    DataRow -> "DataRow"
    EmptyQueryResponse -> "EmptyQueryResponse"
    ErrorResponse -> "ErrorResponse"
    FunctionCallResponse -> "FunctionCallResponse"
    NegotiateProtocolVersion -> "NegotiateProtocolVersion"
    NoData -> "NoData"
    NoticeResponse -> "NoticeResponse"
    NotificationResponse -> "NotificationResponse"
    ParameterDescription -> "ParameterDescription"
    ParameterStatus -> "ParameterStatus"
    ParseComplete -> "ParseComplete"
    PortalSuspended -> "PortalSuspended"
    ReadyForQuery -> "ReadyForQuery"
    RowDescription -> "RowDescription"
  }
}

fn protocol_step_text(step: ProtocolStep) -> String {
  case step {
    AwaitingParseComplete -> "ParseComplete"
    AwaitingParameterDescription -> "ParameterDescription"
    AwaitingStatementColumns -> "the columns of the statement"
    AwaitingBindComplete -> "BindComplete"
    AwaitingPortalColumns -> "the columns of the portal"
    ReadingExecuteRows -> "the rows of the run"
    AwaitingStatementResult -> "the next result of the SQL"
    ReadingSqlRows -> "the rows of a statement of the SQL"
    ReadingCopyOut -> "the data of a refused COPY"
    AwaitingCopyComplete -> "the end of a refused COPY"
    AwaitingReadyForQuery -> "ReadyForQuery"
    AwaitingReadyForQueryAfterError -> "ReadyForQuery after an error"
    AwaitingCloseComplete -> "CloseComplete"
    CopyingIn -> "the end of a COPY FROM STDIN"
  }
}

/// The message of a reason, with no query name: for a codec that reads or
/// writes the parts of a value with the row readers.
@internal
pub fn reason_message(reason: Reason) -> String {
  PostgresError(query_name: None, sql: None, reason:)
  |> to_dream_error
  |> dream_errors.message
}

/// The dream_errors value for a query that `one` expected one row from,
/// and that returned none.
pub fn no_rows(query_name: Option(String)) -> Error(PostgresError) {
  case query_name {
    Some(name) -> NotFound(name <> ": the query returned no row")
    None -> NotFound("the query returned no row")
  }
}

fn server_to_dream_error(
  prefix: String,
  server_error: ServerError,
  error: PostgresError,
) -> Error(PostgresError) {
  let message = prefix <> server_message(server_error)
  case sql_state.class(server_error.sql_state) {
    IntegrityConstraintViolationClass ->
      integrity_error(message, server_error.sql_state, error)
    TransactionRollbackClass ->
      rollback_error(message, server_error.sql_state, error)
    OperatorInterventionClass ->
      intervention_error(message, server_error.sql_state, error)
    ObjectNotInPrerequisiteStateClass ->
      prerequisite_error(message, server_error.sql_state, error)
    DataExceptionClass -> Invalid(message, error)
    ConnectionExceptionClass
    | InvalidAuthorizationSpecificationClass
    | InsufficientResourcesClass
    | SystemErrorClass
    | ConfigurationFileErrorClass -> Unavailable(message, error)
    SuccessfulCompletionClass
    | WarningClass
    | NoDataClass
    | SqlStatementNotYetCompleteClass
    | TriggeredActionExceptionClass
    | FeatureNotSupportedClass
    | InvalidTransactionInitiationClass
    | LocatorExceptionClass
    | InvalidGrantorClass
    | InvalidRoleSpecificationClass
    | DiagnosticsExceptionClass
    | XqueryErrorClass
    | CaseNotFoundClass
    | CardinalityViolationClass
    | InvalidCursorStateClass
    | InvalidTransactionStateClass
    | InvalidSqlStatementNameClass
    | TriggeredDataChangeViolationClass
    | DependentPrivilegeDescriptorsStillExistClass
    | InvalidTransactionTerminationClass
    | SqlRoutineExceptionClass
    | InvalidCursorNameClass
    | ExternalRoutineExceptionClass
    | ExternalRoutineInvocationExceptionClass
    | SavepointExceptionClass
    | InvalidCatalogNameClass
    | InvalidSchemaNameClass
    | SyntaxErrorOrAccessRuleViolationClass
    | WithCheckOptionViolationClass
    | ProgramLimitExceededClass
    | SnapshotFailureClass
    | ForeignDataWrapperErrorClass
    | PlPgsqlErrorClass
    | InternalErrorClass
    | UnlistedClass(..) -> Failed(message, error)
  }
}

// Class 23. A unique violation clashes with existing state. Every other
// integrity violation (not NULL, foreign key, check, exclusion, restrict)
// is input that broke a rule of the schema.
fn integrity_error(
  message: String,
  code: SqlState,
  error: PostgresError,
) -> Error(PostgresError) {
  case code == UniqueViolation {
    True -> Conflict(message, error)
    False -> Invalid(message, error)
  }
}

// Class 40. A serialization failure or a deadlock rolled the transaction
// back, and nothing happened: running it again can succeed.
fn rollback_error(
  message: String,
  code: SqlState,
  error: PostgresError,
) -> Error(PostgresError) {
  case code == SerializationFailure || code == DeadlockDetected {
    True -> Retry(message, error, None)
    False -> Failed(message, error)
  }
}

// Class 57. A cancelled query passed its deadline. Every other code of the
// class is a server that is shutting down or not accepting connections.
fn intervention_error(
  message: String,
  code: SqlState,
  error: PostgresError,
) -> Error(PostgresError) {
  case code == QueryCanceled {
    True -> Timeout(message, error)
    False -> Unavailable(message, error)
  }
}

// Class 55. A lock that was not free before `lock_timeout` is a deadline.
fn prerequisite_error(
  message: String,
  code: SqlState,
  error: PostgresError,
) -> Error(PostgresError) {
  case code == LockNotAvailable {
    True -> Timeout(message, error)
    False -> Failed(message, error)
  }
}

fn server_message(server_error: ServerError) -> String {
  let code = sql_state.to_string(server_error.sql_state)
  case server_error.constraint {
    Some(constraint) ->
      server_error.message
      <> " ("
      <> code
      <> ", constraint "
      <> constraint
      <> ")"
    None -> server_error.message <> " (" <> code <> ")"
  }
}

fn connect_failure_message(failure: ConnectFailure) -> String {
  case failure {
    HostNotFound(host:) -> "the host " <> host <> " was not found"
    ConnectionRefused(host:, port:) ->
      host <> ":" <> int.to_string(port) <> " refused the connection"
    ConnectTimedOut(host:, port:) ->
      host <> ":" <> int.to_string(port) <> " did not answer in time"
    TlsFailed(reason:) -> "the TLS handshake failed: " <> tls_text(reason)
    LoginRefused(server_error) ->
      "the database refused the login: " <> server_message(server_error)
    UnsupportedLoginMethod(name:) ->
      "the server asks for the login method "
      <> name
      <> ", which is not supported"
    OsRefused(error: posix_error) ->
      "the operating system refused the connection ("
      <> posix.name(posix_error)
      <> ")"
    ConnectionBroke(reason:) ->
      "the connection broke during the login: " <> lost_reason_message(reason)
    ConnectClosed(host:, port:) ->
      host
      <> ":"
      <> int.to_string(port)
      <> " closed the connection during the connect"
    ConnectReset(host:, port:) ->
      "the connection to "
      <> host
      <> ":"
      <> int.to_string(port)
      <> " was reset during the connect"
    LoginSendFailed(reason:) ->
      "a login message could not be sent: " <> lost_reason_message(reason)
    PasswordRequired(method:) ->
      "the server asks for a password with the login method "
      <> method
      <> ", and the config has none"
    UnexpectedLoginMessage(message:) ->
      "the server sent "
      <> server_message_name(message)
      <> " at a step of the login that does not allow it"
    UndecodableLoginMessage(fault:) ->
      "the server broke the protocol during the login: "
      <> message_fault_message(fault)
    PasswordTooLong(length:) ->
      "the password has "
      <> int.to_string(length)
      <> " bytes, which is too long to send as a cleartext password"
    SetupTimedOut -> "the connect and the login did not finish in time"
    SetupProcessExited -> "the connection process exited while it connected"
    PasswordHasZeroByte ->
      "the login settings are not valid: the password holds a zero byte"
    ChannelBindingRequiresTls ->
      "the login requires channel binding, and the connection has no TLS"
    ChannelBindingNotOffered(method:) ->
      "the login requires channel binding, and the server asks for " <> method
    ChannelBindingOfferedWithoutTls ->
      "the server offers channel binding on a connection with no TLS"
    CertificateHashFailed(fault:) ->
      "the certificate of the server gives no channel binding data: "
      <> certificate_fault_message(fault)
    ScramFailed(fault:) ->
      "the SCRAM login failed: " <> scram_fault_message(fault)
    UnsupportedProtocolVersion(major_version:, minor_version:) ->
      "the server answers with the protocol version "
      <> int.to_string(major_version)
      <> "."
      <> int.to_string(minor_version)
      <> ", which the client does not speak"
  }
}

fn tls_text(failure: TlsFailure) -> String {
  case failure {
    ServerHasNoTls -> "the server does not offer TLS"
    UnknownAuthority -> "no trusted authority signed the certificate"
    CertificateExpired -> "the certificate expired"
    TlsAlert(name:) -> name
    CertificateHostMismatch -> "the certificate does not name the host"
    AuthorityFileUnreadable(path:, reason:) ->
      "the authority file " <> path <> " could not be read (" <> reason <> ")"
    AuthorityFileEmpty(path:) ->
      "the authority file " <> path <> " holds no certificate"
    TlsRequestAnsweredWithError ->
      "the server answered the TLS request with an error"
    UnexpectedTlsAnswer(answer_byte:) ->
      "the server answered the TLS request with the byte "
      <> int.to_string(answer_byte)
    BytesBeforeTlsHandshake -> "the server sent bytes before the TLS handshake"
  }
}

fn lost_reason_message(lost: LostReason) -> String {
  case lost {
    ClosedByServer -> "the database closed the connection"
    ClosedAfterDeadline ->
      "the connection was closed after a deadline passed, because the cancel of that query was not confirmed"
    Reset -> "the connection was reset"
    TlsAlertRaised(alert:) -> "the TLS layer raised the alert " <> alert
    OsError(error: posix_error) ->
      "the connection failed (" <> posix.name(posix_error) <> ")"
    SendTimedOut ->
      "the database read nothing within the send timeout, so the connection was closed"
  }
}

/// The server error of a server report.
pub fn server_error_from_report(report: ServerReport) -> ServerError {
  let ServerReport(
    severity:,
    localized_severity:,
    code:,
    message:,
    detail:,
    hint:,
    position:,
    internal_position:,
    internal_query:,
    context:,
    schema:,
    table:,
    column:,
    data_type:,
    constraint:,
    file:,
    line:,
    routine:,
    other_fields:,
  ) = report
  ServerError(
    severity: severity_from_string(severity),
    sql_state: sql_state.from_string(code),
    message:,
    detail:,
    hint:,
    position:,
    internal_position:,
    internal_query:,
    context:,
    schema:,
    table:,
    column:,
    data_type:,
    constraint:,
    file:,
    line:,
    routine:,
    localized_severity:,
    other_fields:,
  )
}

fn severity_from_string(name: String) -> Severity {
  case name {
    "ERROR" -> ErrorSeverity
    "FATAL" -> FatalSeverity
    "PANIC" -> PanicSeverity
    "WARNING" -> WarningSeverity
    "NOTICE" -> NoticeSeverity
    "DEBUG" -> DebugSeverity
    "INFO" -> InfoSeverity
    "LOG" -> LogSeverity
    other -> UnlistedSeverity(other)
  }
}

/// The server error of a failure, if PostgreSQL sent one.
pub fn server_error(error: Error(PostgresError)) -> Option(ServerError) {
  case dream_errors.cause(error) {
    Some(PostgresError(reason: Server(server_error), ..)) -> Some(server_error)
    Some(PostgresError(reason: SqlStatementFailed(server_error:, ..), ..)) ->
      Some(server_error)
    Some(PostgresError(reason: ConnectFailed(LoginRefused(server_error)), ..)) ->
      Some(server_error)
    Some(PostgresError(reason: CommitRolledBack(Some(server_error)), ..)) ->
      Some(server_error)
    Some(PostgresError(reason: RollbackAlsoFailed(step_error:, ..), ..)) ->
      server_error(step_error)
    Some(PostgresError(..)) | None -> None
  }
}

/// The SQLSTATE of a failure, if PostgreSQL sent one.
pub fn sql_state(error: Error(PostgresError)) -> Option(SqlState) {
  option.map(server_error(error), fn(found) { found.sql_state })
}

/// The constraint that a failure names, if PostgreSQL named one.
pub fn constraint_name(error: Error(PostgresError)) -> Option(String) {
  option.then(server_error(error), fn(found) { found.constraint })
}

/// The table that a failure names, if PostgreSQL named one.
pub fn table_name(error: Error(PostgresError)) -> Option(String) {
  option.then(server_error(error), fn(found) { found.table })
}

/// The column that a failure names, if PostgreSQL named one.
pub fn column_name(error: Error(PostgresError)) -> Option(String) {
  option.then(server_error(error), fn(found) { found.column })
}

/// The text of a failure for a log line: the dream_errors kind, then the
/// message. It never holds a parameter value.
pub fn describe(error: Error(PostgresError)) -> String {
  dream_errors.kind_name(error)
  <> ": "
  <> string.trim(dream_errors.message(error))
}
