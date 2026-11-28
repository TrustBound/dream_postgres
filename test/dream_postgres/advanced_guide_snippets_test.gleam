//// Tests of the snippet files that the copy, listen and notify, tracing,
//// interceptors, recorded queries, boot check and upgrade guides show,
//// and of the snippet files of the doc comments in `src`.
////
//// The tests with a database run on PostgreSQL 16, and the second
//// listener test on PostgreSQL 17, so that the two listeners of the
//// channel `jobs` never get each other's notifications.

import dream_postgres/codec
import dream_postgres/codecs/range.{Exclusive, Inclusive, Range}
import dream_postgres/config.{type PoolEvent, type ServerNotice, Connected}
import dream_postgres/error
import dream_postgres/listener.{
  type ListenMessage, named_listener, stop_listener,
}
import dream_postgres/pool.{with_connection}
import dream_postgres/query.{affected, named, one, parameter, query, run_sql}
import dream_postgres/recorder
import dream_postgres/recording
import dream_postgres/row.{single}
import dream_postgres/sql_state
import dream_test/context
import dream_test/matchers.{
  be_equal, be_error, be_ok, be_true, contain, or_fail_with, should,
}
import dream_test/suite.{type TestSuite}
import dream_test/unit
import dream_test/unit_context.{before_all, describe, group, it}
import dream_uuid
import driver/listener_gate
import driver/test_tracer.{install_test_tracer, record_spans_here, spans_now}
import fixtures/listen_messages
import fixtures/no_database
import fixtures/recorded_scenarios
import fixtures/recording_paths
import fixtures/server_error
import fixtures/server_pools
import fixtures/server_versions
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/calendar.{Date, January}
import matchers/describe_each_error.{describe_each_error}
import matchers/extract_notice_message.{extract_notice_message}
import matchers/extract_span_attributes.{extract_span_attributes}
import matchers/extract_span_names.{extract_span_names}
import matchers/have_kind_name.{have_kind_name}
import matchers/receive_message.{receive_message}
import matchers/run_and_stop_pool.{run_and_stop_pool}
import matchers/run_and_stop_supervisor.{run_and_stop_supervisor}
import matchers/run_in_rolled_back_transaction.{run_in_rolled_back_transaction}
import matchers/run_on_pool.{run_on_pool}
import matchers/run_with_supervised_listener.{run_with_supervised_listener}
import matchers/run_with_temporary_table.{run_with_temporary_table}
import matchers/stop_pool.{stop_pool}
import simplifile
import snippets/address_codec.{Address, address_codec}
import snippets/answer_three_updates.{answer_three_updates}
import snippets/answer_with_two_posts.{answer_with_two_posts}
import snippets/booking_period_codec.{booking_period_codec}
import snippets/check_database.{check_database}
import snippets/copy_users.{User, load_users}
import snippets/count_invoices.{count_invoices}
import snippets/create_api_key.{create_api_key}
import snippets/empty_recording_text.{empty_recording_text}
import snippets/existing_post_ids.{existing_post_ids}
import snippets/export_users.{export_users}
import snippets/job_events.{JobMessage, ListenerEnded, job_events}
import snippets/list_titles.{list_titles}
import snippets/listen_by_name.{listen_by_name}
import snippets/listen_for_jobs.{listen_for_jobs}
import snippets/load_invoice_totals.{load_invoice_totals}
import snippets/ltree_codec.{Path, ltree_codec}
import snippets/mood_codec.{Sad, mood_codec}
import snippets/named_query.{find_user_id}
import snippets/next_job.{next_job}
import snippets/posts.{Post, create}
import snippets/read_recording.{read_recording}
import snippets/refuse_deletes.{refuse_deletes}
import snippets/replay_server_error.{replay_server_error}
import snippets/run_create_api_key.{run_create_api_key}
import snippets/scores_codec.{scores_codec}
import snippets/signup_errors.{MissingField}
import snippets/simulate_deadlock.{simulate_deadlock}
import snippets/simulate_lost_connection.{simulate_lost_connection}
import snippets/simulate_timeout.{simulate_timeout}
import snippets/start_api_key_recorder.{start_api_key_recorder}
import snippets/start_app_pool.{start_app_pool}
import snippets/start_app_supervisor.{start_app_supervisor}
import snippets/start_listener_supervisor.{start_listener_supervisor}
import snippets/start_pool_on.{start_pool_on}
import snippets/start_pool_with_events.{start_pool_with_events}
import snippets/start_pool_with_notices.{start_pool_with_notices}
import snippets/start_pool_with_private_authority.{
  start_pool_with_private_authority,
}
import snippets/start_pool_without_statement_cache.{
  start_pool_without_statement_cache,
}
import snippets/start_sql_only_recorder.{start_sql_only_recorder}
import snippets/start_tagged_pool.{start_tagged_pool}
import snippets/stop_listening.{stop_listening}
import snippets/sum_of_totals.{sum_of_totals}
import snippets/tagged_query
import snippets/unnamed_query.{count_users}
import snippets/upgrade_connect_database.{connect_database}
import snippets/upgrade_create_user.{create_user, created_response}
import snippets/upgrade_find_user.{find_user}
import snippets/upgrade_show_user.{Response, show_user_response}
import snippets/user_report.{user_report}
import snippets/with_api_keys_table.{with_api_keys_table}

