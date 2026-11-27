//// The executor of a driver connection: the three calls of a runner,
//// made with a connection process and the type catalog, with the error of
//// each driver call mapped to the client reason that says the same thing.

import dream_postgres/driver/catalog.{type Catalog, type CatalogError}
import dream_postgres/driver/catalog_table.{type RowError}
import dream_postgres/driver/channel_binding.{type CertificateError}
import dream_postgres/driver/connection.{
  type ChunkError, type ConnectError, type Connection, type ConnectionEnd,
  type ConnectionStateError, type CopyError, type HousekeepingError,
  type LossReason, type PrepareError, type RequestFailure, type RunError,
  type ScriptError, type Statement, type Violation,
}
import dream_postgres/driver/listener.{
  type ListenFailure, type ListenerError, type UnsubscribeError,
}
import dream_postgres/driver/login.{
  type ConfigError, type LoginError, type LoginMethod,
}
import dream_postgres/driver/message.{
  type BackendMessage, type EncodeError, type ProtocolError,
}
import dream_postgres/driver/pool.{type HoldError, type StartError}
import dream_postgres/driver/query.{type Phase}
import dream_postgres/driver/scram.{type ServerFinalError, type ServerFirstError}
import dream_postgres/driver/transport.{
  type AddressError, type SendError, type SocketError, type TlsFailure,
  type TransportError,
}
import dream_postgres/error.{type Reason}
import dream_postgres/internal/runner.{
  type Executor, type RunFailure, Executor, RunFailed, StatementChanged,
}
import dream_postgres/posix
import dream_postgres/secrets.{type Secrets}
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string

/// The executor that runs each call on the connection, and describes each
/// type with the catalog. Each call waits at most `deadline_milliseconds`.
/// The name of a query goes to the driver with its SQL, so the span of
/// the statement carries it.
pub fn executor(
  connection: Connection,
  catalog: Catalog,
  endpoint: Endpoint,
  secrets: Secrets,
  deadline_milliseconds: Int,
) -> Executor {
  // One deadline for the whole query: each call gets the time that is
  // left, and no call starts after the deadline.
  let deadline_at = monotonic_milliseconds() + deadline_milliseconds
  Executor(
    prepare: fn(sql, name) {
      use remaining <- result.try(remaining_milliseconds(deadline_at))
      connection.prepare(connection, statement(sql, name, secrets), remaining)
      |> result.map_error(prepare_error_reason(_, endpoint))
    },
    describe_current: fn(sql, name) {
      use remaining <- result.try(remaining_milliseconds(deadline_at))
      connection.describe_current(
        connection,
        statement(sql, name, secrets),
        remaining,
      )
      |> result.map_error(prepare_error_reason(_, endpoint))
    },
    describe_type: fn(type_id) {
      use remaining <- result.try(remaining_milliseconds(deadline_at))
      catalog.describe(catalog, connection, type_id, remaining)
      |> result.map_error(catalog_error_reason(_, endpoint))
    },
    run: fn(sql, name, parameters, result_formats) {
      use remaining <- result.try(
        remaining_milliseconds(deadline_at) |> result.map_error(RunFailed),
      )
      connection.run(
        connection,
        statement(sql, name, secrets),
        parameters,
        result_formats,
        remaining,
      )
      |> result.map(fn(outcome) { outcome.result })
      |> result.map_error(run_failure(_, endpoint))
    },
  )
}

/// The driver statement of SQL, with the name of its query when it has
/// one. Each statement that goes to the driver is made here, so this is
/// the one place where the text of its trace span is set: the SQL with
/// the text secrets of the config replaced.
@internal
pub fn statement(
  sql: String,
  name: Option(String),
  secrets: Secrets,
) -> Statement {
  let spanned =
    connection.statement(sql)
    |> connection.span_text(text: secrets.replace_text(secrets, sql))
  case name {
    Some(name) -> connection.named(spanned, name)
    None -> spanned
  }
}

// A changed statement goes back to the runner, which checks it again.
@internal
pub fn run_failure(run_error: RunError, endpoint: Endpoint) -> RunFailure {
  case run_error {
    connection.RunStatementChanged(description:) ->
      StatementChanged(description:)
    connection.RunFailed(..)
    | connection.RunNotConnected(..)
    | connection.RunUnencodable(..)
    | connection.RunRefused(..)
    | connection.RunCopyRefused ->
      RunFailed(run_error_reason(run_error, endpoint))
  }
}

