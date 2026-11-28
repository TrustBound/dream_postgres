//// The outcome of a request: its result, the notices and the notifications that
//// came with it.

import dream_postgres/driver/cell.{
  type ColumnDescription, type CommandResult, type ServerReport,
  type TransactionStatus,
}
import dream_postgres/driver/message.{type BackendMessage, type ProtocolError}
import dream_postgres/driver/query/step.{type UnexpectedMessage}

/// The result of one statement.
pub type Outcome {
  Outcome(
    /// The result columns, for the client's decoders.
    columns: List(ColumnDescription),
    result: CommandResult,
    /// Each notice that arrived during the request of this outcome, in
    /// order. The last outcome of a simple query holds the notices of the whole
    /// simple query.
    notices: List(ServerReport),
    /// Each notification since the last outcome, in order. An app that
    /// wants notifications uses the listener, which has its own connection.
    notifications: List(Notification),
    transaction_status: TransactionStatus,
  )
}

/// A notification of `NOTIFY`, from the backend with this process ID.
pub type Notification {
  Notification(process_id: Int, channel: String, payload: String)
}

/// A message of the server that the driver did not expect.
pub type Violation {
  /// Bytes that are not a valid message.
  UndecodableMessage(error: ProtocolError)
  /// A valid message that the protocol does not allow at this point of a
  /// request.
  UnexpectedServerMessage(error: UnexpectedMessage)
  /// A message between requests that is not a parameter change, a notice,
  /// a notification or an error.
  UnexpectedIdleMessage(message: BackendMessage)
}
