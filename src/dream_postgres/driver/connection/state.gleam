//// The state of a connection process: its link, its running request, and the
//// requests that wait.

import dream_postgres/driver/connection/copy_exchange.{
  type CopySession, type EndedCopy,
}
import dream_postgres/driver/connection/outcome.{type Outcome}
import dream_postgres/driver/connection/process_message.{
  type Message, type Prepared, type Request, type RunDetails,
  type StatementRequest,
}
import dream_postgres/driver/connection/reply.{type ReplyTo}
import dream_postgres/driver/connection/request_failure.{
  type HousekeepingError, type PrepareError, type Refusal, type RunError,
  type SimpleQueryError,
}
import dream_postgres/driver/connection/settings.{type ConnectionConfig}
import dream_postgres/driver/login.{type CancelKey}
import dream_postgres/driver/query/copy_step.{type CopyState}
import dream_postgres/driver/query/extended_query.{
  type PrepareAndRunState, type PrepareState, type RunState,
}
import dream_postgres/driver/query/simple_query.{type SimpleQueryState}
import dream_postgres/driver/query/step.{type AsynchronousMessage}
import dream_postgres/driver/statement_cache.{
  type CachedStatement, type StatementCache,
}
import dream_postgres/driver/transaction.{type TransactionTracker}
import dream_postgres/driver/transport
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject, type Timer}
import gleam/option.{type Option}

pub type State {
  State(
    config: ConnectionConfig,
    subject: Subject(Message),
    link: Link,
    parameters: Dict(String, String),
    tracker: TransactionTracker,
    running: Option(Running),
    /// The request that runs, with its deadline.
    current: Option(Current),
    /// The requests that wait, newest first.
    waiting: List(Ticket),
    /// The number of the next request.
    next_id: Int,
    /// The key of this session for a CancelRequest.
    cancel_key: Option(CancelKey),
    /// The notices of the running request and the notifications since the
    /// last outcome, newest first.
    pending: List(AsynchronousMessage),
    /// The last warning code (class 01) of the running request, for the
    /// span of a request whose result holds no notices.
    warning_code: Option(String),
    /// The named statements of this session.
    cache: StatementCache,
    /// A COPY that ended, until its caller finishes its side.
    copy: Option(EndedCopy),
  )
}

/// The request that runs, with the state of its step.
pub type Running {
  /// A prepare of the unnamed statement, with no cache.
  RunningPrepare(
    state: PrepareState,
    reply: ReplyTo(Result(Prepared, PrepareError)),
  )
  /// A run in one round trip on the unnamed statement, with no cache.
  RunningRun(
    state: PrepareAndRunState,
    reply: ReplyTo(Result(Outcome, RunError)),
  )
  RunningSimpleQuery(
    state: SimpleQueryState,
    reply: ReplyTo(Result(List(Outcome), SimpleQueryError)),
  )
  /// A run of a driver housekeeping statement on the unnamed statement.
  RunningHousekeepingRun(
    state: PrepareAndRunState,
    reply: ReplyTo(Result(Outcome, HousekeepingError)),
  )
  /// A driver housekeeping statement with the simple query protocol.
  RunningHousekeepingSimpleQuery(
    state: SimpleQueryState,
    reply: ReplyTo(Result(List(Outcome), HousekeepingError)),
  )
  /// A prepare under a new name, for the cache.
  RunningNamedPrepare(
    state: PrepareState,
    request: StatementRequest,
    name: String,
  )
  /// A run of a statement of the cache.
  RunningCachedRun(
    state: RunState,
    details: RunDetails,
    statement: CachedStatement,
  )
  RunningCopy(state: CopyState, session: CopySession)
}

pub type Link {
  /// Connected and logged in. `bytes` are read but not decoded yet.
  Open(socket: transport.Connection, bytes: BitArray)
  /// Lost. Requests are refused with `refusal` until the process connects
  /// again.
  Lost(refusal: Refusal)
}

/// A request that waits, with its number and its deadline timer.
pub type Ticket {
  Ticket(id: Int, request: Request, timer: Timer)
}

/// The deadline of the request that runs. After the deadline, the caller
/// gets `DeadlinePassed`; `cancel_confirmed` says whether the server
/// stopped the statement with 57014. The request ends only when its step
/// ended and its cancel is done (`cancel_done`): the server handles a
/// CancelRequest on its own, and one that came late would stop the next
/// statement.
pub type Current {
  Current(
    id: Int,
    timer: Timer,
    deadline_passed: Bool,
    cancel_confirmed: Bool,
    cancel_done: Bool,
  )
}

/// What finishes a step: the state, the socket for a next step of the
/// same request, and the step's outcome.
pub type Finisher(outcome) =
  fn(State, transport.Connection, outcome) -> State
