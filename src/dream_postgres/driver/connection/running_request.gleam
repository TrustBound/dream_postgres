//// A request that runs: it sends the step of the request, reads the answer of
//// the server message by message, and goes on to the next step, or to the next
//// request.

import dream_postgres/driver/cell.{
  type CommandResult, type ServerReport, type StatementDescription,
  type TransactionStatus, Idle,
}
import dream_postgres/driver/connection/cancel.{confirm_cancel}
import dream_postgres/driver/connection/copy_exchange.{
  type CopyPush, type CopySession, type CopyStartError, CopySession,
  StartUnencodable,
}
import dream_postgres/driver/connection/copy_process.{
  copy_result, copy_row, deadline_result, paused, running_copy, settle_copy,
}
import dream_postgres/driver/connection/event.{
  type ConnectionEnd, type LossReason, ConnectionLost, ProtocolViolation,
  ServerEndedConnection,
}
import dream_postgres/driver/connection/extended_query_process.{
  housekeeping_run_finisher, prepare_finisher, prepare_refused, run_failure,
  run_finisher, track_prepare,
}
import dream_postgres/driver/connection/idle_messages.{idle_message}
import dream_postgres/driver/connection/notices.{
  after_step, is_notification, keep_asynchronous, take_pending,
}
import dream_postgres/driver/connection/outcome.{
  type Outcome, Outcome, UndecodableMessage, UnexpectedServerMessage,
}
import dream_postgres/driver/connection/process_message.{
  type Prepared, type Request, type RunDetails, type StatementRequest,
  CachedDescription, CopyRequest, HousekeepingRunRequest,
  HousekeepingSimpleQueryRequest, PrepareStatement, Prepared, RunDetails,
  RunStatement, ServerDescription, SettledStatusRequest, SimpleQueryRequest,
  StatementRequest,
}
import dream_postgres/driver/connection/reconnection.{
  lose, lose_if_connected, send_loss,
}
import dream_postgres/driver/connection/refusal.{
  encode_all, refuse_ticket, simple_query_unencodable, statement_sql,
  statement_unencodable,
}
import dream_postgres/driver/connection/reply.{type ReplyTo, reply}
import dream_postgres/driver/connection/request_deadline.{
  answer_deadline, deadline_passed, end_current,
}
import dream_postgres/driver/connection/request_failure.{
  type HousekeepingError, type PrepareError, type RunError, type SettleError,
  type SimpleQueryError, RunRefused, RunStatementChanged,
}
import dream_postgres/driver/connection/settings.{
  CacheStatements, UnnamedStatements,
}
import dream_postgres/driver/connection/simple_query_process.{
  housekeeping_simple_query_finisher, simple_query_finisher,
}
import dream_postgres/driver/connection/state.{
  type Finisher, type Running, type State, type Ticket, Current, Lost, Open,
  RunningCachedRun, RunningCopy, RunningHousekeepingRun,
  RunningHousekeepingSimpleQuery, RunningNamedPrepare, RunningPrepare,
  RunningRun, RunningSimpleQuery, State,
}
import dream_postgres/driver/decode.{decode_backend}
import dream_postgres/driver/housekeeping_sql.{type HousekeepingSql}
import dream_postgres/driver/message.{
  type BackendMessage, type EncodeError, Decoded, NeedMoreBytes,
}
import dream_postgres/driver/query/copy_step.{
  type CopyState, type CopyStep, CopyConnectionEnded, CopyFinished, CopyRow,
  CopySend, CopyStarted, CopyWait,
} as query_copy_step
import dream_postgres/driver/query/extended_query.{
  type PrepareAndRunState, type PrepareState, type RunState,
} as query_extended_query
import dream_postgres/driver/query/simple_query.{type SimpleQueryState} as query_simple_query
import dream_postgres/driver/query/step.{
  type AsynchronousMessage, type CopyDirection, type CopyResult, type Failure,
  type HousekeepingStart, type Start, type Step, type UnexpectedMessage,
  CopyNotSupported, Finished, Send, ServerError, Wait,
} as query_step
import dream_postgres/driver/statement_cache.{
  type CachedStatement, CachedStatement,
}
import dream_postgres/driver/transaction.{
  track_step, transaction_status as tracked_status,
}
import dream_postgres/driver/transport.{type SendError}
import gleam/bool.{guard}
import gleam/erlang/process.{type Pid}
import gleam/erlang/reference.{type Reference}
import gleam/list.{fold, reverse}
import gleam/option.{None, Some}
import gleam/result.{map_error}

