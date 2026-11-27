-module(driver_socket_ffi).
-export([ssl_answer/2, first_message/2]).

%% Test helpers that talk to a PostgreSQL server over plain TCP, before the
%% driver has any code of its own. Each call opens a connection to
%% localhost, sends the request bytes, reads the answer and closes the
%% connection.

-define(TIMEOUT, 5000).

%% Sends Request and returns the one byte that answers it: the answer to an
%% SSLRequest or a GSSENCRequest.
ssl_answer(Port, Request) ->
    with_connection(Port, Request, fun(Socket) ->
        gen_tcp:recv(Socket, 1, ?TIMEOUT)
    end).

%% Sends Request and returns the first whole message of the answer: its
%% type byte, its length and its body.
first_message(Port, Request) ->
    with_connection(Port, Request, fun read_message/1).

read_message(Socket) ->
    case gen_tcp:recv(Socket, 5, ?TIMEOUT) of
        {ok, <<_Type, Length:32/signed-big>> = Header} ->
            case gen_tcp:recv(Socket, Length - 4, ?TIMEOUT) of
                {ok, Body} -> {ok, <<Header/binary, Body/binary>>};
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

with_connection(Port, Request, Read) ->
    Options = [binary, {active, false}, {packet, raw}],
    case gen_tcp:connect("localhost", Port, Options, ?TIMEOUT) of
        {ok, Socket} ->
            Answer =
                case gen_tcp:send(Socket, Request) of
                    ok -> Read(Socket);
                    {error, Reason} -> {error, Reason}
                end,
            gen_tcp:close(Socket),
            describe_error(Answer);
        {error, Reason} ->
            describe_error({error, Reason})
    end.

describe_error({ok, Bytes}) -> {ok, Bytes};
describe_error({error, Reason}) ->
    {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}.