@internal
pub fn remaining_milliseconds(deadline_at: Int) -> Result(Int, Reason) {
  let remaining = deadline_at - monotonic_milliseconds()
  case remaining > 0 {
    True -> Ok(remaining)
    False -> Error(error.QueryTimeout(stopped_on_server: True))
  }
}

@external(erlang, "dream_postgres_driver_executor_ffi", "monotonic_milliseconds")
@internal
pub fn monotonic_milliseconds() -> Int

/// The server a connection talks to, for the connect failures of a
/// connection that has not logged in yet.
pub type Endpoint {
  Endpoint(host: String, port: Int)
}

/// The client reason of a request that failed on its connection.
@internal
pub fn request_failure_reason(failure: RequestFailure) -> Reason {
  case failure {
    connection.ConnectionProcessDown -> error.ConnectionProcessDown
    connection.DeadlinePassed(cancelled:) ->
      error.QueryTimeout(stopped_on_server: cancelled)
    connection.ConnectionEnded(end:) -> connection_end_reason(end)
  }
}

/// The client reason of a connection that ended.
@internal
pub fn connection_end_reason(end: ConnectionEnd) -> Reason {
  case end {
    connection.ConnectionLost(reason:) ->
      error.ConnectionLost(loss_reason(reason))
    connection.ServerEndedConnection(report:) ->
      error.Server(error.server_error_from_report(report))
    connection.ProtocolViolation(violation:) -> violation_reason(violation)
  }
}

/// The client reason of a failed `prepare`.
@internal
pub fn prepare_error_reason(
  prepare_error: PrepareError,
  endpoint: Endpoint,
) -> Reason {
  case prepare_error {
    connection.PrepareFailed(failure:) -> request_failure_reason(failure)
    connection.PrepareNotConnected(error: connect_error) ->
      not_connected_reason(connect_error, endpoint)
    connection.PrepareUnencodable(error: encode_error) ->
      error.RequestNotWritable(request_fault(encode_error))
    connection.PrepareRefused(report:, transaction_status: _) ->
      error.Server(error.server_error_from_report(report))
  }
}

/// The client reason of a failed `run`.
@internal
pub fn run_error_reason(run_error: RunError, endpoint: Endpoint) -> Reason {
  case run_error {
    connection.RunFailed(failure:) -> request_failure_reason(failure)
    connection.RunNotConnected(error: connect_error) ->
      not_connected_reason(connect_error, endpoint)
    connection.RunUnencodable(error: encode_error) ->
      error.RequestNotWritable(request_fault(encode_error))
    connection.RunRefused(report:, transaction_status: _) ->
      error.Server(error.server_error_from_report(report))
    connection.RunCopyRefused -> error.CopyStatementRefused(statements_run: 0)
    connection.RunStatementChanged(description: _) ->
      error.StatementChangedDuringRun
  }
}

/// The client reason of a failed `run_script`.
@internal
pub fn script_error_reason(
  script_error: ScriptError,
  endpoint: Endpoint,
) -> Reason {
  case script_error {
    connection.ScriptRequestFailed(failure:) -> request_failure_reason(failure)
    connection.ScriptNotConnected(error: connect_error) ->
      not_connected_reason(connect_error, endpoint)
    connection.ScriptUnencodable(error: encode_error) ->
      error.RequestNotWritable(request_fault(encode_error))
    connection.ScriptRefused(report:, transaction_status: _) ->
      error.Server(error.server_error_from_report(report))
    connection.ScriptFailed(completed:, report:, transaction_status: _) ->
      error.ScriptStatementFailed(
        statements_run: list.length(completed),
        server_error: error.server_error_from_report(report),
      )
    connection.ScriptCopyRefused(completed:) ->
      error.CopyStatementRefused(statements_run: list.length(completed))
  }
}

/// The client reason of a failed COPY. The function of the COPY fails
/// with a client reason already, and a driver error gives the reason that
/// says the same thing.
@internal
pub fn copy_error_reason(
  copy_error: CopyError(Reason),
  endpoint: Endpoint,
) -> Reason {
  case copy_error {
    connection.AppFailed(reason:) -> reason
    connection.CopyFailed(failure:) -> request_failure_reason(failure)
    connection.CopyNotConnected(error: connect_error) ->
      not_connected_reason(connect_error, endpoint)
    connection.CopyUnencodable(error: encode_error) ->
      error.RequestNotWritable(request_fault(encode_error))
    connection.CopyRefused(report:, transaction_status: _) ->
      error.Server(error.server_error_from_report(report))
    connection.CopyNotStarted(completed:) ->
      error.CopyNotStarted(statement_ran: option.is_some(completed))
  }
}