/// The server ended the COPY. Its caller gets the result now: with its
/// start, or as a push. After a deadline the result is `DeadlinePassed`.
fn copy_finished(
  state: State,
  session: CopySession,
  outcome: query_step.Outcome(CopyResult, Failure),
) -> State {
  let state = after_step(state, outcome.asynchronous_messages)
  let tracker = track_step(state.tracker, outcome)
  let warning_code = state.warning_code
  let #(state, ended) = copy_result(state, outcome)
  let ended = deadline_result(state, ended)
  State(..state, tracker:, copy: settle_copy(session, ended, warning_code))
  |> next_request
}

/// Decodes and handles each whole message of the buffer.
pub fn read_messages(state: State) -> State {
  read_messages_with(state, <<>>)
}

/// A request runs at once when no request is in progress and no ended
/// COPY waits for its caller. A request is in progress from its start
/// until `next_request` ends it: while a step runs, and also after its
/// step ended while the cancel of its deadline is not done yet, so that
/// cancel can never reach the next request.
///
/// Why the close of the cancel socket is enough (PostgreSQL 16 source):
/// the child that takes a CancelRequest sends SIGINT two times, to the
/// backend and to its process group (postmaster.c signal_child,
/// kill(pid) then kill(-pid)), and exits only after that, which closes
/// the socket (postmaster.c processCancelRequest, ProcessStartupPacket).
/// So when the driver sees the close, both signals are pending on the
/// backend. A pending signal is handled before the backend runs more of
/// its own code, so before it can read the next request. Handled during
/// the statement, it ends that statement with 57014; handled in error
/// recovery, the recovery clears it (postgres.c PostgresMain, the
/// sigsetjmp block); handled while the backend waits for a command, it is
/// dropped, because ProcessInterrupts ignores a cancel while
/// DoingCommandRead and PostgresMain checks for interrupts before it sets
/// DoingCommandRead to false (postgres.c ProcessInterrupts and step 5 of
/// the main loop). The next request therefore never meets an old cancel.
pub fn accept_request(state: State, ticket: Ticket) -> State {
  case state.current, state.copy, state.link {
    None, None, Open(socket:, ..) -> {
      let current = Current(ticket.id, ticket.timer, False, False, False)
      State(
        ..state,
        current: Some(current),
        pending: list.filter(state.pending, is_notification),
        warning_code: None,
      )
      |> begin(socket, ticket.request)
    }
    Some(_in_progress), _, _ | _, Some(_copy), _ ->
      State(..state, waiting: [ticket, ..state.waiting])
    None, None, Lost(refusal:) -> {
      refuse_ticket(ticket, refusal)
      state
    }
  }
}

fn advance(
  state: State,
  socket: transport.Connection,
  running: Running,
  message: BackendMessage,
) -> State {
  case running {
    RunningPrepare(state: step_state, reply: reply_to) ->
      state
      |> advance_prepare(socket, running, step_state, reply_to, message)
    RunningRun(state: step_state, reply: reply_to) ->
      state |> advance_run(socket, running, step_state, reply_to, message)
    RunningSimpleQuery(state: step_state, reply: reply_to) ->
      state |> advance_query(socket, running, step_state, reply_to, message)
    RunningHousekeepingRun(state: step_state, reply: reply_to) ->
      state
      |> advance_housekeeping_run(
        socket,
        running,
        step_state,
        reply_to,
        message,
      )
    RunningHousekeepingSimpleQuery(state: step_state, reply: reply_to) ->
      state
      |> advance_housekeeping_query(
        socket,
        running,
        step_state,
        reply_to,
        message,
      )
    RunningNamedPrepare(state: step_state, request:, name:) ->
      state
      |> advance_named_prepare(
        socket,
        running,
        step_state,
        request,
        name,
        message,
      )
    RunningCachedRun(state: step_state, details:, statement:) ->
      state
      |> advance_cached_run(
        socket,
        running,
        step_state,
        details,
        statement,
        message,
      )
    RunningCopy(state: step_state, session:) ->
      follow_copy(
        state,
        socket,
        query_copy_step.step_copy(step_state, message),
        session,
        running,
      )
  }
}

