-module(driver_proxy_ffi).
-export([start/1, inject/2, close_client/1, reset_client/1, stop_reading/1,
         stop_listening/1, answer_next_request/2,
         watch_client_end/1, client_end/1, stop/1]).

%% A TCP proxy between a connection process and a driver server, for the
%% connection tests: it passes every byte both ways, and on a command it
%% does what a broken network or server does.
%%
%% start(ServerPort) listens on a free port of localhost and gives
%% {ok, {Port, Proxy}}, or {error, Reason} as a text when it cannot
%% listen. The proxy accepts one client, connects to the server, and
%% passes bytes until a command:
%%
%% - inject(Proxy, Bytes): sends Bytes to the client, as if the server sent
%%   them;
%% - close_client(Proxy): closes the client's socket;
%% - reset_client(Proxy): resets the client's socket (linger 0);
%% - stop_reading(Proxy): reads nothing more from the client, so its sends
%%   fill the buffers and block;
%% - stop_listening(Proxy): closes the listening socket, so a new connect to
%%   the proxy is refused, and the session goes on;
%% - answer_next_request(Proxy, Bytes): the next bytes from the client do
%%   not reach the server; the proxy answers them with Bytes and then reads
%%   nothing more from the client.
%%
%% Each command waits until the proxy did it.
%%
%% stop(Proxy) ends the proxy at once. Its sockets close with it, so the
%% server ends the session even when the proxy stopped reading, and saw
%% no close of the client.
%%
%% watch_client_end(Proxy) asks for the last bytes that the client sends
%% before it closes its socket; client_end(Watch) waits for them, so a test
%% can see whether a client ended with a Terminate.

start(ServerPort) ->
    Caller = self(),
    Ready = make_ref(),
    Proxy = spawn(fun() -> listen(Caller, Ready, ServerPort) end),
    receive
        {Ready, {ok, Port}} -> {ok, {Port, Proxy}};
        {Ready, {error, Reason}} -> {error, describe(Reason)}
    end.

inject(Proxy, Bytes) -> command(Proxy, {inject, Bytes}).
close_client(Proxy) -> command(Proxy, close_client).
reset_client(Proxy) -> command(Proxy, reset_client).
stop_reading(Proxy) -> command(Proxy, stop_reading).
stop_listening(Proxy) -> command(Proxy, stop_listening).
answer_next_request(Proxy, Bytes) -> command(Proxy, {answer_next_request, Bytes}).

watch_client_end(Proxy) ->
    Reference = make_ref(),
    Proxy ! {watch, self(), Reference},
    Reference.

client_end(Reference) ->
    receive
        {Reference, LastBytes} -> LastBytes
    end.

stop(Proxy) ->
    exit(Proxy, kill),
    nil.

command(Proxy, Command) ->
    Reference = make_ref(),
    Proxy ! {command, self(), Reference, Command},
    receive
        {Reference, done} -> nil
    end.

listen(Caller, Ready, ServerPort) ->
    Options = [binary, {active, false}, {reuseaddr, true}],
    case gen_tcp:listen(0, Options) of
        {ok, Listen} ->
            listening(Caller, Ready, ServerPort, Listen, inet:port(Listen));
        {error, Reason} ->
            Caller ! {Ready, {error, Reason}}
    end.

listening(Caller, Ready, ServerPort, Listen, {ok, Port}) ->
    Caller ! {Ready, {ok, Port}},
    accept(Listen, ServerPort, none);
listening(Caller, Ready, _ServerPort, Listen, {error, Reason}) ->
    gen_tcp:close(Listen),
    Caller ! {Ready, {error, Reason}}.

%% One client after the other: a client that connects again after a loss
%% gets a new session with the server. A failed accept ends the proxy
%% (also after stop_listening). A client whose server connection fails is closed, so it sees a lost
%% connection.
accept(Listen, ServerPort, Watch) ->
    case gen_tcp:accept(Listen) of
        {ok, Client} -> connect_server(Listen, ServerPort, Watch, Client);
        {error, _Reason} -> gen_tcp:close(Listen)
    end.