/// The port of the PostgreSQL 16 test server.
const port_16 = 5441

/// The snippets that need a database.
pub fn tests() -> TestSuite {
  describe(
    "the snippets of the guides and doc comments",
    context.setup(server_pools.start, teardown: server_pools.stop),
    [
      group("PostgreSQL 16", [
        before_all(server_pools.choose_version(16)),
        it("posts.gleam create stores a post", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_with_temporary_table(
            "posts",
            "(id serial, user_id int4, title text)",
            create(_, 7, "Hello"),
          )
          |> be_ok()
          |> be_equal(Post(id: 1, user_id: 7, title: "Hello"))
          |> or_fail_with("Expected the new post")
        }),
        it(
          "existing_post_ids.gleam existing_post_ids reads an array parameter",
          fn(pools) {
            // Act and assert
            pools
            |> should
            |> run_with_temporary_table(
              "posts",
              "(id serial, user_id int4, title text)",
              fn(held) {
                use _first <- result.try(create(held, 7, "First"))
                use _second <- result.try(create(held, 7, "Second"))
                existing_post_ids(held, [1, 2, 5])
              },
            )
            |> be_ok()
            |> be_equal([1, 2])
            |> or_fail_with("Expected the ids 1 and 2")
          },
        ),
        it("tagged_query.gleam puts the tag in front of the SQL", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_on_pool(tagged_query.current_sql)
          |> be_ok()
          |> be_equal("/* billing */ SELECT current_query()")
          |> or_fail_with("Expected the tagged SQL")
        }),
        it("start_tagged_pool.gleam tags each query", fn(_pools) {
          // Act and assert
          start_tagged_pool(server_pools.config(port_16))
          |> should
          |> be_ok()
          |> run_and_stop_pool(fn(pool) {
            query("SELECT current_query()") |> one(single(codec.text), pool)
          })
          |> be_ok()
          |> be_equal("/* billing */ SELECT current_query()")
          |> or_fail_with("Expected the tagged SQL")
        }),
        it("start_app_pool.gleam starts a pool", fn(_pools) {
          // Act and assert
          start_app_pool("secret")
          |> should
          |> be_ok()
          |> stop_pool()
          |> be_equal(Nil)
          |> or_fail_with("Expected the pool to start")
        }),
        it("start_pool_on.gleam starts a pool", fn(_pools) {
          // Act and assert
          start_pool_on("localhost")
          |> should
          |> be_ok()
          |> stop_pool()
          |> be_equal(Nil)
          |> or_fail_with("Expected the pool to start")
        }),
        it("start_pool_with_private_authority.gleam starts a pool", fn(_pools) {
          // Act and assert
          start_pool_with_private_authority("localhost")
          |> should
          |> be_ok()
          |> stop_pool()
          |> be_equal(Nil)
          |> or_fail_with("Expected the pool to start")
        }),
        it("start_pool_without_statement_cache.gleam runs queries", fn(_pools) {
          // Act and assert
          start_pool_without_statement_cache(server_pools.config(port_16))
          |> should
          |> be_ok()
          |> run_and_stop_pool(fn(pool) {
            query("SELECT 1") |> one(single(codec.int), pool)
          })
          |> be_ok()
          |> be_equal(1)
          |> or_fail_with("Expected 1")
        }),
        it("start_pool_with_notices.gleam sends notices", fn(_pools) {
          // Arrange
          let notices: process.Subject(ServerNotice) = process.new_subject()

          // Act and assert
          start_pool_with_notices(server_pools.config(port_16), notices)
          |> should
          |> be_ok()
          |> run_and_stop_pool(run_sql(
            "DO $$ BEGIN RAISE NOTICE 'hello'; END $$",
            _,
          ))
          |> receive_message(notices, within: 5000)
          |> extract_notice_message()
          |> be_equal("hello")
          |> or_fail_with("Expected the notice hello")
        }),
        it("start_pool_with_events.gleam sends events", fn(_pools) {
          // Arrange
          let events: process.Subject(PoolEvent) = process.new_subject()

          // Act and assert
          start_pool_with_events(
            server_pools.config(port_16) |> config.pool_size(1),
            events,
          )
          |> should
          |> be_ok()
          |> run_and_stop_pool(fn(_pool) { process.receive(events, 5000) })
          |> be_ok()
          |> be_equal(Connected(slot: 0))
          |> or_fail_with("Expected the connect of slot 0 first")
        }),
        it("check_database.gleam passes on the schema", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_with_temporary_table(
            "users",
            "(id int4, email text)",
            check_database,
          )
          |> be_ok()
          |> be_equal(Nil)
          |> or_fail_with("Expected every query to fit the table")
        }),
        it(
          "copy_users.gleam and export_users.gleam load and export users",
          fn(pools) {
            // Arrange
            let users = [User(1, Some("ada@example.com")), User(2, None)]

            // Act and assert
            pools
            |> should
            |> run_with_temporary_table(
              "users",
              "(id int4, email text)",
              fn(held) {
                use stored <- result.try(load_users(held, users))
                use exported <- result.try(export_users(held))
                Ok(#(stored, exported))
              },
            )
            |> be_ok()
            |> be_equal(#(2, users))
            |> or_fail_with("Expected the two users stored and read back")
          },
        ),
        it(
          "load_invoice_totals, sum_of_totals and count_invoices load, sum and count invoices",
          fn(pools) {
            // Act and assert
            pools
            |> should
            |> run_in_rolled_back_transaction(fn(held) {
              use Nil <- result.try(run_sql(
                "CREATE SCHEMA billing; CREATE TABLE billing.invoices (total int4)",
                held,
              ))
              use stored <- result.try(load_invoice_totals(held, [10, 20, 30]))
              use sum <- result.try(sum_of_totals(held))
              use Nil <- result.try(run_sql(
                "INSERT INTO billing.invoices VALUES (NULL)",
                held,
              ))
              use count <- result.try(count_invoices(held))
              Ok(#(stored, sum, count))
            })
            |> be_ok()
            |> be_equal(#(3, 60, 4))
            |> or_fail_with("Expected 3 stored, a sum of 60 and 4 invoices")
          },
        ),
        it("signup_errors.gleam names the column of a NOT NULL", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_with_temporary_table(
            "signups",
            "(email text NOT NULL)",
            fn(held) {
              query("INSERT INTO signups (email) VALUES (NULL)")
              |> affected(held)
              |> result.map_error(signup_errors.signup_error)
            },
          )
          |> be_error()
          |> be_equal(MissingField("email"))
          |> or_fail_with("Expected the missing email")
        }),
        it("user_report.gleam counts the users", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_with_temporary_table("users", "(id int4)", fn(held) {
            use Nil <- result.try(run_sql(
              "INSERT INTO users VALUES (1), (2)",
              held,
            ))
            user_report(held)
          })
          |> be_ok()
          |> be_equal(2)
          |> or_fail_with("Expected 2 users")
        }),
        it("the codec snippets read and write each value", fn(pools) {
          // Arrange
          let period =
            Range(
              Inclusive(Date(2026, January, 5)),
              Exclusive(Date(2026, January, 9)),
            )

          // Act and assert
          pools
          |> should
          |> run_on_pool(
            with_connection(_, fn(held) {
              use Nil <- result.try(run_sql(
                "CREATE TYPE pg_temp.mood AS ENUM ('happy', 'sad');
CREATE TYPE pg_temp.address AS (street text, city text)",
                held,
              ))
              use scores <- result.try(
                query("SELECT $1::int4[]")
                |> parameter(scores_codec(), [Some(1), None])
                |> one(single(scores_codec()), held),
              )
              use booking <- result.try(
                query("SELECT $1::daterange")
                |> parameter(booking_period_codec(), period)
                |> one(single(booking_period_codec()), held),
              )
              use mood <- result.try(
                query("SELECT 'sad'::mood")
                |> one(single(mood_codec()), held),
              )
              use path <- result.try(
                query("SELECT $1::ltree")
                |> parameter(ltree_codec(), Path(["top", "science"]))
                |> one(single(ltree_codec()), held),
              )
              use address <- result.try(
                query("SELECT ROW('1 Main St', NULL)::address")
                |> one(single(address_codec()), held),
              )
              Ok(#(scores, booking, mood, path, address))
            }),
          )
          |> be_ok()
          |> be_ok()
          |> be_equal(#(
            [Some(1), None],
            period,
            Sad,
            Path(["top", "science"]),
            Address(street: "1 Main St", city: None),
          ))
          |> or_fail_with("Expected each value back")
        }),
        it("listen_for_jobs.gleam gets the payload of a job", fn(pools) {
          // Arrange
          let jobs: process.Subject(ListenMessage) = process.new_subject()

          // Act and assert
          pools
          |> should
          |> run_on_pool(fn(pool) {
            use #(listener, subscription) <- result.try(listen_for_jobs(
              server_pools.config(port_16),
              jobs,
            ))
            use Nil <- result.try(run_sql("NOTIFY jobs, 'build-42'", pool))
            let job = next_job(jobs)
            use Nil <- result.try(stop_listening(listener, subscription))
            Ok(job)
          })
          |> be_ok()
          |> be_equal(Ok("build-42"))
          |> or_fail_with("Expected the payload build-42")
        }),
        it("named_query.gleam names the span of a named query", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_with_temporary_table(
            "users",
            "(id int4, email text)",
            fn(held) {
              install_test_tracer()
              record_spans_here()
              let _found = find_user_id(held, "ada@example.com")
              spans_now()
            },
          )
          |> extract_span_names()
          |> be_equal(["user.find_by_email", "user.find_by_email"])
          |> or_fail_with("Expected the spans named after the query")
        }),
        it("named_query.gleam records no parameter value", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_with_temporary_table(
            "users",
            "(id int4, email text)",
            fn(held) {
              install_test_tracer()
              record_spans_here()
              let _found = find_user_id(held, "ada@example.com")
              spans_now()
            },
          )
          |> extract_span_attributes()
          |> be_equal([
            #("db.namespace", "dream_test"),
            #("db.query.summary", "user.find_by_email"),
            #("db.query.text", "SELECT id FROM users WHERE email = $1"),
            #("db.system.name", "postgresql"),
            #("server.address", "localhost"),
            #("server.port", "5441"),
            #("db.namespace", "dream_test"),
            #("db.operation.name", "SELECT"),
            #("db.query.summary", "user.find_by_email"),
            #("db.query.text", "SELECT id FROM users WHERE email = $1"),
            #("db.system.name", "postgresql"),
            #("server.address", "localhost"),
            #("server.port", "5441"),
          ])
          |> or_fail_with("Expected the attributes of the spans")
        }),
        it(
          "unnamed_query.gleam names an unnamed span by its operation",
          fn(pools) {
            // Act and assert
            pools
            |> should
            |> run_with_temporary_table("users", "(id int4)", fn(held) {
              install_test_tracer()
              record_spans_here()
              let _counted = count_users(held)
              spans_now()
            })
            |> extract_span_names()
            |> be_equal(["dream_test", "SELECT dream_test"])
            |> or_fail_with("Expected the span named after the operation")
          },
        ),
        it(
          "run_create_api_key.gleam plays back the recording of the repository",
          fn(_pools) {
            // Act
            let created = {
              use test_recorder <- result.try(start_api_key_recorder(
                recorder.Playback,
              ))
              run_create_api_key(server_pools.config(1), test_recorder, 7)
            }

            // Assert
            created
            |> result.map(fn(api_key) { dream_uuid.to_string(api_key.id) })
            |> should
            |> be_ok()
            |> be_equal("deadbeef-dead-4eef-8ead-beef00000001")
            |> or_fail_with("Expected the placeholder of the recorded UUID")
          },
        ),
        it(
          "start_app_supervisor.gleam plays back under a supervisor through the pool name",
          fn(_pools) {
            // Arrange
            let pool_name = process.new_name("played_app_pool")
            let path =
              recording_paths.unique(
                in: "build/snippet_recordings",
                name: "api_key_create",
              )
            let copied =
              simplifile.create_directory_all("build/snippet_recordings")
              |> result.try(fn(_made) {
                simplifile.copy_file(
                  "test/recordings/api_key_create.json",
                  path,
                )
              })
              |> result.map_error(string.inspect)

            // Act and assert
            copied
            |> result.try(fn(_copied) {
              recorder.new(file: path)
              |> recorded_scenarios.normalized
              |> recorder.start
              |> result.map_error(error.describe)
            })
            |> result.try(start_app_supervisor(
              server_pools.config(1),
              _,
              pool_name,
            ))
            |> should
            |> be_ok()
            |> run_and_stop_supervisor(fn() {
              with_api_keys_table(
                pool.named_connection(pool_name),
                create_api_key(_, 7, "s3cret"),
              )
              |> result.map(fn(api_key) { dream_uuid.to_string(api_key.id) })
            })
            |> be_ok()
            |> be_equal("deadbeef-dead-4eef-8ead-beef00000001")
            |> or_fail_with("Expected the recorded key through the pool name")
          },
        ),
        it(
          "start_sql_only_recorder.gleam starts a recorder that matches on the SQL only",
          fn(_pools) {
            // Act and assert
            start_sql_only_recorder(recorder.Passthrough)
            |> should
            |> be_ok()
            |> or_fail_with("Expected the recorder to start")
          },
        ),
        it("start_listener_supervisor.gleam names the listener", fn(_pools) {
          // Arrange
          let notifications = process.new_name("snippet_listener")
          let jobs: process.Subject(ListenMessage) = process.new_subject()

          // Act and assert
          start_listener_supervisor(server_pools.config(port_16), notifications)
          |> should
          |> be_ok()
          |> run_and_stop_supervisor(fn() {
            listen_by_name(notifications, jobs)
            |> result.is_ok
          })
          |> be_true()
          |> or_fail_with("Expected a subscription through the name")
        }),
        it("the upgrade snippets find and create users", fn(pools) {
          // Act and assert
          pools
          |> should
          |> run_with_temporary_table(
            "users",
            "(id serial, name text, email text UNIQUE)",
            fn(held) {
              let created = create_user(held, "Ada", "ada@example.com")
              let duplicate = create_user(held, "Ann", "ada@example.com")
              let found = find_user(held, 1)
              let missing = find_user(held, 9)
              #(
                created_response(created),
                created_response(duplicate),
                show_user_response(found),
                show_user_response(missing),
              )
            },
          )
          |> be_equal(#(
            Response(201, "Created user 1"),
            Response(409, "That email is already taken"),
            Response(200, "Ada"),
            Response(404, "User not found"),
          ))
          |> or_fail_with("Expected the four responses")
        }),
        it("upgrade_connect_database.gleam starts a pool", fn(_pools) {
          // Act and assert
          connect_database()
          |> should
          |> be_ok()
          |> stop_pool()
          |> be_equal(Nil)
          |> or_fail_with("Expected the pool to start")
        }),
      ]),
      group(
        "check_database.gleam after a schema change",
        list.map(server_versions.all(), fn(version) {
          group(server_versions.group_name(version), [
            before_all(server_pools.choose_version(version)),
            it("names a column whose type changed after a run", fn(pools) {
              // Act and assert
              pools
              |> should
              |> run_with_temporary_table(
                "users",
                "(id int4, email text)",
                fn(held) {
                  use _deleted <- result.try(
                    query("DELETE FROM users WHERE id = $1")
                    |> parameter(codec.int, 1)
                    |> affected(held)
                    |> result.map_error(list.wrap),
                  )
                  use _found <- result.try(
                    query("SELECT id, email FROM users WHERE id = $1")
                    |> parameter(codec.int, 1)
                    |> affected(held)
                    |> result.map_error(list.wrap),
                  )
                  use Nil <- result.try(
                    run_sql(
                      "ALTER TABLE users ALTER COLUMN email TYPE int4 USING NULL",
                      held,
                    )
                    |> result.map_error(list.wrap),
                  )
                  check_database(held)
                },
              )
              |> be_error()
              |> describe_each_error()
              |> be_equal([
                "failed: user.find: column 2 (email) is int4, and the query reads it with the text codec",
              ])
              |> or_fail_with("Expected the changed type of email")
            }),
          ])
        }),
      ),
      group("PostgreSQL 17", [
        before_all(server_pools.choose_version(17)),
        it("job_events.gleam follows a listener through its name", fn(pools) {
          // Arrange
          let notifications = process.new_name("snippet_notifications")
          let jobs: process.Subject(ListenMessage) = process.new_subject()

          // Act and assert
          pools
          |> should
          |> run_with_supervised_listener(notifications, fn(gate, connection) {
            use _subscription <- result.try(
              listen_by_name(notifications, jobs)
              |> result.map_error(error.describe),
            )
            use events <- result.try(
              job_events(notifications, jobs)
              |> result.map_error(error.describe),
            )
            listener_gate.open_gate(gate)
            use _states <- result.try(listen_messages.receive_messages(
              jobs,
              count: 2,
              within: 5000,
            ))
            use Nil <- result.try(
              run_sql("NOTIFY jobs, 'build-43'", connection)
              |> result.map_error(error.describe),
            )
            let job = next_job(jobs)
            stop_listener(named_listener(notifications))
            case process.selector_receive(events, 5000) {
              Ok(ListenerEnded(..)) -> Ok(#(job, "the listener ended"))
              Ok(JobMessage(..)) | Error(Nil) -> Error("no end of the listener")
            }
          })
          |> be_equal(#(Ok("build-43"), "the listener ended"))
          |> or_fail_with("Expected the job, then the end of the listener")
        }),
      ]),
    ],
  )
}

