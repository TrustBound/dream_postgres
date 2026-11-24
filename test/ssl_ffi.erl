-module(ssl_ffi).
-export([capture_tls_alerts/1,
         drop_tls_alert_reports/0, drop_tls_alert_report/2, log/2]).

%% Calls Fun and returns {Value, Alerts}: the value of Fun, and each TLS
%% alert report that OTP's ssl application logged while Fun ran, as
%% {Level, Text} with the text on one line.
capture_tls_alerts(Fun) ->
    Id = list_to_atom("tls_alerts_" ++
                      integer_to_list(erlang:unique_integer([positive]))),
    ok = logger:add_handler(Id, ?MODULE, #{config => #{pid => self()}}),
    Value = try
        Fun()
    after
        logger:remove_handler(Id)
    end,
    {Value, collect_alerts()}.

collect_alerts() ->
    receive
        {tls_alert_report, Alert} -> [Alert | collect_alerts()]
    after 0 ->
        []
    end.

%% The logger handler of capture_tls_alerts/1.
log(Event = #{level := Level}, #{config := #{pid := Pid}}) ->
    case is_tls_alert_report(Event) of
        true ->
            Text = logger_formatter:format(
                Event, #{single_line => true, template => [msg]}),
            Pid ! {tls_alert_report,
                   {atom_to_binary(Level), unicode:characters_to_binary(Text)}};
        false ->
            ok
    end.

%% Drops the TLS alert reports from the output of the test run. A pool
%% whose certificate check fails logs one report for each try of each
%% connection. Every other log event is kept, and capture_tls_alerts/1
%% still gets these reports.
drop_tls_alert_reports() ->
    lists:foreach(
        fun(Handler) ->
            _ = logger:remove_handler_filter(Handler, drop_tls_alert_reports),
            ok = logger:add_handler_filter(
                Handler,
                drop_tls_alert_reports,
                {fun ?MODULE:drop_tls_alert_report/2, nil}
            )
        end,
        logger:get_handler_ids()
    ),
    nil.

drop_tls_alert_report(Event, _Extra) ->
    case is_tls_alert_report(Event) of
        true -> stop;
        false -> ignore
    end.

is_tls_alert_report(#{msg := {report, #{alert := _, alerter := _}}}) -> true;
is_tls_alert_report(_Event) -> false.