fn advance_prepare(
  state: State,
  socket: transport.Connection,
  running: Running,
  step_state: PrepareState,
  reply_to: ReplyTo(Result(Prepared, PrepareError)),
  message: BackendMessage,
) -> State {
  follow(
    state,
    socket,
    query_extended_query.step_prepare(step_state, message),
    RunningPrepare(_, reply_to),
    prepare_finisher(reply_to),
    running,
  )
}

fn advance_run(
  state: State,
  socket: transport.Connection,
  running: Running,
  step_state: PrepareAndRunState,
  reply_to: ReplyTo(Result(Outcome, RunError)),
  message: BackendMessage,
) -> State {
  follow(
    state,
    socket,
    query_extended_query.step_prepare_and_run(step_state, message),
    RunningRun(_, reply_to),
    run_finisher(reply_to),
    running,
  )
}

fn advance_query(
  state: State,
  socket: transport.Connection,
  running: Running,
  step_state: SimpleQueryState,
  reply_to: ReplyTo(Result(List(Outcome), SimpleQueryError)),
  message: BackendMessage,
) -> State {
  follow(
    state,
    socket,
    query_simple_query.step_simple_query(step_state, message),
    RunningSimpleQuery(_, reply_to),
    simple_query_finisher(reply_to),
    running,
  )
}

fn advance_housekeeping_run(
  state: State,
  socket: transport.Connection,
  running: Running,
  step_state: PrepareAndRunState,
  reply_to: ReplyTo(Result(Outcome, HousekeepingError)),
  message: BackendMessage,
) -> State {
  follow(
    state,
    socket,
    query_extended_query.step_prepare_and_run(step_state, message),
    RunningHousekeepingRun(_, reply_to),
    housekeeping_run_finisher(reply_to),
    running,
  )
}

fn advance_housekeeping_query(
  state: State,
  socket: transport.Connection,
  running: Running,
  step_state: SimpleQueryState,
  reply_to: ReplyTo(Result(List(Outcome), HousekeepingError)),
  message: BackendMessage,
) -> State {
  follow(
    state,
    socket,
    query_simple_query.step_simple_query(step_state, message),
    RunningHousekeepingSimpleQuery(_, reply_to),
    housekeeping_simple_query_finisher(reply_to),
    running,
  )
}

fn advance_named_prepare(
  state: State,
  socket: transport.Connection,
  running: Running,
  step_state: PrepareState,
  request: StatementRequest,
  name: String,
  message: BackendMessage,
) -> State {
  follow(
    state,
    socket,
    query_extended_query.step_prepare(step_state, message),
    RunningNamedPrepare(_, request, name),
    named_prepare_finisher(request, name),
    running,
  )
}

fn advance_cached_run(
  state: State,
  socket: transport.Connection,
  running: Running,
  step_state: RunState,
  details: RunDetails,
  statement: CachedStatement,
  message: BackendMessage,
) -> State {
  follow(
    state,
    socket,
    query_extended_query.step_run(step_state, message),
    RunningCachedRun(_, details, statement),
    cached_run_finisher(details, statement),
    running,
  )
}

fn begin(
  state: State,
  socket: transport.Connection,
  request: Request,
) -> State {
  case request {
    SimpleQueryRequest(sql:, reply: reply_to) ->
      begin_simple_query(state, socket, sql, reply_to)
    HousekeepingRunRequest(sql:, reply: reply_to) ->
      begin_housekeeping_run(state, socket, sql, reply_to)
    HousekeepingSimpleQueryRequest(sql:, reply: reply_to) ->
      begin_housekeeping_simple_query(state, socket, sql, reply_to)
    StatementRequest(statement) -> begin_statement(state, socket, statement)
    SettledStatusRequest(reply: reply_to) ->
      answer_settled_status(state, reply_to)
    CopyRequest(id:, direction:, sql:, caller:, pushes:, reply: reply_to) ->
      begin_copy_request(
        state,
        socket,
        id,
        direction,
        sql,
        caller,
        pushes,
        reply_to,
      )
  }
}

