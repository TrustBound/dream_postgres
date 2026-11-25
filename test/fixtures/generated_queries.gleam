//// Runs the queries of two modules that the SQL generator wrote, with
//// `client_module = "dream_postgres/client"`: `generated/database_sql` from
//// the `database` example of Dream and `generated/task_sql` from its
//// `tasks` example. Only the import line of each module changed, from
//// `import dream_postgres_client as pog` to
//// `import dream_postgres/client as pog`.
////
//// The tables are the tables of the migrations of the examples. Each
//// timestamp column has a fixed default in place of `NOW()`, so a recording
//// is the same at each run. The scenarios leave out `toggle_completed` and
//// `update_task`, because they set `updated_at = NOW()`.

import dream_postgres/client as postgres
import generated/database_sql
import generated/task_sql
import gleam/string
import gleam/time/calendar

/// The fixed time of each new row.
const created_at = "'2026-01-02 03:04:05'"

fn run(db: postgres.Connection, sql: String) -> String {
  postgres.query(sql)
  |> postgres.execute(db)
  |> string.inspect
}

/// Runs the queries of the `database` example in order, and gives each
/// result as text.
pub fn database_scenario(db: postgres.Connection) -> List(String) {
  [
    run(
      db,
      "CREATE TABLE users (id SERIAL PRIMARY KEY, name VARCHAR(255) NOT NULL, email VARCHAR(255) UNIQUE NOT NULL, created_at TIMESTAMP DEFAULT "
        <> created_at
        <> ")",
    ),
    run(
      db,
      "CREATE TABLE posts (id SERIAL PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE, title VARCHAR(255) NOT NULL, content TEXT, created_at TIMESTAMP DEFAULT "
        <> created_at
        <> ")",
    ),
    string.inspect(database_sql.create_user(db, "Ada", "ada@example.com")),
    string.inspect(database_sql.create_user(db, "Ada", "ada@example.com")),
    string.inspect(database_sql.create_post(db, 1, "Hello", "The first post")),
    string.inspect(database_sql.get_user(db, 1)),
    string.inspect(database_sql.get_post(db, 1)),
    string.inspect(database_sql.list_users(db)),
    string.inspect(database_sql.list_posts(db, 1)),
    string.inspect(database_sql.update_user(
      db,
      "Ada Lovelace",
      "ada@example.org",
      1,
    )),
    string.inspect(database_sql.delete_user(db, 1)),
    string.inspect(database_sql.list_posts(db, 1)),
  ]
}

/// Runs the queries of the `tasks` example in order, and gives each result
/// as text.
pub fn task_scenario(db: postgres.Connection) -> List(String) {
  let due = calendar.Date(2026, calendar.November, 30)
  [
    run(
      db,
      "CREATE TABLE projects (id SERIAL PRIMARY KEY, name TEXT NOT NULL, description TEXT, color TEXT, created_at TIMESTAMP NOT NULL DEFAULT "
        <> created_at
        <> ")",
    ),
    run(
      db,
      "CREATE TABLE tasks (id SERIAL PRIMARY KEY, title TEXT NOT NULL, description TEXT, completed BOOLEAN NOT NULL DEFAULT FALSE, priority INTEGER NOT NULL DEFAULT 3, due_date DATE, position INTEGER NOT NULL DEFAULT 0, project_id INTEGER REFERENCES projects(id) ON DELETE SET NULL, created_at TIMESTAMP NOT NULL DEFAULT "
        <> created_at
        <> ", updated_at TIMESTAMP NOT NULL DEFAULT "
        <> created_at
        <> ")",
    ),
    string.inspect(task_sql.create_task(
      db,
      "Write the docs",
      "For 2.1.0",
      False,
      2,
      due,
      1,
      0,
    )),
    string.inspect(task_sql.create_task(db, "Tag", "", True, 3, due, 2, 0)),
    string.inspect(task_sql.get_task(db, 1)),
    string.inspect(task_sql.list_tasks(db)),
    string.inspect(task_sql.list_by_project(db, 1)),
    string.inspect(task_sql.update_position(db, 2, 5)),
    string.inspect(task_sql.delete_task(db, 1)),
    string.inspect(task_sql.list_tasks(db)),
  ]
}

/// The results of `database_scenario`, live and played back.
pub const database_results = [
  "Ok(Returned(0, []))",
  "Ok(Returned(0, []))",
  "Ok(Returned(1, [CreateUserRow(1, \"Ada\", \"ada@example.com\", Some(Timestamp(1767323045, 0)))]))",
  "Error(ConstraintViolated(\"duplicate key value violates unique constraint \\\"users_email_key\\\"\", \"users_email_key\", \"Key (email)=(ada@example.com) already exists.\"))",
  "Ok(Returned(1, [CreatePostRow(1, 1, \"Hello\", Some(\"The first post\"), Some(Timestamp(1767323045, 0)))]))",
  "Ok(Returned(1, [GetUserRow(1, \"Ada\", \"ada@example.com\", Some(Timestamp(1767323045, 0)))]))",
  "Ok(Returned(1, [GetPostRow(1, 1, \"Hello\", Some(\"The first post\"), Some(Timestamp(1767323045, 0)))]))",
  "Ok(Returned(1, [ListUsersRow(1, \"Ada\", \"ada@example.com\", Some(Timestamp(1767323045, 0)))]))",
  "Ok(Returned(1, [ListPostsRow(1, 1, \"Hello\", Some(\"The first post\"), Some(Timestamp(1767323045, 0)))]))",
  "Ok(Returned(1, [UpdateUserRow(1, \"Ada Lovelace\", \"ada@example.org\", Some(Timestamp(1767323045, 0)))]))",
  "Ok(Returned(1, []))",
  "Ok(Returned(0, []))",
]

/// The results of `task_scenario`, live and played back.
pub const task_results = [
  "Ok(Returned(0, []))",
  "Ok(Returned(0, []))",
  "Ok(Returned(1, [CreateTaskRow(1, \"Write the docs\", Some(\"For 2.1.0\"), False, 2, Some(Date(2026, November, 30)), 1, None, Timestamp(1767323045, 0), Timestamp(1767323045, 0))]))",
  "Ok(Returned(1, [CreateTaskRow(2, \"Tag\", Some(\"\"), True, 3, Some(Date(2026, November, 30)), 2, None, Timestamp(1767323045, 0), Timestamp(1767323045, 0))]))",
  "Ok(Returned(1, [GetTaskRow(1, \"Write the docs\", Some(\"For 2.1.0\"), False, 2, Some(Date(2026, November, 30)), 1, None, Timestamp(1767323045, 0), Timestamp(1767323045, 0))]))",
  "Ok(Returned(2, [ListTasksRow(1, \"Write the docs\", Some(\"For 2.1.0\"), False, 2, Some(Date(2026, November, 30)), 1, None, Timestamp(1767323045, 0), Timestamp(1767323045, 0)), ListTasksRow(2, \"Tag\", Some(\"\"), True, 3, Some(Date(2026, November, 30)), 2, None, Timestamp(1767323045, 0), Timestamp(1767323045, 0))]))",
  "Ok(Returned(0, []))",
  "Ok(Returned(1, [UpdatePositionRow(2, \"Tag\", Some(\"\"), True, 3, Some(Date(2026, November, 30)), 5, None, Timestamp(1767323045, 0), Timestamp(1767323045, 0))]))",
  "Ok(Returned(1, []))",
  "Ok(Returned(1, [ListTasksRow(2, \"Tag\", Some(\"\"), True, 3, Some(Date(2026, November, 30)), 5, None, Timestamp(1767323045, 0), Timestamp(1767323045, 0))]))",
]