/// The client reason of a chunk that the COPY did not take.
@internal
pub fn chunk_error_reason(chunk_error: ChunkError) -> Reason {
  case chunk_error {
    connection.ChunkFailed(failure:) -> request_failure_reason(failure)
    connection.ChunkCopyNotRunning -> error.CopyNotRunning
    connection.ChunkRefused(report:, transaction_status: _) ->
      error.Server(error.server_error_from_report(report))
  }
}

/// The client reason of a state question that the connection process did
/// not answer.
@internal
pub fn connection_state_error_reason(
  state_error: ConnectionStateError,
) -> Reason {
  case state_error {
    connection.ProcessGone -> error.ConnectionProcessDown
    connection.NoAnswerInTime -> error.QueryTimeout(stopped_on_server: False)
  }
}

fn not_connected_reason(
  connect_error: ConnectError,
  endpoint: Endpoint,
) -> Reason {
  error.ConnectFailed(connect_failure(
    connect_error,
    endpoint.host,
    endpoint.port,
  ))
}

/// The client reason of a failed catalog query.
@internal
pub fn housekeeping_error_reason(
  housekeeping_error: HousekeepingError,
  endpoint: Endpoint,
) -> Reason {
  case housekeeping_error {
    connection.HousekeepingFailed(failure:) -> request_failure_reason(failure)
    connection.HousekeepingNotConnected(error: connect_error) ->
      not_connected_reason(connect_error, endpoint)
    connection.HousekeepingRefused(report:, transaction_status: _) ->
      error.Server(error.server_error_from_report(report))
    connection.HousekeepingAnswerUnexpected ->
      error.UnreadableCatalog(error.UnexpectedCatalogAnswer)
  }
}

/// The client reason of a catalog error. A catalog query that failed on
/// the connection gives the reason of its run error.
@internal
pub fn catalog_error_reason(
  catalog_error: CatalogError,
  endpoint: Endpoint,
) -> Reason {
  case catalog_error {
    catalog.UnknownType(type_id:) -> error.UnknownType(type_id:)
    catalog.LoadFailed(error: housekeeping_error) ->
      housekeeping_error_reason(housekeeping_error, endpoint)
    catalog.UnreadableCatalog(error: row_error) ->
      error.UnreadableCatalog(catalog_fault(row_error))
    catalog.CatalogProcessDown -> error.CatalogProcessDown
  }
}

fn loss_reason(loss: LossReason) -> error.LostReason {
  case loss {
    connection.SocketFailed(error: socket_error) ->
      socket_lost_reason(socket_error)
    connection.ServerStoppedReading -> error.SendTimedOut
    connection.ClosedAfterDeadline -> error.ClosedAfterDeadline
  }
}

fn socket_lost_reason(socket_error: SocketError) -> error.LostReason {
  case socket_error {
    transport.SocketClosed -> error.ClosedByServer
    transport.ConnectionReset -> error.Reset
    transport.TlsAlertRaised(alert:) -> error.TlsAlertRaised(alert:)
    transport.Unlisted(reason:) -> error.OsError(posix_error(reason))
  }
}

fn send_lost_reason(send_error: SendError) -> error.LostReason {
  case send_error {
    transport.SendTimedOut -> error.SendTimedOut
    transport.SendFailed(error: socket_error) ->
      socket_lost_reason(socket_error)
  }
}

// The posix error of an error name, for example `ehostunreach`. A name
// that the type does not list is `Unlisted(name)`.
fn posix_error(name: String) -> posix.Posix {
  posix.posix_codes()
  |> list.find(fn(code) { posix.name(code) == name })
  |> result.unwrap(posix.Unlisted(name:))
}

fn tls_failure(failure: TlsFailure) -> error.TlsFailure {
  case failure {
    transport.HostNameMismatch -> error.CertificateHostMismatch
    transport.UnknownAuthority -> error.UnknownAuthority
    transport.CertificateExpired -> error.CertificateExpired
    transport.AuthorityFileUnreadable(path:, reason:) ->
      error.AuthorityFileUnreadable(path:, reason:)
    transport.AuthorityFileEmpty(path:) -> error.AuthorityFileEmpty(path:)
    transport.OtherTlsFailure(reason:) -> error.TlsAlert(name: reason)
  }
}

