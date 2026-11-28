//// The state of a connection process after its login.

import dream_postgres/driver/connection/event.{ConnectionLost, SocketFailed}
import dream_postgres/driver/connection/notices.{send_notice}
import dream_postgres/driver/connection/process_message.{type Message}
import dream_postgres/driver/connection/request_failure.{
  ConnectionEnded, RefusedWithFailure,
}
import dream_postgres/driver/connection/settings.{
  type ConnectionConfig, CacheStatements, UnnamedStatements,
}
import dream_postgres/driver/connection/startup.{type Session}
import dream_postgres/driver/connection/state.{type State, Lost, Open, State}
import dream_postgres/driver/statement_cache.{type StatementCache}
import dream_postgres/driver/transaction.{new_tracker, track}
import dream_postgres/driver/transport.{SocketClosed}
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/list.{fold}
import gleam/option.{None}

pub fn new_state(config: ConnectionConfig, subject: Subject(Message)) -> State {
  State(
    config:,
    subject:,
    link: Lost(
      RefusedWithFailure(
        ConnectionEnded(ConnectionLost(SocketFailed(SocketClosed))),
      ),
    ),
    parameters: dict.new(),
    tracker: new_tracker(),
    running: None,
    current: None,
    waiting: [],
    next_id: 1,
    cancel_key: None,
    pending: [],
    warning_code: None,
    cache: new_cache(config),
    copy: None,
  )
}

fn new_cache(config: ConnectionConfig) -> StatementCache {
  case config.statements {
    CacheStatements(limit:) -> statement_cache.new(limit)
    UnnamedStatements -> statement_cache.new(1)
  }
}

/// The state of a session that just logged in. Bytes that came after the
/// login's ReadyForQuery wait in the buffer, for `read_messages` after
/// the process told of the login.
pub fn connected_state(state: State, session: Session) -> State {
  let state = fold(session.outcome.notices, state, send_notice)
  State(
    ..state,
    link: Open(session.socket, session.bytes),
    parameters: session.outcome.parameters,
    tracker: track(new_tracker(), session.outcome.transaction_status, None),
    cache: new_cache(state.config),
    cancel_key: session.outcome.cancel_key,
    pending: state.pending,
  )
}
