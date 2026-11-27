-module(dream_postgres_trace_ffi).
-export([start_client_span/3, end_span/3]).

-include_lib("opentelemetry_api/include/opentelemetry.hrl").

%% The OpenTelemetry calls of dream_postgres/driver/trace. With no SDK
%% running, the API's tracer is a no-op, so these calls cost close to
%% nothing.

%% Starts a span of kind CLIENT in the caller's process, with the caller's
%% current span as its parent. OTel semantic conventions, database spans:
%% "**Span kind** SHOULD be `CLIENT`." (docs/db/postgresql.md line 31).
start_client_span(Name, StringAttributes, IntAttributes) ->
    Tracer = opentelemetry:get_application_tracer(?MODULE),
    Attributes = maps:from_list(StringAttributes ++ IntAttributes),
    otel_tracer:start_span(Tracer, Name, #{kind => ?SPAN_KIND_CLIENT,
                                           attributes => Attributes}).

%% Sets the attributes known at the end, sets the status Error when the
%% operation failed, and ends the span. The status description stays
%% empty: a server message can hold a value of the statement.
end_span(Span, StringAttributes, Failed) ->
    otel_span:set_attributes(Span, maps:from_list(StringAttributes)),
    set_failed(Span, Failed),
    otel_span:end_span(Span),
    nil.

set_failed(Span, true) -> otel_span:set_status(Span, ?OTEL_STATUS_ERROR, <<>>);
set_failed(_Span, false) -> false.
