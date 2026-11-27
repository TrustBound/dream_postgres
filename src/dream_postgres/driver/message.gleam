//// The messages of the PostgreSQL wire protocol, versions 3.0 and 3.2, as
//// Gleam values.
////
//// `driver/encode` writes a `FrontendMessage` as bytes, and `driver/decode`
//// reads bytes as a `BackendMessage`. Neither touches a socket. The names
//// of the messages are the names of the PostgreSQL documentation, chapter
//// "Frontend/Backend Protocol", section "Message Formats", so each one can
//// be found there.
////
//// The driver never reads a value: a parameter and a result cell are bytes
//// or NULL, and the format of each is the one the caller gave.
////
//// This module is internal to dream_postgres.

import dream_postgres/internal/cell.{
  type Cell, type ColumnDescription, type Format, type ParameterDescription,
  type ServerReport, type TransactionStatus,
}
import gleam/option.{type Option}

/// The protocol version that a StartupMessage asks for.
pub type ProtocolVersion {
  /// Version 3.0, which every supported PostgreSQL speaks.
  Protocol30
  /// Version 3.2, from PostgreSQL 18: cancel keys of up to 256 bytes.
  Protocol32
}

/// A prepared statement or a portal, by name. The empty name is the unnamed
/// one.
pub type Target {
  /// A prepared statement.
  Statement(name: String)
  /// A portal: a prepared statement bound to its parameters.
  Portal(name: String)
}