fn begin_simple_query(
  state: State,
  socket: transport.Connection,
  sql: String,
  reply_to: ReplyTo(Result(List(Outcome), SimpleQueryError)),
) -> State {
  start_step(
    state,
    socket,
    query_simple_query.start_simple_query(sql),
    RunningSimpleQuery(_, reply_to),
    simple_query_unencodable(reply_to, _),
  )
}

fn begin_housekeeping_run(
  state: State,
  socket: transport.Connection,
  sql: HousekeepingSql,
  reply_to: ReplyTo(Result(Outcome, HousekeepingError)),
) -> State {
  start_housekeeping_step(
    state,
    socket,
    query_extended_query.start_housekeeping_run(sql),
    RunningHousekeepingRun(_, reply_to),
  )
}

fn begin_housekeeping_simple_query(
  state: State,
  socket: transport.Connection,
  sql: HousekeepingSql,
  reply_to: ReplyTo(Result(List(Outcome), HousekeepingError)),
) -> State {
  start_housekeeping_step(
    state,
    socket,
    query_simple_query.start_housekeeping_simple_query(sql),
    RunningHousekeepingSimpleQuery(_, reply_to),
  )
}

fn answer_settled_status(
  state: State,
  reply_to: ReplyTo(Result(TransactionStatus, SettleError)),
) -> State {
  reply(reply_to, Ok(tracked_status(state.tracker)))
  next_request(state)
}

fn begin_copy_request(
  state: State,
  socket: transport.Connection,
  id: Reference,
  direction: CopyDirection,
  sql: String,
  caller: Pid,
  pushes: ReplyTo(CopyPush),
  reply_to: ReplyTo(Result(Nil, CopyStartError)),
) -> State {
  let session =
    CopySession(
      id:,
      monitor: process.monitor(caller),
      start: Some(reply_to),
      pushes:,
      waiting_chunks: [],
      finished: False,
      row_pushed: False,
    )
  begin_copy(state, socket, query_copy_step.start_copy(sql, direction), session)
}

/// Sends the first messages of a COPY. A message that cannot be written
/// fails the request before any byte goes out.
fn begin_copy(
  state: State,
  socket: transport.Connection,
  start: Start(CopyState),
  session: CopySession,
) -> State {
  case encode_all(start.messages) {
    Ok(bytes) ->
      running_copy(state, start.state, session)
      |> sent(socket, transport.send(socket, bytes))
    Error(error) -> {
      option.map(session.start, reply(_, Error(StartUnencodable(error))))
      process.demonitor_process(session.monitor)
      next_request(state)
    }
  }
}

fn begin_statement(
  state: State,
  socket: transport.Connection,
  statement: StatementRequest,
) -> State {
  case state.config.statements {
    UnnamedStatements -> begin_unnamed(state, socket, statement)
    CacheStatements(_) -> look_up(state, socket, statement)
  }
}

fn begin_unnamed(
  state: State,
  socket: transport.Connection,
  statement: StatementRequest,
) -> State {
  case statement {
    PrepareStatement(sql:, reply: reply_to, ..) ->
      start_step(
        state,
        socket,
        query_extended_query.start_prepare("", sql, []),
        RunningPrepare(_, reply_to),
        statement_unencodable(statement, _),
      )
    RunStatement(details) ->
      start_step(
        state,
        socket,
        query_extended_query.start_prepare_and_run(
          details.sql,
          [],
          details.parameters,
          details.result_formats,
        ),
        RunningRun(_, details.reply),
        statement_unencodable(statement, _),
      )
  }
}

fn cached_run_finisher(
  details: RunDetails,
  statement: CachedStatement,
) -> Finisher(query_step.Outcome(CommandResult, Failure)) {
  fn(state, socket, outcome) {
    finish_cached_run(state, socket, outcome, details, statement)
  }
}