fn violation_reason(violation: Violation) -> Reason {
  case violation {
    connection.UndecodableMessage(error: protocol_error) ->
      error.UndecodableServerMessage(message_fault(protocol_error))
    connection.UnexpectedServerMessage(error: unexpected) ->
      error.UnexpectedServerMessage(
        message: server_message_kind(unexpected.message),
        step: protocol_step(unexpected.phase),
      )
    connection.UnexpectedIdleMessage(message:) ->
      error.UnexpectedIdleMessage(server_message_kind(message))
  }
}

fn request_fault(encode_error: EncodeError) -> error.RequestFault {
  case encode_error {
    message.ZeroByteInString(field:) -> error.ZeroByteInString(field:)
    message.TooManyItems(field:, count:) -> error.TooManyItems(field:, count:)
    message.NumberOutOfRange(field:, value:) ->
      error.NumberOutOfRange(field:, value:)
    message.SecretKeyLengthOutOfRange(length:) ->
      error.SecretKeyLengthOutOfRange(length:)
    message.MessageTooLong(length:) -> error.MessageTooLong(length:)
  }
}

fn catalog_fault(row_error: RowError) -> error.CatalogFault {
  case row_error {
    catalog_table.UnreadableRow(row:) -> error.UnreadableRow(row:)
    catalog_table.UnknownTypeKind(type_id:, kind:) ->
      error.UnknownTypeKind(type_id:, kind:)
    catalog_table.MissingPart(type_id:, part_type_id:) ->
      error.MissingPart(type_id:, part_type_id:)
    catalog_table.CircularDomain(type_id:) -> error.CircularDomain(type_id:)
  }
}

fn message_fault(protocol_error: ProtocolError) -> error.MessageFault {
  case protocol_error {
    message.UnknownMessageType(type_byte:) ->
      error.UnknownMessageType(type_byte:)
    message.InvalidMessageLength(type_byte:, length:) ->
      error.InvalidMessageLength(type_byte:, length:)
    message.InvalidMessageBody(type_byte:) ->
      error.InvalidMessageBody(type_byte:)
    message.InvalidUtf8(type_byte:) -> error.InvalidUtf8(type_byte:)
    message.UnknownAuthenticationRequest(code:) ->
      error.UnknownAuthenticationRequest(code:)
    message.UnknownTransactionStatus(status_byte:) ->
      error.UnknownTransactionStatus(status_byte:)
    message.UnknownFormatCode(type_byte:, code:) ->
      error.UnknownFormatCode(type_byte:, code:)
    message.InvalidSecretKeyLength(length:) ->
      error.InvalidSecretKeyLength(length:)
    message.MissingReportField(type_byte:, field_code:) ->
      error.MissingReportField(type_byte:, field_code:)
    message.InvalidReportNumber(type_byte:, field_code:, value:) ->
      error.InvalidReportNumber(type_byte:, field_code:, value:)
  }
}

// The kind of a backend message. Its contents are not kept, because a
// DataRow or a CopyData holds the values of rows.
fn server_message_kind(
  backend_message: BackendMessage,
) -> error.ServerMessageKind {
  case backend_message {
    message.AuthenticationOk -> error.AuthenticationOk
    message.AuthenticationKerberosV5 -> error.AuthenticationKerberosV5
    message.AuthenticationCleartextPassword ->
      error.AuthenticationCleartextPassword
    message.AuthenticationMd5Password(..) -> error.AuthenticationMd5Password
    message.AuthenticationGss -> error.AuthenticationGss
    message.AuthenticationGssContinue(..) -> error.AuthenticationGssContinue
    message.AuthenticationSspi -> error.AuthenticationSspi
    message.AuthenticationSasl(..) -> error.AuthenticationSasl
    message.AuthenticationSaslContinue(..) -> error.AuthenticationSaslContinue
    message.AuthenticationSaslFinal(..) -> error.AuthenticationSaslFinal
    message.BackendKeyData(..) -> error.BackendKeyData
    message.BindComplete -> error.BindComplete
    message.CloseComplete -> error.CloseComplete
    message.CommandComplete(..) -> error.CommandComplete
    message.CopyDataFromServer(..) -> error.CopyData
    message.CopyDoneFromServer -> error.CopyDone
    message.CopyInResponse(..) -> error.CopyInResponse
    message.CopyOutResponse(..) -> error.CopyOutResponse
    message.CopyBothResponse(..) -> error.CopyBothResponse
    message.DataRow(..) -> error.DataRow
    message.EmptyQueryResponse -> error.EmptyQueryResponse
    message.ErrorResponse(..) -> error.ErrorResponse
    message.FunctionCallResponse(..) -> error.FunctionCallResponse
    message.NegotiateProtocolVersion(..) -> error.NegotiateProtocolVersion
    message.NoData -> error.NoData
    message.NoticeResponse(..) -> error.NoticeResponse
    message.NotificationResponse(..) -> error.NotificationResponse
    message.ParameterDescriptions(..) -> error.ParameterDescription
    message.ParameterStatus(..) -> error.ParameterStatus
    message.ParseComplete -> error.ParseComplete
    message.PortalSuspended -> error.PortalSuspended
    message.ReadyForQuery(..) -> error.ReadyForQuery
    message.RowDescription(..) -> error.RowDescription
  }
}

