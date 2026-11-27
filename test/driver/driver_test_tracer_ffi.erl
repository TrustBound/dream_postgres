-module(driver_test_tracer_ffi).
-export([install/0, record_spans_here/0, record_every_process_here/0,
         stop_recording_every_process/0, next_span/0, spans_now/0,
         start_span/4, with_span/5,
         set_attribute/3, set_attributes/2, add_event/3, add_events/2,
         set_status/2, update_name/2, end_span/1, end_span/2]).

-include_lib("opentelemetry_api/include/opentelemetry.hrl").

%% A tracer for the tests, through the OpenTelemetry API with no SDK. It
%% records the spans of a process only after that process calls
%% record_spans_here/0, and sends each step of a span to that process
%% itself, so tests that run at the same time never see each other's
%% spans. Every other process gets the API's no-op span.

%% Makes this tracer the default tracer of the API. It stays for the rest
%% of the run; a process that does not record gets no-op spans.
install() ->
    opentelemetry:set_default_tracer({?MODULE, []}),
    nil.

record_spans_here() ->
    put(?MODULE, recording),
    nil.

%% Records the spans of every process, sent to the calling process, until
%% stop_recording_every_process/0. For a test of the processes of the
%% driver itself, which run in no test's process.
record_every_process_here() ->
    persistent_term:put({?MODULE, sink}, self()),
    nil.

stop_recording_every_process() ->
    persistent_term:erase({?MODULE, sink}),
    nil.

%% Every span that waits in the mailbox of the calling process now, ended
%% or not, in the order they started. It never waits.
spans_now() ->
    spans_now([]).

spans_now(Spans) ->
    receive
        {?MODULE, Id, {started, Name, Kind, Attributes}} ->
            spans_now([pending_span(Id, Name, Kind, Attributes) | Spans])
    after 0 ->
        lists:reverse(Spans)
    end.

pending_span(Id, Name, Kind, Attributes) ->
    finish_now(Id, Name, Kind, Attributes, false).

finish_now(Id, Name, Kind, Attributes, Failed) ->
    receive
        {?MODULE, Id, {attributes, More}} ->
            finish_now(Id, Name, Kind, maps:merge(Attributes, More), Failed);
        {?MODULE, Id, {status, Code}} ->
            finish_now(Id, Name, Kind, Attributes, Code =:= ?OTEL_STATUS_ERROR);
        {?MODULE, Id, ended} ->
            {recorded_span, Name, atom_to_binary(Kind), texts(Attributes), Failed}
    after 0 ->
        {recorded_span, Name, atom_to_binary(Kind), texts(Attributes), Failed}
    end.

%% The next span that the calling process ended:
%% {recorded_span, Name, Kind, Attributes, Failed}, with each attribute as
%% {Key, Text}, sorted by key, and Failed true for the status Error.
next_span() ->
    receive
        {?MODULE, Id, {started, Name, Kind, Attributes}} ->
            finish(Id, Name, Kind, Attributes, false)
    after 5000 ->
        {error, <<"no span within 5 seconds">>}
    end.

finish(Id, Name, Kind, Attributes, Failed) ->
    receive
        {?MODULE, Id, {attributes, More}} ->
            finish(Id, Name, Kind, maps:merge(Attributes, More), Failed);
        {?MODULE, Id, {status, Code}} ->
            finish(Id, Name, Kind, Attributes, Code =:= ?OTEL_STATUS_ERROR);
        {?MODULE, Id, ended} ->
            {ok, {recorded_span, Name, atom_to_binary(Kind), texts(Attributes), Failed}}
    after 5000 ->
        {error, <<"the span did not end within 5 seconds">>}
    end.

texts(Attributes) ->
    lists:sort([{Key, text(Value)} || {Key, Value} <- maps:to_list(Attributes)]).

text(Value) when is_binary(Value) -> Value;
text(Value) when is_integer(Value) -> integer_to_binary(Value);
text(Value) -> unicode:characters_to_binary(io_lib:format("~0p", [Value])).

%% The otel_tracer callbacks.
start_span(Ctx, _Tracer, Name, Opts) ->
    start(destination(), Ctx, Name, Opts).

%% The process that gets the steps of a span of this process: itself when
%% it records, else the process that records every process, if any.
destination() ->
    case get(?MODULE) of
        recording -> self();
        _ -> persistent_term:get({?MODULE, sink}, none)
    end.

start(none, Ctx, Name, Opts) ->
    otel_tracer_noop:start_span(Ctx, {otel_tracer_noop, []}, Name, Opts);
start(Destination, _Ctx, Name, #{kind := Kind, attributes := Attributes}) ->
    Id = erlang:unique_integer([positive]),
    Destination ! {?MODULE, Id, {started, Name, Kind, Attributes}},
    #span_ctx{trace_id = 1, span_id = Id, trace_flags = 1, is_valid = true,
              is_recording = true, span_sdk = {?MODULE, {Id, Destination}}}.

with_span(Ctx, Tracer, Name, Opts, Fun) ->
    Fun(start_span(Ctx, Tracer, Name, Opts)).

%% The span callbacks (span_sdk).
set_attribute(#span_ctx{span_sdk = {?MODULE, {Id, Destination}}}, Key, Value) ->
    Destination ! {?MODULE, Id, {attributes, #{Key => Value}}},
    true.

set_attributes(#span_ctx{span_sdk = {?MODULE, {Id, Destination}}}, Attributes) ->
    Destination ! {?MODULE, Id, {attributes, Attributes}},
    true.

add_event(_SpanCtx, _Name, _Attributes) -> true.

add_events(_SpanCtx, _Events) -> true.

set_status(#span_ctx{span_sdk = {?MODULE, {Id, Destination}}}, #status{code = Code}) ->
    Destination ! {?MODULE, Id, {status, Code}},
    true.

update_name(_SpanCtx, _Name) -> true.

end_span(#span_ctx{span_sdk = {?MODULE, {Id, Destination}}} = SpanCtx) ->
    Destination ! {?MODULE, Id, ended},
    SpanCtx#span_ctx{is_recording = false}.

end_span(SpanCtx, _Timestamp) ->
    end_span(SpanCtx).