/// SQLSTATE 0A000 (the cached plan must not change its result type) and
/// 26000 (no such prepared statement) mean that the cached statement is
/// stale: it leaves the cache. Outside a transaction, the run prepares the
/// statement again and runs one more time. Inside one, the error goes to
/// the caller, because the transaction failed.
fn cached_run_refused(
  state: State,
  socket: transport.Connection,
  details: RunDetails,
  cached: CachedStatement,
  report: ServerReport,
  status: TransactionStatus,
) -> State {
  let stale = report.code == "0A000" || report.code == "26000"
  let state = case stale {
    True ->
      State(..state, cache: statement_cache.forget(state.cache, details.sql))
    False -> state
  }
  case stale, details.previous, status {
    True, None, Idle ->
      look_up(
        state,
        socket,
        RunStatement(RunDetails(..details, previous: Some(cached.description))),
      )
    _, _, _ -> {
      reply(details.reply, Error(RunRefused(report, status)))
      state
    }
  }
}

fn finish_cached_run(
  state: State,
  socket: transport.Connection,
  outcome: query_step.Outcome(CommandResult, Failure),
  details: RunDetails,
  cached: CachedStatement,
) -> State {
  let state = after_step(state, outcome.asynchronous_messages)
  let state = State(..state, tracker: track_step(state.tracker, outcome))
  case outcome.result {
    Ok(command) -> {
      let outcome =
        Outcome(cached.description.columns, command, [], [], outcome.status)
      let #(state, single) = take_pending(state, outcome)
      reply(details.reply, Ok(single))
      state
    }
    Error(ServerError(report)) ->
      cached_run_refused(state, socket, details, cached, report, outcome.status)
    Error(CopyNotSupported(..) as failure) -> {
      reply(details.reply, Error(run_failure(failure, outcome.status)))
      state
    }
  }
}

fn finish_named_prepare(
  state: State,
  socket: transport.Connection,
  outcome: query_step.Outcome(StatementDescription, ServerReport),
  request: StatementRequest,
  name: String,
) -> State {
  let state = after_step(state, outcome.asynchronous_messages)
  let state = State(..state, tracker: track_prepare(state.tracker, outcome))
  case outcome.result {
    Ok(description) -> {
      let sql = statement_sql(request)
      let cache = statement_cache.insert(state.cache, sql, name, description)
      prepared(
        State(..state, cache:),
        socket,
        request,
        CachedStatement(name, description),
      )
    }
    Error(report) -> {
      prepare_refused(request, report, outcome.status)
      state
    }
  }
}

/// Goes on with a step: sends what it asks, waits, or finishes it.
fn follow(
  state: State,
  socket: transport.Connection,
  step: Result(Step(step_state, outcome), UnexpectedMessage),
  running: fn(step_state) -> Running,
  finish: Finisher(outcome),
  current: Running,
) -> State {
  case step {
    Ok(Wait(step_state)) -> State(..state, running: Some(running(step_state)))
    Ok(Send(bytes, step_state)) ->
      State(..state, running: Some(running(step_state)))
      |> sent(socket, transport.send(socket, bytes))
    Ok(Finished(outcome)) ->
      answer_deadline(state, current)
      |> finish(socket, outcome)
      |> next_request
    Ok(query_step.ConnectionEnded(report, messages)) ->
      ended(state, socket, current, report, messages)
    Error(unexpected) ->
      failed(
        state,
        socket,
        current,
        ProtocolViolation(UnexpectedServerMessage(unexpected)),
      )
  }
}

/// Goes on with a COPY: tells its caller of the start and of each row,
/// sends what the step asks, waits, or ends it.
fn follow_copy(
  state: State,
  socket: transport.Connection,
  step: Result(CopyStep, UnexpectedMessage),
  session: CopySession,
  current: Running,
) -> State {
  case step {
    Ok(CopyWait(copy_state)) -> running_copy(state, copy_state, session)
    Ok(CopySend(bytes, copy_state)) ->
      running_copy(state, copy_state, session)
      |> sent(socket, transport.send(socket, bytes))
    Ok(CopyStarted(copy_state)) -> {
      option.map(session.start, reply(_, Ok(Nil)))
      running_copy(state, copy_state, CopySession(..session, start: None))
    }
    Ok(CopyRow(row, copy_state)) -> copy_row(state, copy_state, session, row)
    Ok(CopyFinished(outcome)) -> copy_finished(state, session, outcome)
    Ok(CopyConnectionEnded(report, messages)) ->
      ended(state, socket, current, report, messages)
    Error(unexpected) ->
      failed(
        state,
        socket,
        current,
        ProtocolViolation(UnexpectedServerMessage(unexpected)),
      )
  }
}