fn protocol_step(phase: Phase) -> error.ProtocolStep {
  case phase {
    query.AwaitingParseComplete -> error.AwaitingParseComplete
    query.AwaitingParameterDescription -> error.AwaitingParameterDescription
    query.AwaitingStatementColumns -> error.AwaitingStatementColumns
    query.AwaitingBindComplete -> error.AwaitingBindComplete
    query.AwaitingPortalColumns -> error.AwaitingPortalColumns
    query.ReadingExecuteRows -> error.ReadingExecuteRows
    query.AwaitingStatementResult -> error.AwaitingStatementResult
    query.ReadingScriptRows -> error.ReadingScriptRows
    query.ReadingCopyOut -> error.ReadingCopyOut
    query.AwaitingCopyComplete -> error.AwaitingCopyComplete
    query.AwaitingReadyForQuery -> error.AwaitingReadyForQuery
    query.AwaitingReadyForQueryAfterError ->
      error.AwaitingReadyForQueryAfterError
    query.AwaitingCloseComplete -> error.AwaitingCloseComplete
    query.CopyingIn -> error.CopyingIn
  }
}

// --- Pools and connects ----------------------------------------------------------

/// The client reason of a checkout that gave no connection. `host` and
/// `port` are the server of the pool, for a connect error.
@internal
pub fn checkout_error_reason(
  checkout_error: HoldError,
  host: String,
  port: Int,
) -> Reason {
  case checkout_error {
    pool.HoldDeadlinePassed -> error.NoConnection
    pool.ConnectFailed(error: connect_error) ->
      error.ConnectFailed(connect_failure(connect_error, host, port))
    pool.PoolStopped -> error.PoolStopped
    pool.NoDatabase -> error.PoolHasNoDatabase
  }
}

/// The client reason of a pool that did not start.
@internal
pub fn start_error_reason(start_error: StartError) -> Reason {
  case start_error {
    pool.InvalidSize(size:) -> error.InvalidConfig(error.InvalidPoolSize(size:))
    pool.InvalidHealthCheckInterval(milliseconds:) ->
      error.InvalidConfig(error.InvalidHealthCheckInterval(milliseconds:))
    pool.PoolProcessStartFailed(error: actor_error) ->
      error.PoolStartFailed(pool_start_failure(actor_error))
  }
}

fn pool_start_failure(start_error: actor.StartError) -> error.PoolStartFailure {
  case start_error {
    actor.InitTimeout -> error.PoolStartTimedOut
    actor.InitFailed(message) -> error.PoolInitFailed(message:)
    actor.InitExited(exit_reason) ->
      error.PoolProcessExited(reason: exit_reason_text(exit_reason))
  }
}

fn exit_reason_text(exit_reason: process.ExitReason) -> String {
  case exit_reason {
    process.Normal -> "normal"
    process.Killed -> "killed"
    process.Abnormal(reason:) -> string.inspect(reason)
  }
}

// --- Listeners --------------------------------------------------------------------

/// The client reason of a `LISTEN` that failed on a session that is up.
@internal
pub fn listen_failure_reason(failure: ListenFailure) -> Reason {
  case failure {
    listener.ListenRefused(report:, transaction_status: _) ->
      error.Server(error.server_error_from_report(report))
    listener.ListenAnswerUnexpected -> error.UnexpectedListenAnswer
    listener.ListenDeadlinePassed(cancelled:) ->
      error.QueryTimeout(stopped_on_server: cancelled)
    listener.ChannelHasZeroByte ->
      error.RequestNotWritable(error.ZeroByteInString(field: "channel name"))
    listener.ListenerConnectionDown -> error.ConnectionProcessDown
  }
}

