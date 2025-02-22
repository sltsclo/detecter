%% Copyright (c) 2011-2018, Loïc Hoguin <essen@ninenines.eu>
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

-module(ranch_acceptor).
-include("log.hrl").

-export([start_link/5]).
-export([loop/5]).

-spec start_link(inet:socket(), module(), module(), pid(), integer())
	-> {ok, pid()}.
start_link(LSocket, Transport, Logger, ConnsSup, _AccId) ->
	Pid = spawn_link(?MODULE, loop, [LSocket, Transport, Logger, ConnsSup, _AccId]),
	?TRACE("Started acceptor #~w (~p).", [_AccId, Pid]),
	{ok, Pid}.

-spec loop(inet:socket(), module(), module(), pid(), integer()) -> no_return().
loop(LSocket, Transport, Logger, ConnsSup, _AccId) ->
	{ok, _Port} = inet:port(LSocket),
	?TRACE("Acceptor #~w waiting on port ~w (~w).", [_AccId, _Port, LSocket]),
	_ = case Transport:accept(LSocket, infinity) of
		{ok, CSocket} ->
			case Transport:controlling_process(CSocket, ConnsSup) of
				ok ->
					%% This call will not return until process has been started
					%% AND we are below the maximum number of connections.
					ranch_conns_sup:start_protocol(ConnsSup, CSocket);
				{error, _} ->
					?ERROR("Acceptor #~w failed to trasfer control of port ~w (~w) to ~w.", [_AccId, _Port, LSocket, ConnsSup]),
					Transport:close(CSocket)
			end;
		%% Reduce the accept rate if we run out of file descriptors.
		%% We can't accept anymore anyway, so we might as well wait
		%% a little for the situation to resolve itself.
		{error, emfile} ->
			ranch:log(warning,
				"Ranch acceptor reducing accept rate: out of file descriptors~n",
				[], Logger),
			receive after 100 -> ok end;
		%% Exit if the listening socket got closed.
		{error, closed} ->
			exit(closed);
		%% Continue otherwise.
		{error, _} ->
			ok
	end,
	flush(Logger),
	?MODULE:loop(LSocket, Transport, Logger, ConnsSup, _AccId).

flush(Logger) ->
	receive Msg ->
		?WARN("Ranch acceptor received unexpected message: ~p.", [Msg]),
		ranch:log(warning,
			"Ranch acceptor received unexpected message: ~p~n",
			[Msg], Logger),
		flush(Logger)
	after 0 ->
		ok
	end.