/// A message that the client sends to the server.
pub type FrontendMessage {
  /// The first message of a connection: the protocol version, the user, and
  /// the other startup parameters (for example `database`, `options` or
  /// `client_encoding`) in the order to send them.
  StartupMessage(
    version: ProtocolVersion,
    user: String,
    parameters: List(#(String, String)),
  )
  /// Asks the server for TLS before the StartupMessage.
  SslRequest
  /// Asks the server for GSSAPI encryption before the StartupMessage.
  GssEncryptionRequest
  /// Asks the server, on a new connection, to cancel the query of another
  /// one. The secret key has 4 bytes in protocol 3.0, and 4 to 256 bytes
  /// in protocol 3.2.
  CancelRequest(process_id: Int, secret_key: BitArray)
  /// A password, in clear or as MD5, as the login request asked.
  PasswordMessage(password: String)
  /// The first SASL message: the chosen mechanism and its first data, if
  /// any.
  SaslInitialResponse(mechanism: String, data: Option(BitArray))
  /// A later SASL message.
  SaslResponse(data: BitArray)
  /// A GSSAPI or SSPI message.
  GssResponse(data: BitArray)
  /// Prepares a statement: its name, its SQL, and the type OIDs of the
  /// first parameters (0 leaves a type for the server to choose).
  Parse(statement: String, query: String, parameter_type_ids: List(Int))
  /// Binds the parameters of a prepared statement to a portal, and gives
  /// the format of each result column. A cell's own form gives the format
  /// of each parameter.
  Bind(
    portal: String,
    statement: String,
    parameters: List(Cell),
    result_formats: List(Format),
  )
  /// Asks for the description of a prepared statement or a portal.
  Describe(target: Target)
  /// Runs a portal. A row limit of 0 means no limit.
  Execute(portal: String, row_limit: Int)
  /// Ends an extended query: the server answers each message before it.
  Sync
  /// Asks the server to send what it has, without ending the query.
  Flush
  /// Closes a prepared statement or a portal.
  Close(target: Target)
  /// Runs SQL with the simple query protocol.
  Query(query: String)
  /// Calls a function by its OID, with the format of each argument from
  /// its cell and the format of the result.
  FunctionCall(function_id: Int, arguments: List(Cell), result_format: Format)
  /// Part of the data of a `COPY ... FROM STDIN`.
  CopyData(data: BitArray)
  /// The end of the data of a `COPY ... FROM STDIN`.
  CopyDone
  /// Stops a `COPY ... FROM STDIN` with an error message.
  CopyFail(message: String)
  /// Ends the connection.
  Terminate
}

/// One result column of a RowDescription: the description that the client
/// gets, and the two fields that only the wire needs.
pub type ResultColumn {
  ResultColumn(
    column: ColumnDescription,
    /// The type's size in bytes, from `pg_type.typlen`. A negative size is
    /// a type of variable width.
    type_size: Int,
    /// The format of the column's cells. It is always text in the answer
    /// to a Describe of a statement, because no Bind gave a format yet.
    format: Format,
  )
}

/// A message that the server sends to the client.
pub type BackendMessage {
  /// The login is done.
  AuthenticationOk
  /// The server asks for Kerberos V5, which no supported server offers.
  AuthenticationKerberosV5
  /// The server asks for the password in clear.
  AuthenticationCleartextPassword
  /// The server asks for the password as MD5, with this 4-byte salt.
  AuthenticationMd5Password(salt: BitArray)
  /// The server asks for GSSAPI.
  AuthenticationGss
  /// GSSAPI or SSPI data from the server.
  AuthenticationGssContinue(data: BitArray)
  /// The server asks for SSPI.
  AuthenticationSspi
  /// The server asks for SASL, with its mechanisms in its order of
  /// preference.
  AuthenticationSasl(mechanisms: List(String))
  /// A SASL challenge.
  AuthenticationSaslContinue(data: BitArray)
  /// The last SASL data: SASL is done.
  AuthenticationSaslFinal(data: BitArray)
  /// The process ID and the secret key that a CancelRequest needs. The key
  /// has 4 bytes in protocol 3.0, and 4 to 256 bytes in protocol 3.2.
  BackendKeyData(process_id: Int, secret_key: BitArray)
  /// A Bind is done.
  BindComplete
  /// A Close is done.
  CloseComplete
  /// A command is done, with its tag, for example `INSERT 0 3`.
  CommandComplete(tag: String)
  /// The protocol's CopyData from the server: one row of a
  /// `COPY ... TO STDOUT`, or one message of a copy in both directions.
  CopyDataFromServer(data: BitArray)
  /// The protocol's CopyDone from the server: the end of its copy data.
  CopyDoneFromServer
  /// The server waits for the data of a `COPY ... FROM STDIN`.
  CopyInResponse(format: Format, column_formats: List(Format))
  /// The server starts to send the data of a `COPY ... TO STDOUT`.
  CopyOutResponse(format: Format, column_formats: List(Format))
  /// The server starts a copy in both directions, for replication.
  CopyBothResponse(format: Format, column_formats: List(Format))
  /// One row: each value as bytes, or `None` for NULL. The format of each
  /// value is the one of its column.
  DataRow(values: List(Option(BitArray)))
  /// The query string was empty.
  EmptyQueryResponse
  /// An error, with every field the server sent.
  ErrorResponse(report: ServerReport)
  /// The result of a FunctionCall, or `None` for NULL.
  FunctionCallResponse(result: Option(BitArray))
  /// The server does not speak the asked minor protocol version, or does
  /// not know some `_pq_.` startup parameters. It gives the newest version
  /// that it speaks for the asked major version. The docs call this field
  /// the minor version, but PostgreSQL 16 to 19 send the whole version
  /// number, with the major version in the first 16 bits (196608 for 3.0),
  /// so both halves are kept.
  NegotiateProtocolVersion(
    newest_major_version: Int,
    newest_minor_version: Int,
    unrecognized_options: List(String),
  )
  /// The statement or portal returns no rows.
  NoData
  /// A notice, with every field the server sent.
  NoticeResponse(report: ServerReport)
  /// A `NOTIFY` on a channel that this connection listens to.
  NotificationResponse(process_id: Int, channel: String, payload: String)
  /// The parameters of a prepared statement.
  ParameterDescriptions(parameters: List(ParameterDescription))
  /// The value of a run-time parameter, for example `server_version`.
  ParameterStatus(name: String, value: String)
  /// A Parse is done.
  ParseComplete
  /// An Execute stopped at its row limit.
  PortalSuspended
  /// The server waits for a new query, with the transaction status.
  ReadyForQuery(status: TransactionStatus)
  /// The result columns of a query, a statement or a portal.
  RowDescription(columns: List(ResultColumn))
}

/// The answer to an SslRequest or a GssEncryptionRequest.
pub type EncryptionAnswer {
  /// `S` to an SslRequest, `G` to a GssEncryptionRequest: the server starts
  /// the encryption. Bytes after this answer came before the encryption,
  /// so a client must close the connection when there are any.
  EncryptionAccepted
  /// `N`: the server goes on without encryption.
  EncryptionRefused
  /// `E`: the server sent an ErrorResponse. The server is not yet
  /// authenticated, so the PostgreSQL docs say to close the connection and
  /// not to show the message (CVE-2024-10977). The answer keeps no text.
  EncryptionErrorResponse
  /// Any other byte. A client must close the connection.
  UnknownAnswer(answer_byte: Int)
}

/// The result of one step of reading the bytes from the server.
pub type DecodeStep(value) {
  /// A whole value, and the bytes after it.
  Decoded(value: value, rest: BitArray)
  /// The bytes end inside the value. Read more bytes and try again with all
  /// of them.
  NeedMoreBytes
}

/// Why bytes from the server are not a valid message. Each error names the
/// message type byte, so that the message can be found in the docs.
pub type ProtocolError {
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

/// Why a frontend message cannot be written.
pub type EncodeError {
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
  /// A startup parameter name given two times, or the name `user`, which
  /// the StartupMessage has as its own field.
  DuplicateStartupParameter(name: String)
  /// A startup parameter with an empty name. Its zero byte would end the
  /// parameter list early.
  EmptyStartupParameterName
}