/// The client reason of a subscribe that the listener refused.
@internal
pub fn listener_error_reason(listener_error: ListenerError) -> Reason {
  case listener_error {
    listener.ChannelTooLong(channel:) -> error.ChannelTooLong(channel:)
    listener.SubscriberHasNoProcess -> error.SubscriberHasNoProcess
    listener.SubscribeFailed(error: failure) -> listen_failure_reason(failure)
    listener.ListenerProcessDown -> error.ListenerStopped
  }
}

/// The client reason of an unsubscribe that failed.
@internal
pub fn unsubscribe_error_reason(unsubscribe_error: UnsubscribeError) -> Reason {
  case unsubscribe_error {
    listener.ListenerGone -> error.ListenerStopped
  }
}

/// The client reason of a listener that did not start. `host` and `port`
/// are the server of the listener, for a connect error.
@internal
pub fn listener_start_error_reason(
  start_error: listener.StartError,
  host: String,
  port: Int,
) -> Reason {
  case start_error {
    listener.ConnectFailed(error: connect_error) ->
      error.ConnectFailed(connect_failure(connect_error, host, port))
    listener.ListenerNotStarted(error: actor_error) ->
      error.ListenerStartFailed(listener_start_failure(actor_error))
  }
}

fn listener_start_failure(
  start_error: actor.StartError,
) -> error.ListenerStartFailure {
  case start_error {
    actor.InitTimeout -> error.ListenerStartTimedOut
    actor.InitFailed(message) -> error.ListenerInitFailed(message:)
    actor.InitExited(exit_reason) ->
      error.ListenerProcessExited(reason: exit_reason_text(exit_reason))
  }
}

/// The config fault of an address that the transport refused.
@internal
pub fn address_fault(address_error: AddressError) -> error.ConfigFault {
  case address_error {
    transport.InvalidHost(host:) -> error.InvalidHost(host:)
    transport.InvalidPort(port:) -> error.InvalidPort(port:)
  }
}

/// The config fault of login settings that the driver refused.
@internal
pub fn login_config_fault(config_error: ConfigError) -> error.ConfigFault {
  case config_error {
    login.EmptyUser -> error.EmptyUser
    login.ZeroByteInPassword -> error.ZeroByteInPassword
    login.ZeroByteInParameter(name:) -> error.ZeroByteInParameter(name:)
    login.EmptyParameterName -> error.EmptyParameterName
    login.DuplicateParameter(name:) -> error.DuplicateParameter(name:)
    login.UnsupportedClientEncoding(value:) ->
      error.UnsupportedClientEncoding(value:)
    login.StartupMessageTooLong(length:) -> error.StartupMessageTooLong(length:)
  }
}

/// The client connect failure of a connect error of the driver. `host`
/// and `port` are the server that the connection asked for.
@internal
pub fn connect_failure(
  connect_error: ConnectError,
  host: String,
  port: Int,
) -> error.ConnectFailure {
  case connect_error {
    connection.TransportRefused(error: transport_error) ->
      transport_connect_failure(transport_error, host, port)
    connection.LoginSocketFailed(error: socket_error) ->
      error.ConnectionBroke(socket_lost_reason(socket_error))
    connection.LoginSendFailed(error: send_error) ->
      error.LoginSendFailed(send_lost_reason(send_error))
    connection.LoginRequiresTls -> error.ChannelBindingRequiresTls
    connection.LoginRefused(error: login_error) -> login_failure(login_error)
    connection.LoginUndecodable(error: protocol_error) ->
      error.UndecodableLoginMessage(message_fault(protocol_error))
    connection.SetupTimedOut -> error.SetupTimedOut
    connection.SetupExited -> error.SetupProcessExited
  }
}