%% stop_listening closes the listening socket by its name in the process
%% dictionary; the next accept then fails, and the proxy ends.
connect_server(Listen, ServerPort, Watch, Client) ->
    case gen_tcp:connect("localhost", ServerPort, [binary, {active, once}]) of
        {ok, Server} ->
            put(listen_socket, Listen),
            NextWatch = read_client(Client, Server, <<>>, Watch),
            accept(Listen, ServerPort, NextWatch);
        {error, _Reason} ->
            gen_tcp:close(Client),
            accept(Listen, ServerPort, Watch)
    end.

loop(Client, Server, Last, Watch) ->
    receive
        {tcp, Client, Bytes} ->
            client_bytes(get(answer_next_request), Client, Server, Bytes, Watch);
        {tcp, Server, Bytes} ->
            gen_tcp:send(Client, Bytes),
            case inet:setopts(Server, [{active, once}]) of
                ok -> loop(Client, Server, Last, Watch);
                {error, _Reason} -> server_closed(Client, Watch)
            end;
        {command, From, Reference, Command} ->
            Next = run(Command, Client),
            From ! {Reference, done},
            after_command(Next, Client, Server, Last, Watch);
        {watch, From, Reference} ->
            loop(Client, Server, Last, {From, Reference});
        {tcp_closed, Client} ->
            client_closed(Server, Last, Watch);
        {tcp_closed, Server} ->
            server_closed(Client, Watch)
    end.

%% Passes the client's bytes to the server, or, after
%% answer_next_request, answers them and reads nothing more from the
%% client. A failed send ends the session as a close of the other side
%% does.
client_bytes(undefined, Client, Server, Bytes, Watch) ->
    case gen_tcp:send(Server, Bytes) of
        ok -> read_client(Client, Server, Bytes, Watch);
        {error, _Reason} -> server_closed(Client, Watch)
    end;
client_bytes(Answer, Client, Server, Bytes, Watch) ->
    erase(answer_next_request),
    case gen_tcp:send(Client, Answer) of
        ok ->
            inet:setopts(Client, [{recbuf, 1024}]),
            loop(Client, Server, Bytes, Watch);
        {error, _Reason} ->
            client_closed(Server, Bytes, Watch)
    end.

%% Asks for the next bytes of the client. A client socket that is closed
%% already ends the session as a close of the client does.
read_client(Client, Server, Last, Watch) ->
    case inet:setopts(Client, [{active, once}]) of
        ok -> loop(Client, Server, Last, Watch);
        {error, _Reason} -> client_closed(Server, Last, Watch)
    end.

client_closed(Server, Last, Watch) ->
    report_end(Watch, Last),
    gen_tcp:close(Server),
    none.

server_closed(Client, Watch) ->
    gen_tcp:close(Client),
    Watch.

describe(Reason) ->
    unicode:characters_to_binary(io_lib:format("~p", [Reason])).

%% After a close or a reset the session is over, and the proxy waits for
%% the next client.
after_command(continue, Client, Server, Last, Watch) ->
    loop(Client, Server, Last, Watch);
after_command(ended, _Client, Server, _Last, Watch) ->
    gen_tcp:close(Server),
    Watch.

report_end({From, Reference}, Last) -> From ! {Reference, Last};
report_end(none, _Last) -> ok.

run({inject, Bytes}, Client) ->
    gen_tcp:send(Client, Bytes),
    continue;
run(close_client, Client) ->
    gen_tcp:close(Client),
    ended;
run(reset_client, Client) ->
    inet:setopts(Client, [{linger, {true, 0}}]),
    gen_tcp:close(Client),
    ended;
run({answer_next_request, Bytes}, _Client) ->
    put(answer_next_request, Bytes),
    continue;
run(stop_listening, _Client) ->
    gen_tcp:close(get(listen_socket)),
    continue;
run(stop_reading, Client) ->
    inet:setopts(Client, [{active, false}, {recbuf, 1024}]),
    continue.