fn handle_server_message(
  state: State,
  socket: transport.Connection,
  message: BackendMessage,
) -> State {
  case state.running {
    Some(running) ->
      advance(
        State(..confirm_cancel(state, message), running: None),
        socket,
        running,
        message,
      )
    None -> idle_message(state, socket, message)
  }
}

fn look_up(
  state: State,
  socket: transport.Connection,
  statement: StatementRequest,
) -> State {
  let sql = statement_sql(statement)
  let #(cache, found) = statement_cache.lookup(state.cache, sql)
  let state = State(..state, cache:)
  case found {
    Some(cached) -> serve_cached(state, socket, statement, cached)
    None -> prepare_named(state, socket, statement)
  }
}

/// A socket call that failed loses the connection.
pub fn lose_on_error(
  state: State,
  socket: transport.Connection,
  called: Result(Nil, LossReason),
) -> State {
  case called {
    Ok(Nil) -> state
    Error(reason) -> write_failed(state, socket, reason)
  }
}

fn named_prepare_finisher(
  request: StatementRequest,
  name: String,
) -> Finisher(query_step.Outcome(StatementDescription, ServerReport)) {
  fn(state, socket, outcome) {
    finish_named_prepare(state, socket, outcome, request, name)
  }
}

/// When no step runs, and no cancel of it is under way, the current
/// request is done: its timer stops, and the oldest waiting request
/// starts, if one waits.
pub fn next_request(state: State) -> State {
  use <- guard(option.is_some(state.copy), state)
  case state.running, state.current {
    Some(_running), _ -> state
    None, Some(Current(deadline_passed: True, cancel_done: False, ..)) -> state
    None, _ -> start_waiting(end_current(state))
  }
}

/// Prepares the statement under a new name. On a full cache, the least
/// recently used statement leaves it first, and each statement that left
/// the cache is closed on the server in the same round trip.
fn prepare_named(
  state: State,
  socket: transport.Connection,
  statement: StatementRequest,
) -> State {
  let cache = statement_cache.make_room(state.cache)
  let #(cache, name) = statement_cache.new_name(cache)
  let #(cache, closing) = statement_cache.take_stale(cache)
  start_step(
    State(..state, cache:),
    socket,
    query_extended_query.start_prepare_closing(
      closing,
      name,
      statement_sql(statement),
      [],
    ),
    RunningNamedPrepare(_, statement, name),
    statement_unencodable(statement, _),
  )
}

fn prepared(
  state: State,
  socket: transport.Connection,
  request: StatementRequest,
  cached: CachedStatement,
) -> State {
  case request {
    PrepareStatement(reply: reply_to, ..) -> {
      let prepared =
        Prepared(cached.description, warning_code: state.warning_code)
      reply(reply_to, Ok(prepared))
      state
    }
    RunStatement(details) -> run_prepared(state, socket, details, cached)
  }
}

fn read_message(
  state: State,
  socket: transport.Connection,
  bytes: BitArray,
) -> State {
  case decode_backend(bytes) {
    Ok(Decoded(message, rest)) ->
      State(..state, link: Open(socket, rest))
      |> handle_server_message(socket, message)
      |> read_messages
    Ok(NeedMoreBytes) -> State(..state, link: Open(socket, bytes))
    Error(error) ->
      lose(state, socket, ProtocolViolation(UndecodableMessage(error)))
  }
}

/// Decodes and handles each whole message of the buffer, followed by
/// `received`.
fn read_messages_with(state: State, received: BitArray) -> State {
  use <- guard(paused(state), state)
  case state.link {
    Open(socket:, bytes:) ->
      read_message(state, socket, <<bytes:bits, received:bits>>)
    Lost(..) -> state
  }
}