fn transport_connect_failure(
  transport_error: TransportError,
  host: String,
  port: Int,
) -> error.ConnectFailure {
  case transport_error {
    transport.ConnectRefused -> error.ConnectionRefused(host:, port:)
    transport.ConnectTimedOut -> error.ConnectTimedOut(host:, port:)
    transport.DnsLookupFailed(host: unresolved) ->
      error.HostNotFound(host: unresolved)
    transport.TlsFailed(reason:) -> error.TlsFailed(tls_failure(reason))
    transport.ServerRefusedTls -> error.TlsFailed(error.ServerHasNoTls)
    transport.TlsRequestAnsweredWithError ->
      error.TlsFailed(error.TlsRequestAnsweredWithError)
    transport.UnexpectedTlsAnswer(answer_byte:) ->
      error.TlsFailed(error.UnexpectedTlsAnswer(answer_byte:))
    transport.BytesBeforeTls -> error.TlsFailed(error.BytesBeforeTlsHandshake)
    transport.ConnectClosed -> error.ConnectClosed(host:, port:)
    transport.ConnectReset -> error.ConnectReset(host:, port:)
    transport.ConnectUnlisted(reason:) -> error.OsRefused(posix_error(reason))
  }
}

fn login_failure(login_error: LoginError) -> error.ConnectFailure {
  case login_error {
    login.ServerRejectedLogin(report:) ->
      error.LoginRefused(error.server_error_from_report(report))
    login.UnexpectedMessage(message:) ->
      error.UnexpectedLoginMessage(server_message_kind(message))
    login.UnsupportedLoginMethod(method:) ->
      error.UnsupportedLoginMethod(name: login_method_name(method))
    login.PasswordRequired(method:) ->
      error.PasswordRequired(method: login_method_name(method))
    login.PasswordHasZeroByte -> error.PasswordHasZeroByte
    login.PasswordTooLong(length:) -> error.PasswordTooLong(length:)
    login.ChannelBindingNotOffered(method:) ->
      error.ChannelBindingNotOffered(method: login_method_name(method))
    login.ChannelBindingOfferedWithoutTls ->
      error.ChannelBindingOfferedWithoutTls
    login.CertificateHashFailed(error: certificate_error) ->
      error.CertificateHashFailed(certificate_fault(certificate_error))
    login.ScramServerFirstFailed(error: server_first_error) ->
      error.ScramFailed(server_first_fault(server_first_error))
    login.ScramServerFinalFailed(error: server_final_error) ->
      error.ScramFailed(server_final_fault(server_final_error))
    login.UnsupportedProtocolVersion(major_version:, minor_version:) ->
      error.UnsupportedProtocolVersion(major_version:, minor_version:)
  }
}

fn login_method_name(method: LoginMethod) -> String {
  case method {
    login.TrustLogin -> "trust"
    login.CleartextLogin -> "cleartext password"
    login.Md5Login -> "MD5"
    login.ScramLogin(mechanism:) -> mechanism
    login.SaslLogin(mechanisms:) ->
      "SASL (" <> string.join(mechanisms, ", ") <> ")"
    login.KerberosV5Login -> "Kerberos V5"
    login.GssLogin -> "GSSAPI"
    login.SspiLogin -> "SSPI"
  }
}

fn certificate_fault(
  certificate_error: CertificateError,
) -> error.CertificateFault {
  case certificate_error {
    channel_binding.InvalidCertificate -> error.InvalidCertificate
    channel_binding.UnsupportedSignatureAlgorithm(object_identifier:) ->
      error.UnsupportedSignatureAlgorithm(object_identifier:)
  }
}

fn server_first_fault(
  server_first_error: ServerFirstError,
) -> error.ScramFault {
  case server_first_error {
    scram.InvalidServerFirstMessage(message:) ->
      error.InvalidServerFirstMessage(message:)
    scram.MandatoryExtension(attribute:) -> error.MandatoryExtension(attribute:)
    scram.ServerNonceMismatch(server_nonce:) ->
      error.ServerNonceMismatch(server_nonce:)
    scram.ServerNonceTooLong(length:) -> error.ServerNonceTooLong(length:)
    scram.InvalidSalt(salt:) -> error.InvalidSalt(salt:)
    scram.InvalidIterationCount(iteration_count:) ->
      error.InvalidIterationCount(iteration_count:)
  }
}

fn server_final_fault(
  server_final_error: ServerFinalError,
) -> error.ScramFault {
  case server_final_error {
    scram.InvalidServerFinalMessage(message:) ->
      error.InvalidServerFinalMessage(message:)
    scram.ServerReportedError(error: scram_error_text) ->
      error.ServerReportedError(error: scram_error_text)
    scram.ServerSignatureMismatch -> error.ServerSignatureMismatch
  }
}
