%%% ----------------------------------------------------------------------------
%%% @author Duncan Paul Attard
%%%
%%% @doc Module description (becomes module heading).
%%%
%%% @end
%%% 
%%% Copyright (c) 2021, Duncan Paul Attard <duncanatt@gmail.com>
%%%
%%% This program is free software: you can redistribute it and/or modify it 
%%% under the terms of the GNU General Public License as published by the Free 
%%% Software Foundation, either version 3 of the License, or (at your option) 
%%% any later version.
%%%
%%% This program is distributed in the hope that it will be useful, but WITHOUT 
%%% ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or 
%%% FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
%%% more details.
%%%
%%% You should have received a copy of the GNU General Public License along with 
%%% this program. If not, see <https://www.gnu.org/licenses/>.
%%% ----------------------------------------------------------------------------
-module(tracer).
-author("Duncan Paul Attard").

%%% Includes.
-include_lib("stdlib/include/assert.hrl").
-include("log.hrl").
-include("dev.hrl").

%%% Public API.
-export([start/4, stop/0]).

-ifdef(TEST).
-export([get_mon_info/0, get_mon_info/1, set_trc_info/2]).
-export([get_mon_info_rev/0, get_mon_info_rev/1]).
-export([get_proc_mon/1]).
-endif.


%%% Internal callbacks.
-export([root/5, tracer/6]).

-export([new_mon_stats/0, new_mon_stats/6]).
-export([show_stats/2, cum_sum_stats/2]).

%%% Types.
-export_type([]).

%%% Implemented behaviors.
%-behavior().


%%% ----------------------------------------------------------------------------
%%% Macro and record definitions.
%%% ----------------------------------------------------------------------------

%% Two modes a tracer can exist in. In direct mode, the tracer receives events
%% directly from the process(es) it tracers; in priority mode, the tracer
%% may still be receiving events directly from the process(es) it traces, but
%% must nevertheless first analyze those events forwarded to it by other tracers
%% (a.k.a. priority events) before it can then analyse the trace events it
%% receives directly from the processes it traces.
-define(MODE_DIRECT, direct).
-define(MODE_PRIORITY, priority).

-define(ANALYSIS_INTERNAL, internal).
-define(ANALYSIS_EXTERNAL, external).


%% TODO: What are these? Probably tables used to keep counts used in the ETS table? We'll see
%% TODO: I think they are used in testing to keep the association between tracers and processes.
-ifdef(TEST).
-define(MON_INFO_ETS_NAME, mon_state).
-define(MON_INFO_INV_ETS_NAME, mon_inv_state).
-endif.

%% Maintains the count of the events seen by the tracer.
-record(event_stats, {
  cnt_spawn = 0 :: non_neg_integer(),
  cnt_exit = 0 :: non_neg_integer(),
  cnt_send = 0 :: non_neg_integer(),
  cnt_receive = 0 :: non_neg_integer(),
  cnt_spawned = 0 :: non_neg_integer(),
  cnt_other = 0 :: non_neg_integer()
}).