fn run_cached(
  state: State,
  socket: transport.Connection,
  details: RunDetails,
  cached: CachedStatement,
) -> State {
  start_step(
    state,
    socket,
    query_extended_query.start_run(
      cached.name,
      details.parameters,
      details.result_formats,
    ),
    RunningCachedRun(_, details, cached),
    statement_unencodable(RunStatement(details), _),
  )
}

/// A run after a prepare goes on, unless the server made the driver
/// prepare again and the description changed.
fn run_prepared(
  state: State,
  socket: transport.Connection,
  details: RunDetails,
  cached: CachedStatement,
) -> State {
  use <- guard(deadline_passed(state), state)
  case details.previous {
    Some(previous) if previous != cached.description -> {
      reply(details.reply, Error(RunStatementChanged(cached.description)))
      state
    }
    _ -> run_cached(state, socket, details, cached)
  }
}

pub fn sent(
  state: State,
  socket: transport.Connection,
  sent: Result(Nil, SendError),
) -> State {
  lose_on_error(state, socket, sent |> map_error(send_loss))
}

/// A run uses the statement of the cache. A prepare always asks the
/// server, because its answer is the server's description now, which a
/// A run uses the statement of the cache, and so does a prepare that
/// takes the cache's description. A prepare that wants the server's
/// description now closes the cached statement and prepares it again
/// under a new name, in one round trip, and the cache keeps what the
/// server answered (see `describe_current`).
fn serve_cached(
  state: State,
  socket: transport.Connection,
  statement: StatementRequest,
  cached: CachedStatement,
) -> State {
  case statement {
    PrepareStatement(source: CachedDescription, reply: reply_to, ..) -> {
      reply(reply_to, Ok(Prepared(cached.description, warning_code: None)))
      next_request(state)
    }
    PrepareStatement(sql:, source: ServerDescription, ..) -> {
      let cache = statement_cache.forget(state.cache, sql)
      prepare_named(State(..state, cache:), socket, statement)
    }
    RunStatement(details) -> run_cached(state, socket, details, cached)
  }
}

/// Sends the first messages of a step of a housekeeping statement, whose
/// bytes cannot fail to encode.
fn start_housekeeping_step(
  state: State,
  socket: transport.Connection,
  start: HousekeepingStart(step_state),
  running: fn(step_state) -> Running,
) -> State {
  State(..state, running: Some(running(start.state)))
  |> sent(socket, transport.send(socket, start.bytes))
}

/// Sends the first messages of a step. A message that cannot be written
/// fails the request before any byte goes out.
fn start_step(
  state: State,
  socket: transport.Connection,
  start: Start(step_state),
  running: fn(step_state) -> Running,
  fail: fn(EncodeError) -> Nil,
) -> State {
  case encode_all(start.messages) {
    Ok(bytes) ->
      State(..state, running: Some(running(start.state)))
      |> sent(socket, transport.send(socket, bytes))
    Error(error) -> {
      fail(error)
      next_request(state)
    }
  }
}

fn start_waiting(state: State) -> State {
  case reverse(state.waiting) {
    [oldest, ..others] ->
      accept_request(State(..state, waiting: reverse(others)), oldest)
    [] -> state
  }
}

/// A write failed. The server may have sent its last messages before the
/// failure, for example the FATAL error of a session that it ends, and
/// then closed: the process reads them first, so that error wins. If
/// they do not end the connection, the failure of the write does.
pub fn write_failed(
  state: State,
  socket: transport.Connection,
  reason: LossReason,
) -> State {
  read_messages_with(state, transport.received_bytes(socket))
  |> lose_if_connected(socket, ConnectionLost(reason))
}

fn ended(
  state: State,
  socket: transport.Connection,
  current: Running,
  report: ServerReport,
  messages: List(AsynchronousMessage),
) -> State {
  let state = fold(messages, state, keep_asynchronous)
  failed(state, socket, current, ServerEndedConnection(report))
}

/// The request failed in a way that leaves the connection in an unknown
/// state: the caller gets the end, and the process connects again.
fn failed(
  state: State,
  socket: transport.Connection,
  current: Running,
  end: ConnectionEnd,
) -> State {
  lose(State(..state, running: Some(current)), socket, end)
}