/// The snippets that need no database.
pub fn unit_tests() -> TestSuite {
  unit.describe("the snippets of the guides with no database", [
    unit.it(
      "answer_with_two_posts.gleam answers post.list with two posts",
      fn() {
        // Act
        let titles =
          list_titles(pool.with_interceptor(
            no_database.connection(),
            answer_with_two_posts,
          ))

        // Assert
        titles
        |> should
        |> be_ok()
        |> be_equal([#(1, "First"), #(2, "Second")])
        |> or_fail_with("Expected the two posts of the interceptor")
      },
    ),
    unit.it("answer_three_updates.gleam answers UPDATE 3", fn() {
      // Act
      let count =
        query("UPDATE users SET active = false")
        |> named("user.deactivate_all")
        |> affected(pool.with_interceptor(
          no_database.connection(),
          answer_three_updates,
        ))

      // Assert
      count
      |> should
      |> be_ok()
      |> be_equal(3)
      |> or_fail_with("Expected 3 rows")
    }),
    unit.group(
      "the simulated failures answer each request",
      list.map(
        [
          #("account.transfer", simulate_deadlock, "retry"),
          #("report.build", simulate_lost_connection, "unavailable"),
          #("report.build", simulate_timeout, "timeout"),
          #("user.delete", refuse_deletes, "failed"),
        ],
        fn(example) {
          let #(name, simulation, kind) = example
          unit.it(name <> " fails as " <> kind, fn() {
            // Act
            let outcome =
              query("SELECT 1")
              |> named(name)
              |> affected(pool.with_interceptor(
                no_database.connection(),
                simulation,
              ))

            // Assert
            outcome
            |> should
            |> be_error()
            |> have_kind_name()
            |> be_equal(kind)
            |> or_fail_with("Expected the kind " <> kind)
          })
        },
      ),
    ),
    unit.it("replay_server_error.gleam replays a server error", fn() {
      // Arrange
      let unique_violation =
        server_error.with_sql_state(sql_state.UniqueViolation, None)

      // Act and assert
      replay_server_error(unique_violation)
      |> should
      |> be_equal(Some(error.Server(unique_violation)))
      |> or_fail_with("Expected the same reason back")
    }),
    unit.it(
      "empty_recording_text.gleam writes the text of an empty recording",
      fn() {
        // Act and assert
        empty_recording_text()
        |> should
        |> be_equal(
          "{\n  \"dream_postgres_recording\": 1,\n  \"entries\": []\n}\n",
        )
        |> or_fail_with("Expected the text of the empty recording")
      },
    ),
    unit.it("begin_recording.json is a recording in the file format", fn() {
      // Arrange
      let path = "test/snippets/begin_recording.json"
      let assert Ok(text) = simplifile.read(path)
      let assert Ok(bytes) = simplifile.read_bits(path)

      // Act
      let written =
        read_recording(bytes)
        |> result.map(recording.to_file_text)

      // Assert
      written
      |> should
      |> be_ok()
      |> be_equal(text)
      |> or_fail_with("Expected the same text back")
    }),
    unit.it("check_database.gleam needs a database", fn() {
      // Act and assert
      check_database(no_database.connection())
      |> should
      |> be_error()
      |> describe_each_error()
      |> contain(
        "failed: the connection has no database to check the queries against",
      )
      |> or_fail_with("Expected NoDatabaseToVerify")
    }),
  ])
}