%% Internal tracer state consisting of:
%%
%% {@dl
%%   {@item `routes'}
%%   {@desc Routing map that determines the next hop from tracer to tracer.}
%%   {@item `traced'}
%%   {@desc Processes that are traced by the tracer with their traced mode.}
%%   {@item `mfa_spec'}
%%   {@desc Function that determines whether an analyzer is associated with a
%%          MFA whose process instantiation needs to be monitored.}
%%   {@item `trace'}
%%   {@desc List of trace events seen by the tracer.}
%%   {@item `stats'}
%%   {@desc Counts of the events seen by the tracer.}
%% }
-record(tracer_state, {
  routes = #{} :: routes(),
  traced = #{} :: traced(),
  mfa_spec = fun({_, _, _}) -> undefined end :: analyzer:mfa_spec(),
  analysis = ?ANALYSIS_EXTERNAL,
%%  analysis = internal,
  trace = [] :: list(),
  stats = #event_stats{} :: event_stats()
}).


%%% ----------------------------------------------------------------------------
%%% Type definitions.
%%% ----------------------------------------------------------------------------

-type mode() :: ?MODE_PRIORITY | ?MODE_DIRECT.

-type routes() :: #{pid() => pid()}.

-type traced() :: #{pid() => mode()}.

-type parent() :: pid() | self.

-type analyzer() :: undefined | pid() | self.

-type event_stats() :: #event_stats{}.

-type state() :: #tracer_state{}.

-type detach() :: {detach, PidRtr :: pid(), PidS :: pid()}.

-type routed(Msg) :: {route, PidRtr :: pid(), Msg}.

-type analysis() :: ?ANALYSIS_INTERNAL | ?ANALYSIS_EXTERNAL.


%%% ----------------------------------------------------------------------------
%%% Data API.
%%% ----------------------------------------------------------------------------
% Testing = for me, Debugging = For users of the tool.

-spec new_mon_stats() -> Stats :: event_stats().
new_mon_stats() ->
  #event_stats{}.

-spec new_mon_stats(CntSpawn, CntExit, CntSend, CntReceive, CntSpawned, CntOther) ->
  Stats :: event_stats()
  when
  CntSpawn :: non_neg_integer(),
  CntExit :: non_neg_integer(),
  CntSend :: non_neg_integer(),
  CntReceive :: non_neg_integer(),
  CntSpawned :: non_neg_integer(),
  CntOther :: non_neg_integer().
new_mon_stats(CntSpawn, CntExit, CntSend, CntReceive, CntSpawned, CntOther) ->
  #event_stats{
    cnt_spawn = CntSpawn, cnt_exit = CntExit, cnt_send = CntSend,
    cnt_receive = CntReceive, cnt_spawned = CntSpawned, cnt_other = CntOther
  }.


%%% ----------------------------------------------------------------------------
%%% Public API.
%%% ----------------------------------------------------------------------------

% TODO: We need to add another parameter that specifies whether the analysis
% TODO: is done locally in the tracer or separately in another analyzer process.
%%-spec start(PidS, MfaSpec, Analysis, Parent) -> pid()
%%  when
%%  PidS :: pid(),
%%  MfaSpec :: analyzer:mfa_spec(),
%%  Parent :: parent().
start(PidS, MfaSpec, Analysis, Parent)
  when is_pid(PidS), is_function(MfaSpec, 1),
  is_pid(Parent); Parent =:= self ->

  ?exec_if_test(io:format("TESTING~n"), io:format("NOT TESTING~n")),
  ?exec_if_test(
    % Create and initialize tracer-process mapping ETS tables.
    init_mon_info_tbls(), ok
  ),

  Starter = self(),
  spawn(?MODULE, root, [PidS, MfaSpec, Analysis, Starter, Parent]).


-spec stop() -> ok.
stop() ->
  ?exec_if_test(
    begin
      ets:delete(?MON_INFO_ETS_NAME),
      ets:delete(?MON_INFO_INV_ETS_NAME)
    end, ok),
  ok.


%%% ----------------------------------------------------------------------------
%%% Internal callbacks.
%%% ----------------------------------------------------------------------------

%% @doc Initializes the root tracer and starts tracing the top-level system
%% process.
%%
%% {@params
%%   {@name }
%%   {@desc }
%% }
%%
%% {@returns Does not return.}
%%-spec root(PidS, MfaSpec, Analysis, Starter, Parent) -> no_return()
%%  when
%%  PidS :: pid(),
%%  MfaSpec :: analyzer:mfa_spec(),
%%  Starter :: pid(),
%%  Parent :: parent().
root(PidS, MfaSpec, Analysis, Starter, Parent) ->

  ?INFO("Started ROOT tracer ~w for process ~w.", [self(), PidS]),

  % Start tracing top-level system process. Trace events from the top-level
  % process and its children will be deposited in the mailbox.
  true = trace_lib:trace(PidS),

  % Syn with starter process and wait for ack. This syn allows the parent to
  % complete its setup before resuming the root tracer.
  util:syn(Starter),

  % Initialize state. Root system process ID is added to the empty set of
  % processes traced by the root tracer.
  State = #tracer_state{
    traced = add_proc(PidS, ?MODE_DIRECT, #{}), mfa_spec = MfaSpec, analysis = Analysis
  },

  ?exec_if_test(
    % Update tracer-process mapping in ETS lookup tables.
    set_trc_info(PidS, State), ok
  ),

  % Start root tracer in 'direct' mode since it has no ancestor. This means
  % that (i) never has to detach from a parent tracer, and (ii) no trace events
  % are routed to it. The root tracer has no analyzer associated with it either.
  loop(?MODE_DIRECT, State, undefined, Parent).




%% TODO: Add comments and also a flag to determine local or separate analysis.
%%-spec tracer(PidS, PidT, MonFun, MfaSpec, Parent) -> no_return()
%%  when
%%  PidS :: pid(),
%%  PidT :: pid(),
%%  MonFun :: analyzer:monitor(),
%%  MfaSpec :: analyzer:mfa_spec(),
%%  Parent :: parent().
tracer(PidS, PidT, MonFun, MfaSpec, Analysis, Parent) ->

  % Start independent analyzer to analyse trace events.
%%  PidM = analyzer:start(MonFun, Parent),
  Analyzer = init_analyzer(MonFun, Parent, Analysis),
  ?INFO("------------------ Analysis ~p.", [Analysis]),
  ?INFO("Started tracer ~w and analyzer ~w for process ~w.", [self(), Analyzer, PidS]),

  % Detach system process from router tracer. The detach command notifies the
  % router tracer that it is now in charge of collecting trace events for this
  % system process directly.
  detach(PidS, PidT),

  % Initialize tracer state. Detached system process ID is added to the empty
  % set of processes traced by this tracer.
  State = #tracer_state{
    traced = add_proc(PidS, ?MODE_PRIORITY, #{}), mfa_spec = MfaSpec, analysis = Analysis
  },

  ?exec_if_test(
    % Update tracer-process mapping in ETS lookup tables.
    set_trc_info(PidS, State), ok
  ),

  % Start tracer in 'priority' mode since it *has* an ancestor. This means that
  % (i) this tracer has detached from, or is in the process of detaching from
  % the router tracer, (ii) the router tracer potentially needs to route trace
  % events to it before this tracer can, in turn, collect trace events for
  % system processes directly. This tracer can transition to 'direct' mode *only
  % if all* the system processes it traces, i.e., those in the process group,
  % have been marked as detached.
  loop(?MODE_PRIORITY, State, Analyzer, Parent).


%%% ----------------------------------------------------------------------------
%%% Private helper functions.
%%% ----------------------------------------------------------------------------

%% @doc Main tracer loop that routes, collects and analyzes trace events.
%%
%% {@params
%%   {@name Mode}
%%   {@desc Tracer mode.}
%%   {@name State}
%%   {@desc Internal tracer state.}
%%   {@name PidA}
%%   {@desc PID of trace event analyzer or the atom `self'.}
%%   {@name Parent}
%%   {@desc PID of supervisor that is linked to tracer process.}
%% }
%%
%% {@par When {@mono `PidA' =/= `self'}, the tracer creates an independent
%%       analyzer process to which it dispatches trace events for asynchronous
%%       analysis. The tracer and analyzer processes are not linked. When
%%       {@mono `PidA' == `self'}, trace events are analyzed by the tracer.
%% }
%% {@par Tracers operate in one of two modes: `direct' or `priority'. In
%%       `direct' mode, a tracer collects trace events for the system process or
%%       processes it traces directly. In `priority' mode, the tracer has to
%%       wait for the router tracer to route trace events to it. Routed priority
%%       trace events necessarily temporally precede any other event the tracer
%%       comes across in the future, and therefore, must be handled first. Only
%%       when these are handled, and a corresponding detach command has been
%%       issued by the tracer for {@emph each} of the system processes it traces
%%       can it transition to `direct' mode.
%% }
%%
%% <p>The contents of the routing table are managed by the receive handlers of
%% the `spawn' and `stp' events. The `spawn' event adds new entries into the
%% routing table only if a tracer (and by extension, a monitor) can be created
%% for the spawned process. This is decided based on the MFA in the `PropLst'
%% dictionary. If no tracer will be created (since the MFA in the `spawn' event
%% is not contained in the `PropLst' dictionary) no entry is added in the
%% routing table. Entries are removed from the routing table once a `stp' event
%% is received. The event `stp' serves to notify the ancestor tracer that the
%% local tracer is subscribed to its local trace, and therefore, requires no
%% further message routing.</p>
%% {@returns Does not return.}
-spec loop(Mode, State, PidA, Parent) -> no_return()
  when
  Mode :: mode(),
  State :: state(),
  PidA :: pid() | self | undefined,
  Parent :: parent().
loop(?MODE_PRIORITY, State = #tracer_state{}, PidA, Parent) ->

  % Analyzer reference must be one of PID or the atom 'self' when the tracer is
  % in 'priority' mode. It cannot be 'undefined': this is only allowed for the
  % root tracer which is *always* started in 'direct' mode, never 'priority'.
  ?assert(is_pid(PidA) or (PidA =:= self), "Analyzer reference is not PID | self"),
%%  ?exec_if_test(show_state(State, ?MODE_PRIORITY), ok),

  % When in 'priority' mode, the tracer dequeues *only* routed messages. These
  % can be either (i) priority trace events, or (ii) 'detach' commands. Invalid
  % junk messages left in the mailbox to be disposed of by the tracer when in
  % 'direct' mode (see receive clause _Other in loop/5 function for 'direct').
  receive
    Msg = {route, PidRtr, Cmd} when element(1, Cmd) =:= detach ->
      ?TRACE("(*) Dequeued relayed command ~w from router tracer ~w.", [Msg, PidRtr]),

      % Routed 'detach' command. It may be forwarded to the next hop, but if
      % not possible (no entry in routing map), is handled by the tracer.
      % Handling 'detach' may cause the tracer to transition to 'direct' mode.
      %
      % *Invariant*: It must be the case that for the tracer to handle the
      % routed 'detach' command, it should be the tracer that issued the
      % command in the first place. Consequently, the tracer PID embedded inside
      % the routed command must correspond to self().
      State0 = handle_detach(State, Msg, PidA, Parent),
      loop(?MODE_PRIORITY, State0, PidA, Parent);

    Msg = {route, PidRtr, Evt} when element(1, Evt) =:= trace ->
      ?TRACE("(*) Dequeued relayed trace event ~w from router tracer ~w.", [Msg, PidRtr]),

      % Routed trace event. It may be forwarded to the next hop, but if not
      % possible (no entry in routing map), is handled by the tracer.
      State0 = handle_event(?MODE_PRIORITY, State, Msg, PidA, Parent),
      loop(?MODE_PRIORITY, State0, PidA, Parent)
  end;

loop(?MODE_DIRECT, State = #tracer_state{}, PidA, Parent) ->
%%  ?exec_if_test(show_state(State, ?MODE_DIRECT), ok),

  % When in 'direct' mode, the tracer dequeues both direct and routed messages.
  % These can be (i) trace events collected directly, (ii) 'detach' commands
  % received directly from descendant tracers, (iii) routed trace events, or
  % (iv) routed 'detach' commands. Invalid junk messages are dequeued by the
  % tracer as well.
  receive
    Evt when element(1, Evt) =:= trace ->
      ?TRACE("(o) Obtained trace event ~w.", [Evt]),

      % Direct trace event. It may be forwarded to the next hop, but if not
      % possible (no entry in routing map), is handled by the tracer.
      State0 = handle_event(?MODE_DIRECT, State, Evt, PidA, Parent),
      loop(?MODE_DIRECT, State0, PidA, Parent);

    Cmd when element(1, Cmd) =:= detach ->
      ?TRACE("(o) Signalled by command ~w from ~w.", [Cmd, element(2, Cmd)]),

      % Non-routed 'detach' command. Non-routed 'detach' commands are sent
      % by one specific descendant tracer to signal a system process detach.
      % The tracer reacts by routing the 'detach' command to the next hop, thus
      % designating it as the *router tracer* for that detach and associated
      % descendant tracer process that issued the 'detach'.
      %
      % *Invariant*: It must the case that for the tracer to route the 'detach'
      % command, an entry in the routing map for this command must exist for it
      % to be routed.
      State0 = route_detach(State, Cmd, PidA, Parent),
      loop(?MODE_DIRECT, State0, PidA, Parent);

    Msg = {route, PidRtr, Evt} when element(1, Evt) =:= trace ->
      ?TRACE("(o) Dequeued forwarded trace event ~w from router tracer ~w.",
        [Msg, PidRtr]),

      % Routed trace event. Since a routed trace event must *always* be handled
      % by a tracer when in 'priority' mode, the only possible option is for the
      % tracer to forward the event to the next hop.
      %
      % *Invariant*: It must be the case that for the tracer to forward the
      % trace event, an entry in the routing map for this event must exist for
      % it to be routed.
      State0 = forwd_event(State, Msg),
      loop(?MODE_DIRECT, State0, PidA, Parent);

  %% TODO: May be incorporated in the above clause of forwd_routed.
    Msg = {route, PidRtr, Cmd} when element(1, Cmd) =:= detach ->
      ?TRACE("(o) Dequeued forwarded detach command ~w from router tracer ~w.",
        [Msg, PidRtr]),

      % Routed 'detach' command. Since a routed 'detach' command must *always*
      % be handled by a tracer when in 'priority' mode, the only possible option
      % is for the tracer to forward the command to the next hop.
      %
      % *Invariant*: It must be the case that for the tracer to forward the
      % 'detach' command, an entry in the routing map for this command must
      % exist for it to be routed.
      State0 = forwd_detach(State, Msg, PidA, Parent),
      loop(?MODE_DIRECT, State0, PidA, Parent);

    _Other ->

      % Invalid or unexpected message. Error out as a sanity check indicating
      % the presence of a bug in the algorithm.
      ?ERROR("(o) Dequeued invalid message ~w.", [_Other]),
      error(invalid_event)
  end.


%% @doc Handles trace events in direct and priority modes.
%%
%% {@params
%%   {@name Mode}
%%   {@desc Tracer mode.}
%%   {@name State}
%%   {@desc Tracer state.}
%%   {@name Msg}
%%   {@desc What?????????????????????????????????????????????????????????????}
%%   {@name PidA}
%%   {@desc PID of trace event analyzer or `self'.}
%%   {@name Parent}
%%   {@desc PID of supervisor that is linked to tracer process.}
%% }
%%
%% {@returns Updated tracer state.}
-spec handle_event(Mode, State, Msg, PidA, Parent) -> state()
  when
  Mode :: mode(),
  State :: state(),
  Msg :: event:evm_event() | routed(event:evm_event()),
  PidA :: analyzer(),
  Parent :: parent().
handle_event(?MODE_DIRECT, State, Evt = {trace, PidSrc, spawn, PidTgt, _}, PidA, Parent) ->
  do_handle(PidSrc, State,
    fun _Route(PidT) ->

      % Route trace event to next hop. Routing of a 'spawn' events result in the
      % addition of a tracer-process mapping in the tracer routing map.
      route(PidT, Evt),
      State#tracer_state{
        routes = add_route(PidTgt, PidT, State#tracer_state.routes)
      }
    end,
    fun _Instr() ->

      % Analyze trace event. Analysis is performed only if the analyzer is
      % available. This is not the case for the root tracer, PidA == undefined.
%%      if PidA =/= undefined -> analyze(PidA, Evt); true -> ok end,
      analyze(PidA, Evt),

      % Instrument tracer and update processed trace event count.
      State0 = instr(?MODE_DIRECT, State, Evt, self(), Parent),
      State1 = set_state(State0, Evt),

      ?exec_if_test(
        % Update tracer-process mapping in ETS lookup tables.
        set_trc_info(PidTgt, State1), State1
      )
    end);
handle_event(?MODE_DIRECT, State, Evt = {trace, PidSrc, exit, _}, PidA, Parent) ->
  do_handle(PidSrc, State,
    fun _Route(PidT) ->

      % Route trace event to next hop.
      route(PidT, Evt),
      State
    end,
    fun _Clean() ->

      % Analyze trace event. Analysis is performed only if the analyzer is
      % available. This is not the case for the root tracer, PidA == undefined.
%%      if PidA =/= undefined -> analyze(PidA, Evt); true -> ok end,
      analyze(PidA, Evt),

      % Remove terminated system process from traced processes map and update
      % processed trace event count.
      State0 = State#tracer_state{
        traced = del_proc(PidSrc, State#tracer_state.traced)
      },
      State1 = set_state(State0, Evt),

      ?exec_if_test(
        % Update tracer-process mapping in ETS lookup tables.
        set_trc_info(PidSrc, State1), State1
      ),

      % Check whether tracer can be terminated.
      try_gc(State1, PidA, Parent)
    end);
handle_event(?MODE_DIRECT, State, Evt, PidA, _) when
  element(3, Evt) =:= send; element(3, Evt) =:= 'receive'; element(3, Evt) =:= spawned ->
  PidSrc = element(2, Evt),
  do_handle(PidSrc, State,
    fun _Route(PidT) ->

      % Route trace event to next hop.
      route(PidT, Evt),
      State
    end,
    fun _Analyze() ->

      % Analyze trace event. Analysis is performed only if the analyzer is
      % available. This is not the case for the root tracer, PidA == undefined.
%%      if PidA =/= undefined -> analyze(PidA, Evt); true -> ok end,
      analyze(PidA, Evt),

      % Update processed trace event count.
      State0 = set_state(State, Evt),

      ?exec_if_test(
        % Update tracer-process mapping in ETS lookup tables.
        set_trc_info(PidSrc, State0), State0
      )
    end);

handle_event(?MODE_PRIORITY, State, Msg = {route, PidRtr, Evt = {trace, PidSrc, spawn, PidTgt, _}}, PidA, Parent) ->
  do_handle(PidSrc, State,
    fun _Forwd(PidT) ->

      % Forward trace event to next hop. Forwarding of 'spawn' events result in
      % the addition of a tracer-process mapping in the tracer routing map.
      forwd(PidT, Msg),
      State#tracer_state{
        routes = add_route(PidTgt, PidT, State#tracer_state.routes)
      }
    end,
    fun _Instr() ->

      % Analyze trace event.
      analyze(PidA, Evt),

      % Instrument tracer and update processed trace event count.
      State0 = instr(?MODE_PRIORITY, State, Evt, PidRtr, Parent),
      State1 = set_state(State0, Evt),

      ?exec_if_test(
        % Update tracer-process mapping in ETS lookup tables.
        set_trc_info(PidTgt, State1), State1
      )
    end);
handle_event(?MODE_PRIORITY, State, Msg = {route, _PidRtr, Evt = {trace, PidSrc, exit, _}}, PidA, Parent) ->
  do_handle(PidSrc, State,
    fun _Forwd(PidT) ->

      % Forward trace event to next hop.
      forwd(PidT, Msg),
      State
    end,
    fun _Clean() ->

      % Analyze trace event.
      analyze(PidA, Evt),

      % Remove terminated system process from traced processes map and update
      % processed trace event count.
      State0 = State#tracer_state{
        traced = del_proc(PidSrc, State#tracer_state.traced)
      },
      State1 = set_state(State0, Evt),

      ?exec_if_test(
        % Update tracer-process mapping in ETS lookup tables.
        set_trc_info(PidSrc, State1), State1
      ),

      % Check whether tracer can be terminated.
      try_gc(State1, PidA, Parent)
    end);
handle_event(?MODE_PRIORITY, State, Msg = {route, _PidRtr, Evt}, PidA, _) when
  element(3, Evt) =:= send; element(3, Evt) =:= 'receive'; element(3, Evt) =:= spawned ->
  PidSrc = element(2, Evt),
  do_handle(PidSrc, State,
    fun _Forwd(PidT) ->

      % Forward trace event to next hop.
      forwd(PidT, Msg),
      State
    end,
    fun _Analyze() ->

      % Analyze trace event.
      analyze(PidA, Evt),

      % Update processed trace event count.
      State0 = set_state(State, Evt),

      ?exec_if_test(
        % Update tracer-process mapping in ETS lookup tables.
        set_trc_info(PidSrc, State0), State0
      )
    end);

handle_event(_, State, Msg, _, _) ->
  ?WARN("Not handling trace event ~p.", [Msg]),
  State.


%% @doc Instruments a system process with a new tracer or adds the system
%% process under the current tracer.
%%
%% {@params
%%   {@name Mode}
%%   {@desc Tracer mode.}
%%   {@name State}
%%   {@desc Tracer state.}
%%   {@name Event}
%%   {@desc Trace event containing the information of the new system process.}
%%   {@name PidT}
%%   {@desc PID of the tracer process to issue the detach command to.}
%%   {@name Parent}
%%   {@desc PID of supervisor that is linked to tracer process.}
%% }
%%
%% {@returns Updated tracer state.}
-spec instr(Mode, State, Event, PidT, Parent) -> state()
  when
  Mode :: mode(),
  State :: state(),
  Event :: event:evm_event(),
  PidT :: pid(),
  Parent :: parent().
instr(Mode, State, {trace, _, spawn, PidTgt, Mfa = {_, _, _}}, PidT, Parent)
  when Mode =:= ?MODE_PRIORITY; Mode =:= ?MODE_DIRECT ->

  % Check whether a new tracer needs to be instrumented for the system process.
  % This check is performed against the instrumentation map which contains the
  % MFAs that require tracing.
  case (State#tracer_state.mfa_spec)(Mfa) of
    undefined ->
      ?TRACE("No tracer found for process ~w; adding to own traced processes map.", [PidTgt]),

      % A new tracer is not required. In 'priority' mode, the tracer handles a
      % 'spawn' trace event of an existing system process that is being traced
      % by another (router) tracer. Therefore, send a 'detach' command to the
      % router tracer to signal that the system process will be transferred
      % under the tracer that collects trace events directly from the process.
      % In 'direct' mode, this 'spawn' event is collected directly from the
      % newly created system process (i.e., event is not routed) *and* a new
      % tracer is not created. Consequently, there is no 'detach' to perform.
      if Mode =:= ?MODE_PRIORITY -> detach(PidTgt, PidT); true -> ok end,

      % New system process is added to the traced processes map under the
      % tracer. The process is marked with the tracer mode it was added in.
      State#tracer_state{
        traced = add_proc(PidTgt, Mode, State#tracer_state.traced)
      };
    {ok, MonFun} ->

      % A new tracer is required. In 'priority' mode, the tracer handles a
      % 'spawn' trace event of an existing system process that is being traced
      % by another (router) tracer. In direct mode, this 'spawn' event is
      % collected directly from the newly-created system process (i.e., the
      % event is not routed). However, a new tracer needs to be created.
      % Consequently, in both priority and direct modes, a 'detach' is required
      % so signal to the router tracer that the system process will be
      % transferred under the new tracer that collects events directly from this
      % process. When in 'priority' mode, the router tracer will never be a
      % parent of the new tracer, but an ancestor; in 'direct' mode the router
      % tracer to whom the 'detach' is sent will always be a (direct) parent of
      % the new tracer. The 'detach' command is sent by the new tracer, see
      % trace/5 for details.
      %
      % Note that the new system process is not added to the traced processes
      % map of the tracer since it is being traced by the new tracer.
      Args = [PidTgt, PidT, MonFun, State#tracer_state.mfa_spec, State#tracer_state.analysis, Parent],
      PidT0 = spawn(?MODULE, tracer, Args),

      ?INFO("Instrumenting tracer ~w on MFA ~w for process ~w.", [PidT0, Mfa, PidTgt]),

      % New system process is NOT added to the set of processes this tracer
      % currently traces: it is being traced by the new tracer. Set up new route
      % in this tracer's routes table to enable it to forward other events for
      % the system process to the new tracer.

      % Create a new process-tracer mapping in the routes map to enable the
      % tracer to forward events to the next hop. The next hop is, in fact, the
      % newly-created tracer.
      State#tracer_state{
        routes = add_route(PidTgt, PidT0, State#tracer_state.routes)
      }
  end.


%% @doc Routes detach commands to the next hop.
%%
%% {@params
%%   {@name State}
%%   {@desc Tracer state.}
%%   {@name Cmd}
%%   {@desc Detach command to route.}
%%   {@name PidA}
%%   {@desc PID of trace event analyzer or `self'.}
%%   {@name Parent}
%%   {@desc PID of supervisor that is linked to tracer process.}
%% }
%%
%% {@par The function should be used in `direct' mode.}
%% {@par Detach commands {@emph must} be routed when the tracer is in `direct'
%%       mode.
%% }
%%
%% {@returns Updated tracer state, or does not return if tracer is garbage
%%           collected.
%% }
-spec route_detach(State, Cmd, PidA, Parent) -> state() | no_return()
  when
  State :: state(),
  Cmd :: detach(),
  PidA :: analyzer(),
  Parent :: parent().
route_detach(State, Cmd = {detach, PidT, PidTgt}, PidA, Parent) ->
  do_handle(PidTgt, State,
    fun _Route(PidT) ->

      % Route 'detach' command to next hop. Commands to be routed are sent by
      % one specific descendant tracer to signal a system process detach. This
      % means that the entry for that process-tracer mapping in all other tracer
      % routing maps becomes redundant, for the tracer sending the detach
      % command can now collect trace events directly for the system process in
      % question. As a result, it no longer relies on trace events being routed
      % to it for that particular system process. The process-tracer mapping is
      % removed from the routing map. All tracers in subsequent hops handle the
      % routed 'detach' command analogously.
      route(PidT, Cmd),
      State0 = State#tracer_state{routes = del_route(PidTgt, State#tracer_state.routes)},

      % Check whether tracer can be terminated.
      try_gc(State0, PidA, Parent)
    end,
    fun _Fail() ->

      % TODO: Copy to main loop?
      % *Invariant*: For the command to be routed, a corresponding entry in
      % the routing map must exist. This entry should have been created by the
      % tracer when it handled the 'spawn' event of the process whose command in
      % question is being routed.

      % *Violation*: If this case is reached, such an entry does not exist and
      % the command cannot be routed to the next hop, and it must have been
      % sent to the tracer by mistake.
      ?assert(false, format("Detach command sent from tracer ~w not expected", [PidT]))
    end).

%% @doc Forwards detach commands to the next hop.
%%
%% {@params
%%   {@name State}
%%   {@desc Tracer state.}
%%   {@name Rtd}
%%   {@desc Routed message to forward.}
%%   {@name PidA}
%%   {@desc PID of trace event analyzer or `self'.}
%%   {@name Parent}
%%   {@desc PID of supervisor that is linked to tracer process.}
%% }
%%
%% {@par The function should be used in `direct' mode.}
%% {@par When a tracer is in `priority' mode, it can either handle or forward
%%       `detach' commands. This command enables a tracer to transition from
%%       `priority' mode to `direct' mode only once all the processes in the
%%        traced processes map are marked as detached by the tracer; this
%%        procedure can only be accomplished by the tracer when it handles the
%%        command for the particular process being detached. When, the command
%%        cannot be handled by the tracer, it is forwarded to the next hop, see
%%        {@link handle_detach/4}. A `detach' is not designed to be handled by
%%        tracers when in `direct' mode, and {@emph must} always be forwarded.
%% }
%%
%% {@returns Updated tracer state, or does not return if tracer is garbage
%%           collected.}
-spec forwd_detach(State, Rtd, PidA, Parent) -> state() | no_return()
  when
  State :: state(),
  Rtd :: routed(detach()),
  PidA :: analyzer(),
  Parent :: parent().
forwd_detach(State, Msg = {route, _, {detach, _PidT, PidTgt}}, PidA, Parent) ->
  do_handle(PidTgt, State,
    fun _Forwd(PidT) ->

      % Forward 'detach' command to next hop. Forwarding of 'detach' commands
      % results in the removal of a process-tracer mapping in the tracer
      % routing map.
      forwd(PidT, Msg),
      State0 = State#tracer_state{
        routes = del_route(PidTgt, State#tracer_state.routes)
      },

      % ** Harmless race condition **
      % There are cases when a 'detach' command sent by a tracer to the router
      % tracer for a particular process is routed back by the latter tracer
      % *after* the process in question has been removed from the traced
      % processes map of the tracer sending the 'detach' command. This happens
      % when the 'exit' trace event of the process is handled by the tracer.
      % Note that such a scenario necessarily arises when the tracer is in
      % 'priority' mode; it cannot arise when the tracer is in 'direct' mode
      % simply because the tracer has not yet handled the 'detach' command, and
      % is therefore, still in 'priority' mode.
      %
      % In cases where there are no processes to trace (all 'exit' events have
      % been handled), the associated tracer is garbage collected, and the
      % 'detach' command is forwarded to a non-existent tracer.
      %
      % Both of these cases are harmless, and the tracer choreography is still
      % sound. These are two examples where this situation might occur:
      %
      % Suppose a system consists of two processes, P, Q and R. Q is forked by
      % P, and R is forked by Q, and the whole execution completes before any
      % tracer is created. The trace is thus: 'fork(P, Q).fork(Q, R).exit(R)'.
      % 1. The first case is where Q and R are traced by separate tracers. When
      %    the root tracer processes 'fork(P, Q)', it creates a tracer TQ for Q.
      %    TQ is in 'priority' mode with process Q in its traced processes map.
      %    TQ sends a 'detach' command to the root tracer that in turn, routes
      %    back to TQ. Next, the root tracer routes 'fork(Q, R)' to TQ which
      %    handles it to create TR for R. TR is in 'priority' mode with process
      %    R in its traced processes map. TQ sends a 'detach' command to the
      %    root tracer. Finally, the root tracer routes 'exit(R)' to TR via
      %    tracer TQ. When TR handles 'exit(R)' removes the entry for R from its
      %    traced processes map and terminates (it has an empty routing map).
      %    Eventually, the 'detach' command for process R is forwarded by TQ to
      %    the non-existent tracer TR. The command for R is not processed, but
      %    the tracer choreography remains sound.

      % Check whether tracer can be terminated.
      try_gc(State0, PidA, Parent)
    end,
    fun _DetachOfATerminatedProcessNoLongerInTheTracedProcessesMapOfTracer() ->

      % ** Harmless race condition (continued from the previous case) **
      % 2. The second case is where Q and R are traced by the same tracer. When
      %    the root tracer processes 'fork(P, Q)', it creates a tracer TQR. TQR
      %    is in 'priority' mode with process Q in its traced processes map. TQR
      %    sends a 'detach' command for process Q to the root tracer. Next, the
      %    root tracer routes 'fork(Q, R)' to TQR which handles it to add
      %    process R to its traced process map too. TQR sends a 'detach' command
      %    for R to the root tracer. Finally, the root tracer routes 'exit(R)'
      %    to TQR which handles it by removing R from its traced processes map.
      %    Note that process R is removed while R is marked as 'priority'.
      %    Eventually, the 'detach' command for process Q is routed by the
      %    root tracer to TQR, which results in Q being marked as 'direct' in
      %    the traced processes map of TQR. Meanwhile, note that the routing map
      %    in TQR is empty. Since all the processes in the traced processes map
      %    (only Q) are marked as 'direct', TQR switched to 'direct' mode. Right
      %    after, the 'detach' command for process R reaches TQR. Now, this
      %    command cannot be routed, since the routing map is empty, and must
      %    therefore be handled (i.e., this case). By design, there is nothing
      %    to handle, since process R has already been removed from the traced
      %    processes map of TQR. Similar to case 1 above, the command for R is
      %    not processed, albeit for a different reason, but the tracer
      %    choreography remains sound.
      ?TRACE("Routed 'detach' command handled for (already) terminated process ~w.", [PidTgt]),
      State
    end).

%% @doc Handles detach commands or forwards them to the next hop.
%%
%% {@params
%%   {@name State}
%%   {@desc Tracer state.}
%%   {@name Rtd}
%%   {@desc Routed message to forward.}
%%   {@name PidA}
%%   {@desc PID of trace event analyzer or `self'.}
%%   {@name Parent}
%%   {@desc PID of supervisor that is linked to tracer process.}
%% }
%%
%% {@par The function should be used in `priority' mode.}
%% {@par Detach commands can be either handled {@emph or} forwarded when the
%%       tracer is in `priority' mode.
%% }
%%
%% {@returns Updated tracer state, or does not return if tracer is garbage
%%           collected.}
-spec handle_detach(State, Rtd, PidA, Parent) -> UpdatedState :: state() | no_return()
  when
  State :: state(),
  Rtd :: routed(detach()),
  PidA :: analyzer(),
  Parent :: parent().
handle_detach(State, Rtd = {route, _, {detach, Self, PidTgt}}, PidA, Parent) ->
  do_handle(PidTgt, State,
    fun _Relay(PidT) ->

      % Forward 'detach' command to next hop. Forwarding of 'detach' commands
      % results in the removal of a process-tracer mapping in the tracer
      % routing map.
      forwd(PidT, Rtd),
      State0 = State#tracer_state{
        routes = del_route(PidTgt, State#tracer_state.routes)
      },

      % Check whether tracer can be terminated.
      try_gc(State0, PidA, Parent)
    end,
    fun _CheckIfCanTransitionToDirectMode() ->

      % *Invariant*: A 'detach' command that is not forwarded must always be
      % handled by the tracer in 'priority' mode. This means that the tracer
      % handling the command must be the same tracer that sent the `detach'
      % command to the routed tracer.

      % *Violation*: The PID of the sending tracer embedded inside the 'detach'
      % command is not the same as self().
      ?assertEqual(self(), Self, format("Tracer ~w is not equal to ~w for detach command", [Self, self()])),

      % A 'detach' command is interpreted as an end-of-trace marker for the
      % particular process being traced. Update the entry for the detached
      % system process in the traced processes map by switching it from
      % 'priority' to direct'. The tracer now collects events for said process
      % directly from the trace.
      State0 = State#tracer_state{
        traced = sub_proc(PidTgt, ?MODE_DIRECT, State#tracer_state.traced)
      },

      % Check whether tracer can transition to 'direct' mode. This is possible
      % only if all processes in the traced processes map are marked 'direct'.
      case can_detach(State0) of
        true ->

          ?TRACE("Tracer ~w switched to ~w mode.", [self(), ?MODE_DIRECT]),
          loop(?MODE_DIRECT, State0, PidA, Parent);
        false ->
          State0
      end
    end).

%% @doc Forwards routed trace events.
%%
%% {@params
%%   {@name State}
%%   {@desc Tracer state.}
%%   {@name Msg}
%%   {@desc Routed message to forward.}
%% }
%%
%% {@par The function should be used in `direct' mode.}
%% {@par When a tracer is in `priority' mode, it can either handle or forward
%%       trace events. Handling enables the tracer to analyze the event. When
%%       the event cannot be handled by the tracer, it is forwarded to the next
%%       hop, see {@link handle_event/5}, `priority' mode. A trace event is not
%%       designed to be handled by tracers when in `direct' mode, and {@emph
%%       must} always be forwarded.
%% }
%%
%% {@returns Update tracer state.}
% TODO: Can this be tightened? It can but the result is more cryptic.
-spec forwd_event(State, Rtd) -> state()
  when
  State :: state(),
  Rtd :: routed(event:evm_event()).
forwd_event(State, Rtd = {route, _, {trace, PidSrc, spawn, PidTgt, _}}) ->
  do_handle(PidSrc, State,
    fun _Forwd(PidT) ->

      % Forward trace event to next hop. Forwarding of 'spawn' events results in
      % the addition of a process-tracer mapping in the tracer routing map for
      % the child process.
      forwd(PidT, Rtd),
      State#tracer_state{
        routes = add_route(PidTgt, PidT, State#tracer_state.routes)
      }
    end,
    fun _Fail() ->

      % TODO: Copy it to main loop?
      % *Invariant*: For the event to be forwarded, a corresponding entry in the
      % routing map must exist. This entry should have been created by the
      % tracer when it handled the 'spawn' event of the process whose event in
      % question is being forwarded.

      % *Violation*: If this case is reached, such an entry does not exist and
      % the event cannot be forwarded. This means that the event must be handled
      % by the tracer, but this goes against the assumption that the event
      % should have been handled by the tracer when in 'priority' mode.
      ?assert(false, format("Routed trace event ~w cannot be handled while in ~s mode", [Rtd, ?MODE_DIRECT]))
    end);
forwd_event(State, Rtd = {route, _, Evt}) ->
  PidSrc = element(2, Evt),
  do_handle(PidSrc, State,
    fun _Forwd(PidT) ->

      % Forward trace event to next hop.
      forwd(PidT, Rtd),
      State
    end,
    fun _Fail() ->

      % *Invariant*: For the event to be forwarded, a corresponding entry in the
      % routing map must exist. This entry should have been created by the
      % tracer when it handled the 'spawn' event of the process whose event in
      % question is being forwarded.

      % *Violation*: If this case is reached, such an entry does not exist and
      % the event cannot be forwarded. This means that the event must be handled
      % by the tracer, but this goes against the assumption that the event
      % should have been handled by the tracer when in 'priority' mode.
      ?assert(false, format("Routed trace event ~w cannot be handled while in ~s mode", [Rtd, ?MODE_DIRECT]))
    end).





-spec set_stats(Stats, Event) -> event_stats()
  when
  Stats :: event_stats(),
  Event :: event:evm_event().
set_stats(Stats = #event_stats{cnt_spawn = Cnt}, {trace, _, spawn, _, _}) ->
  Stats#event_stats{cnt_spawn = Cnt + 1};
set_stats(Stats = #event_stats{cnt_exit = Cnt}, {trace, _, exit, _}) ->
  Stats#event_stats{cnt_exit = Cnt + 1};
set_stats(Stats = #event_stats{cnt_send = Cnt}, {trace, _, send, _, _}) ->
  Stats#event_stats{cnt_send = Cnt + 1};
set_stats(Stats = #event_stats{cnt_receive = Cnt}, {trace, _, 'receive', _}) ->
  Stats#event_stats{cnt_receive = Cnt + 1};
set_stats(Stats = #event_stats{cnt_spawned = Cnt}, {trace, _, spawned, _, _}) ->
  Stats#event_stats{cnt_spawned = Cnt + 1};
set_stats(Stats = #event_stats{cnt_other = Cnt}, Event) when element(1, Event) =:= trace ->
  Stats#event_stats{cnt_other = Cnt + 1}.

-spec set_state(State, Event) -> State0 :: state()
  when
  State :: state(),
  Event :: event:evm_event().
set_state(State = #tracer_state{trace = _Trace, stats = Stats}, Event) ->
  State0 = State#tracer_state{stats = set_stats(Stats, Event)},
  ?exec_if_test(State0#tracer_state{trace = [Event | _Trace]}, State0).


%%% ----------------------------------------------------------------------------
%%% Private helper functions.
%%% ----------------------------------------------------------------------------

-spec add_proc(PidS, Mode, Group) -> UpdatedGroup :: traced()
  when
  PidS :: pid(),
  Mode :: mode(),
  Group :: traced().
add_proc(PidS, Mode, Group) ->
  ?assertNot(maps:is_key(PidS, Group),
    format("Process ~w must not exist when adding", [PidS])),
  Group#{PidS => Mode}.

-spec del_proc(PidS :: pid(), Group :: traced()) -> UpdatedGroup :: traced().
del_proc(PidS, Group) ->
  % ?assert(maps:is_key(PidS, Group), % TODO: Commented this for now since might be a potential bug.
  %   format("Process ~w must exist when deleting", [PidS])),

  % Is it always the case that a process must exist before deleting?
  % Well for sure, a process is deleted when an exit is processed.
  ?TRACE("Process ~w deleted from group while in ~w mode.", [PidS, maps:get(PidS, Group)]),

  maps:remove(PidS, Group).

-spec sub_proc(PidS, NewMode, Group) -> UpdatedGroup :: traced()
  when
  PidS :: pid(),
  NewMode :: mode(),
  Group :: traced().
sub_proc(PidS, NewMode, Group) ->
  % It may be the case that the process we are trying to update does not exist.
  % This happens when a process has exited and is removed from the process group
  % BEFORE the detach command reaches the monitor and there would be no process
  % to update. In this case do nothing and leave group unmodified.
  case maps:is_key(PidS, Group) of
    true ->
      Group#{PidS := NewMode}; % Only update existing value, otherwise fail.
    false ->
      ?TRACE("Process ~w not updated since it is no longer in group.", [PidS]),
      Group
  end.

-spec add_route(PidS :: pid(), PidT :: pid(), Routes :: routes()) ->
  UpdatedRoutes :: routes().
add_route(PidS, PidT, Routes) ->
  ?assertNot(maps:is_key(PidS, Routes)),
  Routes#{PidS => PidT}.

-spec del_route(PidS :: pid(), Routes :: routes()) ->
  UpdatedRoutes :: routes().
del_route(PidS, Routes) ->
  ?assert(maps:is_key(PidS, Routes)),
  maps:remove(PidS, Routes).

-spec can_detach(State :: state()) -> boolean().
can_detach(#tracer_state{traced = Group}) ->
  length(lists:filter(
    fun(?MODE_DIRECT) -> false; (_) -> true end, maps:values(Group)
  )) =:= 0.

-spec detach(PidS :: pid(), PidT :: pid()) -> Detach :: detach().
detach(PidS, PidT) ->

  % Preempt former (ancestor) tracer. This tracer now takes over the tracing of
  % the system process: this gives rise to a new 'trace partition'. Ancestor
  % tracer is informed that this tracer (i.e., self()) issued preempt, and that
  % moreover, tracing of the system process will be done by this tracer in turn.
  % Note that there is one specific case where preempt does not succeed (i.e.,
  % returns 'false'): this arises whenever preempt is invoked on a process that
  % has exited before the call to preempt was made. This is perfectly normal,
  % since the tracer is asynchronous, and may process event long after the
  % system process in under scrutiny has terminated.
  trace_lib:preempt(PidS),
  PidT ! {detach, self(), PidS}.

-spec try_gc(State, Analyzer, Parent) -> State :: state() | no_return()
  when
  State :: state(),
  Analyzer :: pid() | undefined,
  Parent :: parent().
try_gc(#tracer_state{traced = Group, routes = Routes, trace = _Trace, stats = Stats}, undefined, Parent) when
  map_size(Group) =:= 0, map_size(Routes) =:= 0 ->

  ?DEBUG("Terminated ROOT tracer ~w.", [self()]),
%%  ?TRACE("Terminated ROOT tracer ~w with trace ~p.", [self(), Trace]),

  % Link to owner process (if Owner =/= self) and exit. Stats are embedded in
  % the exit signal so that these can be collected if Owner is trapping exits.
  if is_pid(Parent) -> link(Parent); true -> ok end,
  exit({garbage_collect, {root, Stats}});

%%try_gc(#tracer_state{traced = Group, routes = Routes, trace = _Trace, stats = Stats}, self, Owner) when
%%  map_size(Group) =:= 0, map_size(Routes) =:= 0 ->
%%  ?DEBUG("Terminated tracer ~w.", [self()]),
%%  if is_pid(Owner) -> link(Owner); true -> ok end,
%%  exit({garbage_collect, {tracer, Stats}});


try_gc(#tracer_state{traced = Group, routes = Routes, trace = _Trace, stats = Stats}, Analyzer, Parent) when
  map_size(Group) =:= 0, map_size(Routes) =:= 0 ->

  % Issue stop command to monitor. Monitor will eventually process the command
  % and terminate its execution.
%%  analyzer:stop(PidM),
  stop_analyzer(Analyzer),

  ?DEBUG("Terminated tracer ~w for analyzer ~w.", [self(), Analyzer]),
%%  ?TRACE("Terminated tracer ~w for monitor ~w with trace ~p.",
%%    [self(), PidM, Trace]),

  % Link to owner process (if Owner =/= self) and exit. Stats are embedded in
  % the exit signal so that these can be collected if Owner is trapping exits.
  % Note: Stats are sent from the tracer (rather than the monitor), since the
  % monitor might not process all trace events before reaching a verdict, and
  % the stats collected up to that point would not reflect the true count. While
  % this may still be solved by post processing the monitor's mailbox, it would
  % needlessly complicate its code.
  if is_pid(Parent) -> link(Parent); true -> ok end,
  exit({garbage_collect, {tracer, Stats}});

try_gc(State = #tracer_state{}, _, _) ->
  State.

-spec route(PidT, Msg) -> routed(event:evm_event()) | routed(detach())
  when
  PidT :: pid(),
  Msg :: event:evm_event() | detach().
route(PidT, Msg) when element(1, Msg) =:= trace; element(1, Msg) =:= detach ->
  ?TRACE("Tracer ~w routing ~w to next tracer ~w.", [self(), Msg, PidT]),
  PidT ! {route, self(), Msg}.

-spec forwd(PidT :: pid(), Rtd) -> routed(event:evm_event()) | routed(detach())
  when
  Rtd :: routed(event:evm_event()) | routed(detach()).
forwd(PidT, Routed) when element(1, Routed) =:= route ->
  ?TRACE("Tracer ~w forwarding ~w to next hop ~w.", [self(), Routed, PidT]),
  PidT ! Routed.

%%-spec analyze(PidA :: pid(), Evt :: event:evm_event()) -> event:evm_event().
%%analyze(PidA, Evt) when element(1, Evt) =:= trace ->
%%  ?TRACE("Tracer ~w sent trace event ~w to ~w for analysis.",
%%    [self(), Evt, PidA]),
%%  PidA ! Evt.

% TODO: HERE!!!!
%%analyze(self, Evt) when element(1, Evt) =:= trace ->
%%  ?TRACE("Tracer ~w analyzing event ~w internally.", [self(), Evt]),
%%  analyzer:do_monitor(Evt, fun(_Verdict) -> ok end),
%%  Evt;
%%analyze(undefined, _) ->
%%  ?TRACE("Skipping analysis.");
%%analyze(PidA, Evt) when is_pid(PidA), element(1, Evt) =:= trace ->
%%  ?TRACE("Tracer ~w sent event ~w to ~w for analysis.", [self(), Evt, PidA]),
%%  PidA ! Evt.

%% @doc Initializes the analyzer based on the type.
init_analyzer(MonFun, _, internal) ->
  analyzer:embed(MonFun);
init_analyzer(MonFun, Parent, external) ->
  analyzer:start(MonFun, Parent).

stop_analyzer(self) ->
  ok;
stop_analyzer(PidA) when is_pid(PidA) ->
  analyzer:stop(PidA).

% Analyzer.
analyze(undefined, Evt) -> % This should be removed and made explicit in the code.
% Because the only type of tracer that does not have an analyzer is the ROOT monitor: this is the loop in DIRECT mode.
% The loop in priority mode must have an analyzer, because if the tracer is in priority mode, it must have been created
% due to the MonFun MFA, and we stated that new tracers are created in PRIORITY mode.
  ok;
%%analyze(PidA, Evt) when is_pid(PidA), PidA =:= self() ->
%%  ?TRACE("Tracer ~w analyzing event ~w internally.", [self(), Evt]),
%%  analyzer:do_monitor(Evt, fun(_Verdict) -> ok end),
%%  Evt;
analyze(self, Evt) ->
  ?TRACE("Tracer ~w analyzing event ~w internally.", [self(), Evt]),
  analyzer:do_monitor(Evt, fun(_Verdict) -> ok end),
  Evt;
analyze(PidA, Evt) when is_pid(PidA) ->
  ?TRACE("Tracer ~w sent event ~w to ~w for analysis (externally).", [self(), Evt, PidA]),
  PidA ! Evt.



-spec do_handle(PidSrc, State, Forward, Handle) -> term()
  when
  PidSrc :: pid(),
  State :: state(),
  Forward :: fun((NextHop :: pid()) -> term()),
  Handle :: fun(() -> term()).
do_handle(PidSrc, #tracer_state{routes = Routes, traced = Group}, Forward, Handle)
  when is_function(Handle, 0), is_function(Forward, 1) ->

  % In general, the process PID cannot be traced by this tracer (i.e., be in its
  % process group) and at the same time, be contained in the tracer's routes
  % table: this would seem to suggest that the process is also being traced by
  % another tracer. There is one case however, where this statement is not true.
  % When the process PID is not in the tracer's process group, it could also
  % mean that the process in question exited before its corresponding 'detach'
  % command has been processed (i.e., 'detach' would eventually be processed,
  % but the process referred to by the 'detach' is already removed from the
  % process group). Therefore, the assumption that if the process is not in the
  % group, then it must be in the tracer's routes table is WRONG. Yet, the
  % reverse must always hold: a process that is in the tracer's routes table can
  % never be in its process group as well. This means that R -> not G, or stated
  % differently, not R or not G.
  ?assert((not maps:is_key(PidSrc, Routes)) or not maps:is_key(PidSrc, Group)),

  case maps:get(PidSrc, Routes, undefined) of
    undefined ->
      Handle();
    NextHop ->
      Forward(NextHop)
  end.

%% @private Returns a character list that represents data formatted in
%% accordance with the specified format.
-spec format(Format :: string(), Args :: list()) -> String :: string().
format(Format, Args) -> lists:flatten(io_lib:format(Format, Args)).


%%% ----------------------------------------------------------------------------
%%% Statistics functions for events.
%%% ----------------------------------------------------------------------------


-spec cum_sum_stats(Stats0, Stats1) -> Stats2 :: event_stats()
  when
  Stats0 :: event_stats(),
  Stats1 :: event_stats().
cum_sum_stats(Stats0 = #event_stats{cnt_spawn = Spawn0, cnt_exit = Exit0, cnt_send = Send0, cnt_receive = Receive0, cnt_spawned = Spawned0, cnt_other = Other0},
    #event_stats{cnt_spawn = Spawn1, cnt_exit = Exit1, cnt_send = Send1, cnt_receive = Receive1, cnt_spawned = Spawned1, cnt_other = Other1}) ->
  Stats0#event_stats{cnt_spawn = Spawn0 + Spawn1, cnt_exit = Exit0 + Exit1, cnt_send = Send0 + Send1, cnt_receive = Receive0 + Receive1, cnt_spawned = Spawned0 + Spawned1, cnt_other = Other0 + Other1}.

-spec show_stats(Stats0 :: event_stats(), Stats1 :: event_stats()) -> ok.
show_stats(Stats = #event_stats{}, #event_stats{cnt_send = CntSend, cnt_receive = CntRecv, cnt_other = CntTerm}) ->

  % Calculate the number of expected send and receive trace event messages.
  CntSend0 = CntSend + CntRecv + CntTerm,
  CntRecv0 = CntRecv + CntSend + CntTerm,

  Title = format("Trace Summary", []),
  S0 = color_by_pid(self(), format("~n~64c[ ~s ]~64c~n", [$-, Title, $-])) ++
    format("~-8.s ~b~n", ["Spawn:", Stats#event_stats.cnt_spawn]) ++
    format("~-8.s ~b~n", ["Exit:", Stats#event_stats.cnt_exit]) ++
    format("~-8.s ~b (expected ~b, ~.4f% loss)~n", ["Send:", Stats#event_stats.cnt_send, CntSend0, (CntSend0 - Stats#event_stats.cnt_send) / CntSend0 * 100]) ++
    format("~-8.s ~b (expected ~b, ~.4f% loss)~n", ["Receive:", Stats#event_stats.cnt_receive, CntRecv0, (CntRecv0 - Stats#event_stats.cnt_receive) / CntRecv0 * 100]) ++
    format("~-8.s ~b~n", ["Spawned:", Stats#event_stats.cnt_spawned]) ++
    format("~-8.s ~b~n", ["Other:", Stats#event_stats.cnt_other]) ++
    color_by_pid(self(), format("~" ++ integer_to_list(length(Title) + (64 * 2) + 4) ++ "c~n", [$-])),
  io:put_chars(user, S0).

-spec color_by_pid(Pid :: pid(), Text :: string()) -> iolist().
color_by_pid(Pid, Text) when is_pid(Pid) ->
  {_, N, _} = util:pid_tokens(Pid),
  Code = N rem 255,
  ["\e[38;5;", integer_to_list(Code), "m", Text, "\e[0m"].


-ifdef(TEST).

-spec show_state(State :: state(), Mode :: mode()) -> ok.
show_state(State, Mode) ->
  {messages, MQueue} = erlang:process_info(self(), messages),
  Symbol = if Mode =:= ?MODE_DIRECT -> $o; Mode =:= ?MODE_PRIORITY -> $* end,

  Title = format("(~c) Tracer ~w", [Symbol, self()]),
  S0 = color_by_pid(self(), format("~n~64c[ ~s ]~64c~n", [$-, Title, $-])) ++
    format("~-8.s ~p~n", ["Routes:", State#tracer_state.routes]) ++
    format("~-8.s ~p~n", ["Group:", State#tracer_state.traced]) ++
    format("~-8.s ~p~n", ["Trace:", State#tracer_state.trace]) ++
    format("~-8.s ~p~n", ["MQueue:", MQueue]) ++
    color_by_pid(self(), format("~" ++ integer_to_list(length(Title) + (64 * 2) + 4) ++ "c~n", [$-])),
  io:put_chars(user, S0).

-spec init_mon_info_tbls() -> ok.
init_mon_info_tbls() ->
  EtsAttrs = [set, public, named_table, {keypos, 1},
    {write_concurrency, true}],
  ets:new(?MON_INFO_ETS_NAME, EtsAttrs),
  ets:new(?MON_INFO_INV_ETS_NAME, EtsAttrs),
  ok.

-spec get_mon_info() -> list().
get_mon_info() ->
  ets:tab2list(?MON_INFO_ETS_NAME).

-spec get_mon_info(MonPid :: pid()) -> Info :: tuple().
get_mon_info(MonPid) ->
  case ets:lookup(?MON_INFO_ETS_NAME, MonPid) of
    [] ->
      undefined;
    [Info] ->
      Info
  end.

-spec set_trc_info(Pid :: pid(), State :: state()) -> State :: state().
set_trc_info(Pid, State = #tracer_state{traced = Group, trace = Trace}) ->
  MonPid = self(),
  Info = {MonPid, maps:keys(Group), lists:reverse(Trace)},

  % Insert monitor info in lookup and reverse lookup tables.
  ets:insert(?MON_INFO_ETS_NAME, Info),
  ets:insert(?MON_INFO_INV_ETS_NAME, {Pid, MonPid}),
  State.

-spec get_mon_info_rev() -> list().
get_mon_info_rev() ->
  ets:tab2list(?MON_INFO_INV_ETS_NAME).

-spec get_mon_info_rev(Pid :: pid()) -> Info :: tuple() | undefined.
get_mon_info_rev(Pid) ->
  case get_proc_mon(Pid) of
    undefined ->
      undefined;
    MonPid ->
      get_mon_info(MonPid)
  end.

-spec get_proc_mon(Pid :: pid()) -> MonPid :: pid() | undefined.
get_proc_mon(Pid) ->
  case ets:lookup(?MON_INFO_INV_ETS_NAME, Pid) of
    [] ->
      undefined;
    [{_, MonPid}] ->
      MonPid
  end.

-endif.