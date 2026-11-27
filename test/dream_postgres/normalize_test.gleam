//// The normalizers of a recorder, on requests and answers with cells
//// that are written already, with no database.

import dream_postgres/error.{InterceptorFailed}
import dream_postgres/interceptor.{CopyFromAnswer}
import dream_postgres/internal/cell.{Binary, Null, Text}
import dream_postgres/recorder/normalize
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import fixtures/normalize_inputs.{
  first_placeholder, placeholder_bytes, rows_of, uuid_bytes, uuid_text,
}
import matchers/extract_answer_rows.{extract_answer_rows}

/// The normalizer tests, with no database.
pub fn tests() -> TestSuite {
  describe("normalize", [
    it("generated_uuids gives a uuid cell the first placeholder", fn() {
      // Act and assert
      normalize.generated_uuids(keep: [])(
        normalize_inputs.statement("SELECT 1", []),
        normalize_inputs.answering(rows_of("uuid", [[Binary(uuid_bytes())]])),
      )
      |> should
      |> extract_answer_rows()
      |> be_equal([[Binary(placeholder_bytes(1))]])
      |> or_fail_with("Expected the bytes of the first placeholder")
    }),
    it("generated_uuids gives the same UUID the same placeholder", fn() {
      // Act and assert
      normalize.generated_uuids(keep: [])(
        normalize_inputs.statement("SELECT 1", []),
        normalize_inputs.answering(
          rows_of("uuid", [[Binary(uuid_bytes())], [Binary(uuid_bytes())]]),
        ),
      )
      |> should
      |> extract_answer_rows()
      |> be_equal([
        [Binary(placeholder_bytes(1))],
        [Binary(placeholder_bytes(1))],
      ])
      |> or_fail_with("Expected one placeholder for both rows")
    }),
    it("generated_uuids numbers UUIDs in the order it sees them", fn() {
      // Act and assert
      normalize.generated_uuids(keep: [])(
        normalize_inputs.statement("SELECT 1", []),
        normalize_inputs.answering(
          rows_of("uuid", [[Binary(uuid_bytes())], [Binary(<<7:128>>)]]),
        ),
      )
      |> should
      |> extract_answer_rows()
      |> be_equal([
        [Binary(placeholder_bytes(1))],
        [Binary(placeholder_bytes(2))],
      ])
      |> or_fail_with("Expected the placeholders 1 and 2")
    }),
    it("generated_uuids leaves a UUID of keep as it is", fn() {
      // Act and assert
      normalize.generated_uuids(keep: ["0B8F5C2E-6A1D-4F3B-9C7E-2D4A6B8C0E1F"])(
        normalize_inputs.statement("SELECT 1", []),
        normalize_inputs.answering(rows_of("uuid", [[Binary(uuid_bytes())]])),
      )
      |> should
      |> extract_answer_rows()
      |> be_equal([[Binary(uuid_bytes())]])
      |> or_fail_with("Expected the kept UUID")
    }),
    it("generated_uuids leaves a UUID of keep as it is in text", fn() {
      // Act and assert
      normalize.generated_uuids(keep: [uuid_text])(
        normalize_inputs.statement("SELECT 1", []),
        normalize_inputs.answering(
          rows_of("text", [[Binary(<<uuid_text:utf8>>)]]),
        ),
      )
      |> should
      |> extract_answer_rows()
      |> be_equal([[Binary(<<uuid_text:utf8>>)]])
      |> or_fail_with("Expected the kept UUID in the text")
    }),
    it("generated_uuids replaces a UUID in the text of a text cell", fn() {
      // Act and assert
      normalize.generated_uuids(keep: [])(
        normalize_inputs.statement("SELECT 1", []),
        normalize_inputs.answering(
          rows_of("text", [[Binary(<<"key ":utf8, uuid_text:utf8>>)]]),
        ),
      )
      |> should
      |> extract_answer_rows()
      |> be_equal([[Binary(<<"key ":utf8, first_placeholder:utf8>>)]])
      |> or_fail_with("Expected the placeholder in the text")
    }),
    it("generated_uuids replaces a UUID in a jsonb cell", fn() {
      // Act and assert
      normalize.generated_uuids(keep: [])(
        normalize_inputs.statement("SELECT 1", []),
        normalize_inputs.answering(
          rows_of("jsonb", [
            [Binary(<<1, "{\"id\":\"":utf8, uuid_text:utf8, "\"}":utf8>>)],
          ]),
        ),
      )
      |> should
      |> extract_answer_rows()
      |> be_equal([
        [Binary(<<1, "{\"id\":\"":utf8, first_placeholder:utf8, "\"}":utf8>>)],
      ])
      |> or_fail_with("Expected the placeholder in the JSON")
    }),
    it("generated_uuids replaces a UUID in a cell of a script", fn() {
      // Act and assert
      normalize.generated_uuids(keep: [])(
        normalize_inputs.statement("SELECT 1", []),
        normalize_inputs.answering(
          normalize_inputs.script_rows([[Text(<<uuid_text:utf8>>)]]),
        ),
      )
      |> should
      |> extract_answer_rows()
      |> be_equal([[Text(<<first_placeholder:utf8>>)]])
      |> or_fail_with("Expected the placeholder in the text cell")
    }),
    it("generated_uuids replaces a UUID in a recorded COPY TO row", fn() {
      // Act and assert
      normalize.generated_uuids(keep: [])(
        normalize_inputs.statement("SELECT 1", []),
        normalize_inputs.answering(
          normalize_inputs.copied_rows_of("uuid", [[Binary(uuid_bytes())]]),
        ),
      )
      |> should
      |> extract_answer_rows()
      |> be_equal([[Binary(placeholder_bytes(1))]])
      |> or_fail_with("Expected the placeholder in the COPY row")
    }),
    it("generated_uuids replaces a UUID in the SQL", fn() {
      // Act and assert
      normalize.generated_uuids(keep: [])(
        normalize_inputs.statement("SELECT '" <> uuid_text <> "'::uuid", []),
        normalize_inputs.refusing_with_key,
      )
      |> should
      |> be_equal(
        Error(InterceptorFailed(
          "statement\nSELECT '" <> first_placeholder <> "'::uuid",
        )),
      )
      |> or_fail_with("Expected the placeholder in the SQL")
    }),
    it("generated_uuids replaces a UUID in a written parameter", fn() {
      // Act and assert
      normalize.generated_uuids(keep: [])(
        normalize_inputs.statement("SELECT $1", [
          normalize_inputs.written("uuid", Binary(uuid_bytes())),
        ]),
        normalize_inputs.refusing_with_key,
      )
      |> should
      |> be_equal(
        Error(InterceptorFailed(
          "statement\nSELECT $1\n$1 uuid binary DEADBEEFDEAD4EEF8EADBEEF00000001",
        )),
      )
      |> or_fail_with("Expected the placeholder in the parameter")
    }),
    it("generated_uuids replaces a UUID in a written COPY FROM row", fn() {
      // Act and assert
      normalize.generated_uuids(keep: [])(
        normalize_inputs.copy_from([
          [normalize_inputs.written("uuid", Binary(uuid_bytes()))],
        ]),
        normalize_inputs.refusing_with_key,
      )
      |> should
      |> be_equal(
        Error(InterceptorFailed(
          "copy_from\nCOPY items FROM STDIN\nrow 1 uuid binary DEADBEEFDEAD4EEF8EADBEEF00000001",
        )),
      )
      |> or_fail_with("Expected the placeholder in the row")
    }),
    it(
      "generated_uuids leaves a secret parameter and one not written as they are",
      fn() {
        // Act and assert
        normalize.generated_uuids(keep: [])(
          normalize_inputs.statement("SELECT $1, $2", [
            normalize_inputs.not_written(),
            ..normalize_inputs.written_secret()
          ]),
          normalize_inputs.refusing_with_key,
        )
        |> should
        |> be_equal(
          Error(InterceptorFailed(
            "statement\nSELECT $1, $2\n$1 not written int\n$2 secret text",
          )),
        )
        |> or_fail_with("Expected both parameters as they were")
      },
    ),
    it(
      "generated_uuids keeps the number of a placeholder, and numbers the next UUID after it",
      fn() {
        // Act and assert
        normalize.generated_uuids(keep: [])(
          normalize_inputs.statement("SELECT 1", []),
          normalize_inputs.answering(
            rows_of("uuid", [
              [Binary(placeholder_bytes(5))],
              [Binary(uuid_bytes())],
            ]),
          ),
        )
        |> should
        |> extract_answer_rows()
        |> be_equal([
          [Binary(placeholder_bytes(5))],
          [Binary(placeholder_bytes(6))],
        ])
        |> or_fail_with("Expected the placeholders 5 and 6")
      },
    ),
    it(
      "generated_uuids gives a new placeholder to a UUID like a placeholder with no number",
      fn() {
        // Act and assert
        normalize.generated_uuids(keep: [])(
          normalize_inputs.statement("SELECT 1", []),
          normalize_inputs.answering(
            rows_of("text", [
              [Binary(<<"deadbeef-dead-4eef-8ead-beefabcdef12":utf8>>)],
            ]),
          ),
        )
        |> should
        |> extract_answer_rows()
        |> be_equal([[Binary(<<first_placeholder:utf8>>)]])
        |> or_fail_with("Expected the first placeholder")
      },
    ),
    it("generated_uuids leaves a cell of another type as it is", fn() {
      // Act and assert
      normalize.generated_uuids(keep: [])(
        normalize_inputs.statement("SELECT 1", []),
        normalize_inputs.answering(rows_of("bytea", [[Binary(uuid_bytes())]])),
      )
      |> should
      |> extract_answer_rows()
      |> be_equal([[Binary(uuid_bytes())]])
      |> or_fail_with("Expected the bytea cell as it was")
    }),
    it("generated_uuids leaves a NULL as it is", fn() {
      // Act and assert
      normalize.generated_uuids(keep: [])(
        normalize_inputs.statement("SELECT 1", []),
        normalize_inputs.answering(rows_of("uuid", [[Null]])),
      )
      |> should
      |> extract_answer_rows()
      |> be_equal([[Null]])
      |> or_fail_with("Expected the NULL")
    }),
    it("generated_uuids leaves bytes that are not UTF-8 as they are", fn() {
      // Act and assert
      normalize.generated_uuids(keep: [])(
        normalize_inputs.statement("SELECT 1", []),
        normalize_inputs.answering(rows_of("text", [[Binary(<<255, 254>>)]])),
      )
      |> should
      |> extract_answer_rows()
      |> be_equal([[Binary(<<255, 254>>)]])
      |> or_fail_with("Expected the bytes as they were")
    }),
    it("generated_uuids passes the count of a COPY FROM on", fn() {
      // Act and assert
      normalize.generated_uuids(keep: [])(
        normalize_inputs.copy_from([]),
        normalize_inputs.answering(Ok(CopyFromAnswer(count: 3))),
      )
      |> should
      |> be_equal(Ok(CopyFromAnswer(count: 3)))
      |> or_fail_with("Expected the count")
    }),
    it("timestamps_near_now replaces a timestamptz of now", fn() {
      // Act and assert
      normalize.timestamps_near_now(window_days: 1)(
        normalize_inputs.statement("SELECT now()", []),
        normalize_inputs.answering(
          rows_of("timestamptz", [[normalize_inputs.now_cell()]]),
        ),
      )
      |> should
      |> extract_answer_rows()
      |> be_equal([[normalize_inputs.fixed_timestamp_cell()]])
      |> or_fail_with("Expected the fixed timestamp")
    }),
    it("timestamps_near_now replaces a timestamp of now", fn() {
      // Act and assert
      normalize.timestamps_near_now(window_days: 1)(
        normalize_inputs.statement("SELECT now()", []),
        normalize_inputs.answering(
          rows_of("timestamp", [[normalize_inputs.now_cell()]]),
        ),
      )
      |> should
      |> extract_answer_rows()
      |> be_equal([[normalize_inputs.fixed_timestamp_cell()]])
      |> or_fail_with("Expected the fixed timestamp")
    }),
    it("timestamps_near_now leaves a timestamp outside the window", fn() {
      // Act and assert
      normalize.timestamps_near_now(window_days: 400)(
        normalize_inputs.statement("SELECT 1", []),
        normalize_inputs.answering(rows_of("timestamptz", [[Binary(<<0:64>>)]])),
      )
      |> should
      |> extract_answer_rows()
      |> be_equal([[Binary(<<0:64>>)]])
      |> or_fail_with("Expected 2000-01-01 as it was")
    }),
    it("timestamps_near_now leaves a cell of another type", fn() {
      // Act and assert
      normalize.timestamps_near_now(window_days: 1)(
        normalize_inputs.statement("SELECT 1", []),
        normalize_inputs.answering(rows_of("int8", [[Binary(<<5:64>>)]])),
      )
      |> should
      |> extract_answer_rows()
      |> be_equal([[Binary(<<5:64>>)]])
      |> or_fail_with("Expected the int8 cell as it was")
    }),
  ])
}
