%%% ----------------------------------------------------------------------------
%%% @author Duncan Paul Attard
%%%
%%% @doc Module description (becomes module heading).
%%%
%%% @end
%%% 
%%% Copyright (c) 2022, Duncan Paul Attard <duncanatt@gmail.com>
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
-module(lin_analyzer).
-author("Duncan Paul Attard").

%%% Includes.
-include_lib("stdlib/include/assert.hrl").
-include("log.hrl").

-compile(export_all).

%%% Public API.
-export([]).

%%% Callbacks/Internal.
-export([]).

%%% Types.
-export_type([rule/0, verdict/0]).


%%% ----------------------------------------------------------------------------
%%% Macro and record definitions.
%%% ----------------------------------------------------------------------------

%% Process dictionary key used to store the synthesized analysis function that
%% is applied to trace events. The result of this function application is used
%% to overwrite the previous result.
-define(MONITOR, '$monitor').

%% Irrevocable verdicts reached by the runtime analysis.
-define(VERDICT_YES, yes).
-define(VERDICT_NO, no).

%% Small-step semantics rule name identifiers; these rules dictate how a monitor
%% is reduced from one state to the next.
-define(M_VRD, mVrd). % Verdict persistence.
-define(M_ACT, mAct). % Action analysis.
-define(M_CHS_L, mChsL). % Left external choice.
-define(M_CHS_R, mChsR). % Right external choice.
-define(M_TAU_L, mTauL). % Left tau reduction.
-define(M_TAU_R, mTauR). % Right tau reduction.
-define(M_PAR, mPar). % Lockstep action reduction.
-define(M_DIS_Y_L, mDisYL). % Yes verdict left disjunction short circuiting.
-define(M_DIS_Y_R, mDisYR). % Yes verdict right disjunction short circuiting.
-define(M_DIS_N_L, mDisNL). % No verdict left disjunction short circuiting.
-define(M_DIS_N_R, mDisNR). % No verdict right disjunction short circuiting.
-define(M_CON_Y_L, mConYL). % Yes verdict left conjunction short circuiting.
-define(M_CON_Y_R, mConYR). % Yes verdict right conjunction short circuiting.
-define(M_CON_N_L, mConNL). % No verdict left conjunction short circuiting.
-define(M_CON_N_R, mConNR). % No verdict right conjunction short circuiting.
-define(M_REC, mRec). % Monitor unfolding.

%% Monitor environment keys.
-define(KEY_ENV, env).
-define(KEY_STR, str).
-define(KEY_VAR, var).
-define(KEY_PAT, pat).
-define(KEY_CTX, ctx).
-define(KEY_NS, ns).

%% Monitor and proof display macros.
-define(PD_SEP, "-").
-define(INDENT(PdId), (length(PdId) + length(?PD_SEP))).

%%% ----------------------------------------------------------------------------
%%% Type definitions.
%%% ----------------------------------------------------------------------------

-type rule() :: ?M_TAU_L | ?M_TAU_R | ?M_REC |
?M_DIS_Y_L | ?M_DIS_Y_L | ?M_DIS_N_L | ?M_DIS_N_R |
?M_CON_Y_L | ?M_CON_Y_R | ?M_CON_N_L | ?M_CON_N_R |
?M_VRD | ?M_ACT | ?M_CHS_L | ?M_CHS_R | ?M_PAR.
%% Small-step semantics rule names.

-type verdict() :: ?VERDICT_NO | ?VERDICT_YES.
%% Verdicts reachable by the runtime analysis.

-type monitor() :: term().

-type pd_id() :: list(integer()).
%% Proof derivation ID.

-type tau() :: tau.
%% Internal monitor silent transition.

-type event() :: any().
%% Analysable trace event actions.

-type premise() :: {pre, pd()}.
%% Proof derivation premise.

-type pd() :: {pd_id(), rule(), event(), monitor(), monitor()} |
{pd_id(), rule(), event(), monitor(), monitor(), premise()} |
{pd_id(), rule(), event(), monitor(), monitor(), monitor(), premise(), premise()}.
%% Three types of proof derivations. One is for axioms that have no premises,
%% one for derivations having one premise, and one for derivations having two
%% premises.

-type env() :: {?KEY_ENV, list()}.
-type str() :: {?KEY_STR, string()}.
-type var() :: {?KEY_VAR, atom()}.
-type pat() :: {?KEY_PAT, term()}.
-type ctx() :: {?KEY_CTX, list()}.
-type ns() :: {?KEY_NS, atom()}.
-type binding() :: {{atom(), atom()}, any()}.


%%% ----------------------------------------------------------------------------
%%% Public API.
%%% ----------------------------------------------------------------------------

% Proof derivation strategy for rules that transition via the internal action tau .

%%% @doc Determines the rule that must be applied to reduce the monitor state by
%%%      one tau transition.
%%%
%%% {@params
%%%   {@name M}
%%%   {@desc Monitor to be reduced.}
%%%   {@name PdId}
%%%   {@desc Proof derivation ID.}
%%% }
%%%
%%% {@returns `true` together with the proof derivation and monitor continuation
%%%           after one tau reduction or `false` if the monitor cannot be
%%%           reduced.
%%% }
-spec derive_tau(M, PdId) -> false | {true, pd(), monitor()}
  when
  M :: monitor(),
  PdId :: pd_id().
derive_tau(L = {'or', _, Yes = {yes, _}, _}, PdId) ->
  ?DEBUG(":: (~s) Reducing using axiom mDisYL: ~s.", [pdid_to_iolist(PdId), format_m(L)]),

  % Axiom mDisYL.
  {true, {{PdId, ?M_DIS_Y_L, tau, L, Yes}, Yes}};

derive_tau(L = {'or', _, _, Yes = {yes, _}}, PdId) ->
  ?DEBUG(":: (~s) Reducing using axiom mDisYR: ~s.", [pdid_to_iolist(PdId), format_m(L)]),

  % Axiom mDisYR.
  {true, {{PdId, ?M_DIS_Y_R, tau, L, Yes}, Yes}};

derive_tau(L = {'or', _, {no, _}, M}, PdId) ->
  ?DEBUG(":: (~s) Reducing using axiom mDisNL: ~s.", [pdid_to_iolist(PdId), format_m(L)]),

  % Axiom mDisNL.
  {true, {{PdId, ?M_DIS_N_L, tau, L, copy_ns(L, copy_ctx(L, M))}, copy_ns(L, copy_ctx(L, M))}};

derive_tau(L = {'or', _, M, {no, _}}, PdId) ->
  ?DEBUG(":: (~s) Reducing using axiom mDisNR: ~s.", [pdid_to_iolist(PdId), format_m(L)]),

  % Axiom mDisNR.
  {true, {{PdId, ?M_DIS_N_R, tau, L, copy_ns(L, copy_ctx(L, M))}, copy_ns(L, copy_ctx(L, M))}};

derive_tau(L = {'and', _, {yes, _}, M}, PdId) ->
  ?DEBUG(":: (~s) Reducing using axiom mConYL: ~s.", [pdid_to_iolist(PdId), format_m(L)]),

  % Axiom mConYL.
  {true, {{PdId, ?M_CON_Y_L, tau, L, copy_ns(L, copy_ctx(L, M))}, copy_ns(L, copy_ctx(L, M))}};

derive_tau(L = {'and', _, M, {yes, _}}, PdId) ->
  ?DEBUG(":: (~s) Reducing using axiom mConYR: ~s.", [pdid_to_iolist(PdId), format_m(L)]),

  % Axiom mConYR.
  {true, {{PdId, ?M_CON_Y_R, tau, L, copy_ns(L, copy_ctx(L, M))}, copy_ns(L, copy_ctx(L, M))}};

derive_tau(L = {'and', _, No = {no, _}, _}, PdId) ->
  ?DEBUG(":: (~s) Reducing using axiom mConNL: ~s.", [pdid_to_iolist(PdId), format_m(L)]),

  % Axiom mConNL.
  {true, {{PdId, ?M_CON_N_L, tau, L, No}, No}};

derive_tau(L = {'and', _, _, No = {no, _}}, PdId) ->
  ?DEBUG(":: (~s) Reducing using axiom mConNR: ~s.", [pdid_to_iolist(PdId), format_m(L)]),

  % Axiom mConNR.
  {true, {{PdId, ?M_CON_N_R, tau, L, No}, No}};

derive_tau(L = {rec, Env, M}, PdId) ->
  ?DEBUG(":: (~s) Reducing using axiom mRec: ~s.", [pdid_to_iolist(PdId), format_m(L)]),

  % The continuation of a recursive construct is encoded in terms of a function
  % that needs to be applied to unfold the monitor. Recursive monitor
  % definitions do not accept parameters.


  % Axiom mRec.
  M_ = M(),


  % Open new namespace.
%%  Env = get_env(M_),

%%  ?TRACE("Env of M_ = ~p", [Env]),

  M__ = set_env(M_, set_ns(get_env(M_), {ns, unwrap_value(get_var(Env))})),

%%  {true, {{PdId, mRec, tau, L}, copy_ctx(L, M_)}};
%%  {true, {{PdId, mRec, tau, L, copy_ctx(L, M_)}, copy_ctx(L, M_)}};
  {true, {{PdId, ?M_REC, tau, L, copy_ctx(L, M__)}, copy_ctx(L, M__)}};

derive_tau(L = {var, Env, M}, PdId) ->
  ?DEBUG(":: (~s) Reducing using axiom mRec (var): ~s.", [pdid_to_iolist(PdId), format_m(L)]),

  % Recursive variables complement recursive constructs, and are used to refer
  % to recursive monitor definitions. Identically to the recursive construct,
  % the variable itself is a function reference that needs to be applied to
  % unfold the monitor. Recursive monitor definitions do not accept parameters.

  % Axiom mRec.
  M_ = M(),

  % Delete vars with NS.

  Ctx = clean_ns(get_ctx(Env), unwrap_value(get_ns(Env))),
  L_ = set_env(L, set_ctx(Env, Ctx)),


%%  {true, {{PdId, mRecccc, tau, L, copy_ctx(L, M_)}, copy_ctx(L, M_)}};
  {true, {{PdId, ?M_REC, tau, L, copy_ctx(L_, M_)}, copy_ctx(L_, M_)}};

derive_tau(L = {Op, Env, M, N}, PdId) when Op =:= 'and'; Op =:= 'or' ->

  ?DEBUG(":: (~s) Trying to reduce using rule mTauL: ~s.", [pdid_to_iolist(PdId), format_m(L)]),
%%  case derive_tau(copy_ctx(L, M), new_pdid(PdId)) of
  case derive_tau(copy_ns(L, copy_ctx(L, M)), new_pdid(PdId)) of
    false ->
      ?DEBUG(":: (~s) Trying to reduce using rule mTauR: ~s.", [pdid_to_iolist(PdId), format_m(L)]),
%%      case derive_tau(copy_ctx(L, N), new_pdid(PdId)) of
      case derive_tau(copy_ns(L, copy_ctx(L, N)), new_pdid(PdId)) of
        false ->
          ?DEBUG(":: (~s) Unable to reduce futher using tau: ~s.", [pdid_to_iolist(PdId), format_m(L)]),
          false;
        {true, {PdN_, N_}} ->

          % Rule mTauR.
          {true, {{PdId, ?M_TAU_R, tau, L, copy_ns(L, copy_ctx(L, M)), N_, {pre, PdN_}}, {Op, Env, M, N_}}}
%%          {true, {{PdId, mTauR, tau, L, copy_ns(L, copy_ctx(L, M)), N_, {pre, PdN_}}, {Op, {env, [{str, "TAUR"}]}, M, N_}}}
      end;
    {true, {PdM_, M_}} ->

      % Rule mTauL.
      {true, {{PdId, ?M_TAU_L, tau, L, M_, copy_ns(L, copy_ctx(L, N)), {pre, PdM_}}, {Op, Env, M_, N}}}
%%      {true, {{PdId, mTauL, tau, L, M_, copy_ns(L, copy_ctx(L, N)), {pre, PdM_}}, {Op, {env, [{str, "TAUL"}]}, M_, N}}}
  end;

derive_tau(_, _) ->

  % The monitor cannot transition internally on tau actions.
  false.

%%% @doc Determines the rule that must be applied to reduce the monitor state by
%%%      one trace event.
%%%
%%% {@params
%%%   {@name Event}
%%%   {@desc Trace event to analyze.}
%%%   {@name M}
%%%   {@desc Monitor to be reduced.}
%%%   {@name PdId}
%%%   {@desc Proof derivation ID.}
%%% }
%%%
%%% {@returns Proof derivation and monitor continuation after one event
%%%           reduction.
%%% }
-spec derive_event(Event, M, PdId) -> {pd(), monitor()}
  when
  Event :: event(),
  M :: monitor(),
  PdId :: pd_id().
derive_event(Event, M = {V, _}, PdId) when V =:= yes; V =:= no ->
  ?assertNot(Event =:= tau),
  ?DEBUG(":: (~s) Reducing using axiom mVrd: ~s.", [pdid_to_iolist(PdId), format_m(M)]),

  % Axiom mVrd.
  {{PdId, ?M_VRD, Event, M, M}, M};

derive_event(Event, L = {act, Env, C, M}, PdId) ->
  ?assertNot(Event =:= tau),
  ?assert(C(Event)),
  ?assert(is_function(M, 1)),

  % Get the variable binder associated with this action.
  Binder = unwrap_value(get_var(Env)),

  % Instantiate binder with data from action and extend the variable context.
  % This is used for debugging purposes, to track the flow of data values in the
  % monitor and its continuation.

  Ns = get_ns(Env),
  L_ = set_env(L, set_ctx(Env, new_binding(get_ctx(Env), unwrap_value(Ns), Binder, Event))),

  ?DEBUG(":: (~s) Reducing using rule mAct: ~s.", [pdid_to_iolist(PdId), format_m(L_)]),


  % Axiom mAct.
  M_ = M(Event),
  ?assertNot(is_function(M_)),

%%  M__ = set_ns()

  % The environment of M cannot be updated prior to applying M to Act, since M
  % is a function. Once M is applied, the new variable binding acquired during
  % the analysis of Act can be passed down to the unwrapped monitor by updating
  % its environment.

%%  NewM = copy_ctx(MMM, M_),
%%  NewM = copy_ctx(L_, M_),


%%  {{PdId, mAct, Act, {act, NewEnv}}, NewM}; % Updated monitor env.
%%  {{PdId, mAct, Act, MMM}, NewM}; % Updated monitor env.
%%  {{PdId, mAct, Act, L_}, M_}; % Updated monitor env.
%%  {{PdId, mAct, Act, L_}, copy_ctx(L_, M_)}; % Updated monitor env.

%%  {{PdId, mAct, Act, L, copy_ctx(L_, M_)}, copy_ctx(L_, M_)}; % Updated monitor env.
  {{PdId, ?M_ACT, Event, L, copy_ns(L_, copy_ctx(L_, M_))}, copy_ns(L_, copy_ctx(L_, M_))}; % Updated monitor env.

derive_event(Event, L = {chs, _, M, N}, PdId) ->
  ?assert(is_tuple(M) andalso element(1, M) =:= act),
  ?assert(is_tuple(N) andalso element(1, N) =:= act),

  case {is_satisfied(Event, M), is_satisfied(Event, N)} of
    {true, false} ->
      ?DEBUG(":: (~s) Reducing using rule mChsL: ~s.", [pdid_to_iolist(PdId), format_m(L)]),

      % Rule mChsL.
      {PdM_, M_} = derive_event(Event, copy_ns(L, copy_ctx(L, M)), new_pdid(PdId)),
%%      {{PdId, mChsL, Act, L, {pre, PdM_}}, M_};
      {{PdId, ?M_CHS_L, Event, L, M_, {pre, PdM_}}, M_};
%%      {{PdId, mChsL, Act, copy_ctx(M_, L), {pre, PdM_}}, M_};
%%      {{PdId, mChsL, Act, M_, {pre, PdM_}}, M_};

    {false, true} ->
      ?DEBUG(":: (~s) Reducing using rule mChsR: ~s.", [pdid_to_iolist(PdId), format_m(L)]),

      % Rule mChsR.
      {PdN_, N_} = derive_event(Event, copy_ns(L, copy_ctx(L, N)), new_pdid(PdId)),
%%      {{PdId, mChsR, Act, L, {pre, PdN_}}, N_}
      {{PdId, ?M_CHS_R, Event, L, N_, {pre, PdN_}}, N_}
%%      {{PdId, mChsR, Act, copy_ctx(N_, L), {pre, PdN_}}, N_}
  end;

derive_event(Event, L = {Op, Env, M, N}, PdId) when Op =:= 'and'; Op =:= 'or' ->
  ?assertNot(Event =:= tau),
  ?DEBUG(":: (~s) Reducing using rule mPar: ~s.", [pdid_to_iolist(PdId), format_m(L)]),

  % Unfold respective sub-monitors. Proof derivation ID for second monitor N is
  % incremented accordingly.
  {PdM_, M_} = derive_event(Event, copy_ns(L, copy_ctx(L, M)), new_pdid(PdId)),
  {PdN_, N_} = derive_event(Event, copy_ns(L, copy_ctx(L, N)), inc_pdid(new_pdid(PdId))),

  % Merge context of M and N monitors.
  Ctx = merge_ctx(get_ctx(get_env(M_)), get_ctx(get_env(N_))),
  Env_ = set_ctx(Env, Ctx),


%%  {{PdId, mPar, Act, L, M_, N_, {pre, PdM_}, {pre, PdN_}}, {Op, Env, M_, N_}}.
  {{PdId, ?M_PAR, Event, L, M_, N_, {pre, PdM_}, {pre, PdN_}}, {Op, Env_, M_, N_}}.
%%  {{PdId, mPar, Act, L, M_, N_, {pre, PdM_}, {pre, PdN_}}, {Op, Env, M_, N_}}.
%%  {{PdId, mPar, Act, L, M_, N_, {pre, PdM_}, {pre, PdN_}}, {Op, get_env(N_), M_, N_}}. % Use context of N_ ?
%%  {{PdId, mPar, Act, L, {pre, PdM_}, {pre, PdN_}}, {Op, Env, M_, N_}}.
%%  {{PdId, mPar, Act, set_env(L, Env_), {pre, PdM_}, {pre, PdN_}}, {Op, Env, M_, N_}}.


reduce_tau(M, PdList) ->
  ?TRACE("[ Attempting new derivation for monitor on internal action 'tau' ]"),

  case derive_tau(M, new_pdid([])) of
    false ->

      % No more tau reductions.
      {PdList, M};
    {true, {PdM, M_}} ->

      % Monitor state reduced by one tau transition. Attempt to reduce further.
      reduce_tau(M_, [PdM | PdList])
  end.

% Assumes that the monitor is already in a ready state.
analyze(Event, M, PdList) ->
  ?TRACE("[ Starting new derivation for monitor on event '~w' ]", [Event]),

  % Analyze trace event.
  {PdM, M_} = derive_event(Event, M, new_pdid([])),

  % Check whether the residual monitor state can be reduced further using tau
  % transitions. This ensures that the monitor is always left in a state where
  % it is ready to analyse the next action.
  reduce_tau(M_, [PdM | PdList]).





analyze_trace(Trace, M) when is_list(Trace) ->
  {PdList_, M_} = reduce_tau(M, []),
  analyze_trace(Trace, M_, PdList_).

analyze_trace([], M, PdList) ->
  {PdList, M};

analyze_trace([Event | Trace], M, PdList) ->
  {PdList_, M_} = analyze(Event, M, PdList),
  analyze_trace(Trace, M_, PdList_).


%%% ----------------------------------------------------------------------------
%%% Private helper functions.
%%% ----------------------------------------------------------------------------

%%% @private Determines whether the monitor constraint is satisfied by the trace
%%%          event.
is_satisfied(Event, {act, _, C, _M}) ->
  ?assert(is_function(_M, 1)),
  C(Event).


%%% ----------------------------------------------------------------------------
%%% Monitor environment management functions.
%%% ----------------------------------------------------------------------------

%%% @private Returns the value mapped to the specified key from the provided
%%%          list. If the key is not found, the default value settles the return
%%%          value: when default is false, false is returned, otherwise the pair
%%%          {key, default value} is returned.
-spec get_key(Key, List, Default) -> false | {Key, any()}
  when
  Key :: any(),
  List :: list(),
  Default :: false | {any(), any()}.
get_key(Key, List, false) ->
  lists:keyfind(Key, 1, List);
get_key(Key, List, {true, Default}) ->
  case get_key(Key, List, false) of
    false ->
      {Key, Default};
    Pair = {Key, _} ->
      Pair
  end.

%%% @private Adds the specified key-value pair to the list.
-spec put_key(Key, Value, List) -> list()
  when
  Key :: any(),
  Value :: any(),
  List :: list().
put_key(Key, Value, List) ->
  lists:keystore(Key, 1, List, {Key, Value}).

%%% @private Returns the environment associated with the current monitor state.
-spec get_env(M :: monitor()) -> env().
get_env(M) when is_tuple(M), tuple_size(M) > 1 ->
  {env, _} = element(2, M).

%%% @private Overwrites the environment of the specified monitor with the new
%%%          one.
-spec set_env(M :: monitor(), Env :: env()) -> monitor().
set_env(M, {env, Env}) when is_tuple(M), tuple_size(M) > 1, is_list(Env) ->
  setelement(2, M, {env, Env}).

%%% @private Returns the string from the specified environment.
-spec get_str(Env :: env()) -> str().
get_str({?KEY_ENV, Env}) when is_list(Env) ->
  get_key(?KEY_STR, Env, false).

%%% @private Returns the variable from the specified environment.
-spec get_var(Env :: env()) -> var().
get_var({?KEY_ENV, Env}) when is_list(Env) ->
  get_key(?KEY_VAR, Env, false).

%%% @private Returns the event pattern from the specified environment.
-spec get_pat(Env :: env()) -> pat().
get_pat({?KEY_ENV, Env}) when is_list(Env) ->
  get_key(?KEY_PAT, Env, false).

%%% @private Returns the existing variable binding context or a fresh one if it
%%%          does not exist.
-spec get_ctx(Env :: env()) -> ctx().
get_ctx({?KEY_ENV, Env}) when is_list(Env) ->
  get_key(?KEY_CTX, Env, {true, []}).

%%% @private Overwrites the variable binding context in the specified monitor
%%%          environment with the new one.
-spec set_ctx(Env :: env(), Ctx :: ctx()) -> env().
set_ctx({?KEY_ENV, Env}, {ctx, Ctx}) when is_list(Env), is_list(Ctx) ->
  {?KEY_ENV, put_key(?KEY_CTX, Ctx, Env)}.

%%% @private Copies the variable binding context from the environment of `From`
%%%          to `To`. Any variable bindings in the target context `To` are
%%%          discarded.
-spec copy_ctx(From :: monitor(), To :: monitor()) -> monitor().
copy_ctx(From, To) ->
  EnvTo = set_ctx(get_env(To), get_ctx(get_env(From))),
  set_env(To, EnvTo).

%%% @private Merges the specified variable binding contexts into a new one. In
%%%          case of duplicate variable names, the bindings in the second
%%%          context `Ctx2` are preferred, and the ones in `Ctx1` are
%%%          overwritten.
-spec merge_ctx(Ctx1 :: ctx(), Ctx2 :: ctx()) -> ctx().
merge_ctx({?KEY_CTX, Ctx1}, {?KEY_CTX, Ctx2}) ->
  {?KEY_CTX, lists:foldr(
    fun(Mapping = {Name, _}, Acc) ->
      case get_key(Name, Acc, false) of
        false ->
          [Mapping | Acc];
        {Name, _} ->
          Acc
      end
    end, Ctx2, Ctx1)}.

%%% @private Creates a new variable binding and value under the specified
%%%          namespace in the specified variable binding context.
-spec new_binding(Ctx, Ns, Name, Value) -> ctx()
  when
  Ctx :: ctx(),
  Ns :: ns(),
  Name :: atom(),
  Value :: any().
new_binding({?KEY_CTX, Ctx}, Ns, Name, Value) when is_list(Ctx) ->
  {?KEY_CTX, put_key({Ns, Name}, Value, Ctx)}.

%%% @private Purges all variable bindings under the specified namespace from the
%%%          specified variable binding context.
-spec clean_ns(Ctx :: ctx(), Ns :: ns()) -> ctx().
clean_ns({?KEY_CTX, []}, _) ->
  {?KEY_CTX, []};
clean_ns({?KEY_CTX, [{{Ns, _}, _} | Bindings]}, Ns) ->
  clean_ns({?KEY_CTX, Bindings}, Ns);
clean_ns({?KEY_CTX, [Binding = {{_, _}, _} | Bindings]}, Ns) ->
  {?KEY_CTX, Bindings_} = clean_ns({?KEY_CTX, Bindings}, Ns),
  {?KEY_CTX, [Binding | Bindings_]}.

%%% @private Returns the existing namespace or the global one if it does not
%%%          exist.
-spec get_ns(Env :: env()) -> ns().
get_ns({?KEY_ENV, Env}) ->
  get_key(?KEY_NS, Env, {true, global}).

%%% @private Overwrites the namespace in the specified monitor environment with
%%%          the new one.
-spec set_ns(Env :: env(), Ns :: ns()) -> env().
set_ns({?KEY_ENV, Env}, {ns, Ns}) ->
  {?KEY_ENV, put_key(ns, Ns, Env)}.

%%% @private Copies the namespace from the environment of `From` to `To`. The
%%%          existing namespace is overwritten.
-spec copy_ns(From :: monitor(), To :: monitor()) -> env().
copy_ns(From, To) ->
  EnvTo = set_ns(get_env(To), get_ns(get_env(From))),
  set_env(To, EnvTo).

%%% @private Returns the value element of the specified tagged tuple.
-spec unwrap_value(Pair :: {atom(), any()}) -> any().
unwrap_value({_, Value}) ->
  Value;

unwrap_value(Any) ->
  io:format("The unwrapped value is : ~p~n", [Any]),
  ok.

%%% ----------------------------------------------------------------------------
%%% Monitor and proof derivation display functions.
%%% ----------------------------------------------------------------------------

% This relies on the fact that the derivation algorithm copies the context from
% one monitor continuation to the other so inherit it. But since we are printing
% a monitor that has not been reduce, we need to pass the context to the
% continuation which has not been yet unfolded.
%%m_to_iolist(M) ->
%%
%%  % Pass variable context of monitor so that monitors containing free variables
%%  % are correctly stringified.
%%  {ctx, Ctx} = get_ctx(get_env(M)),
%%  m_to_iolist(M, [{Name, Value} || {{_, Name}, Value} <- Ctx]).
%%
%%m_to_iolist({yes, Env = {env, _}}, _) ->
%%  unwrap_value(get_str(Env));
%%m_to_iolist({no, Env = {env, _}}, _) ->
%%  unwrap_value(get_str(Env));
%%m_to_iolist({var, Env = {env, _}, _}, _) ->
%%  unwrap_value(get_str(Env));
%%m_to_iolist({act, Env = {env, _}, _, M}, Ctx) ->
%%
%%  % The continuation of an action is a function. In order to stringify the rest
%%  % of the monitor, apply the function to unfold it. Action functions accept a
%%  % single parameter.
%%  M_ = M(undef),
%%  [lin_7:format_ph(unwrap_value(get_str(Env)), Ctx), $., m_to_iolist(M_, Ctx)];
%%m_to_iolist({chs, Env = {env, _}, M, N}, Ctx) ->
%%  [$(, m_to_iolist(M, Ctx), $ , unwrap_value(get_str(Env)), $ , m_to_iolist(N, Ctx), $)];
%%m_to_iolist({'or', Env = {env, _}, M, N}, Ctx) ->
%%  [m_to_iolist(M, Ctx), $ , unwrap_value(get_str(Env)), $ , m_to_iolist(N, Ctx)];
%%m_to_iolist({'and', Env = {env, _}, M, N}, Ctx) ->
%%  [m_to_iolist(M, Ctx), $ , unwrap_value(get_str(Env)), $ , m_to_iolist(N, Ctx)];
%%m_to_iolist({rec, Env = {env, _}, M}, Ctx) ->
%%
%%  % The continuation of a recursive construct is encoded in terms of a function
%%  % that needs to be applied to unfold the monitor before stringifying it.
%%  % Recursive monitor definitions do not accept parameters.
%%  [unwrap_value(get_str(Env)), m_to_iolist(M(), Ctx)].


%%% @private Extends the current proof derivation ID with a new sub-derivation.
-spec new_pdid(Id :: list(integer())) -> list(integer()).
new_pdid(Id) when is_list(Id) ->
  [1 | Id].

%%% @private Increments the ID of the current proof derivation.
-spec inc_pdid(Id :: list(integer())) -> list(integer()).
inc_pdid([Idx | Idxs]) ->
  [Idx + 1 | Idxs].

%%% @private Returns the proof derivation ID as an IoList where each derivation
%%%          index is period-separated.
-spec pdid_to_iolist(Id :: list(integer())) -> iolist().
pdid_to_iolist(Id = [_ | _]) ->
  tl(lists:foldl(fun(Idx, Id) -> [$., integer_to_list(Idx) | Id] end, [], Id)).








format_m(M) ->
  {ctx, Ctx} = get_ctx(get_env(M)),
  Vars = [{Name, Value} || {{_, Name}, Value} <- Ctx],
  lists:flatten(io_lib:format("~s \e[0;33msub([\e[0m \e[37m~s\e[0m\e[0;33m])\e[0m", [format_m(M, Vars),
    [io_lib:format("~s=~w ", [Name, Value]) || {Name, Value} <- Vars]])).


format_m({yes, Env = {env, _}}, _) ->
  unwrap_value(get_str(Env));
format_m({no, Env = {env, _}}, _) ->
  unwrap_value(get_str(Env));
format_m({var, Env = {env, _}, _}, _) ->
  unwrap_value(get_str(Env));
format_m({act, Env = {env, _}, _, M}, Ctx) ->

  % Unfold continuation monitor body for act using dummy data. This data will
  % not interfere with constraints since there are no constraints associated
  % with the continuation body, but only with the action guard test.
  M_ = M(unwrap_value(get_pat(Env))),

%%  [format_ph(unwrap_value(get_str(Env)), Ctx), $., format_m(M_, Ctx)];
%%  [format_ph(re:replace(unwrap_value(get_str(Env)), " when ", ","), Ctx), $., format_m(M_, Ctx)];
  [re:replace(unwrap_value(get_str(Env)), " when ", ","), $., format_m(M_, Ctx)];
format_m({chs, Env = {env, _}, M, N}, Ctx) ->
  [$(, format_m(M, Ctx), $ , unwrap_value(get_str(Env)), $ , format_m(N, Ctx), $)];
format_m({'or', Env = {env, _}, M, N}, Ctx) ->
  [format_m(M, Ctx), $ , unwrap_value(get_str(Env)), $ , format_m(N, Ctx)];
format_m({'and', Env = {env, _}, M, N}, Ctx) ->
  [format_m(M, Ctx), $ , unwrap_value(get_str(Env)), $ , format_m(N, Ctx)];
format_m({rec, Env = {env, _}, M}, Ctx) ->
  [unwrap_value(get_str(Env)), format_m(M(), Ctx)].


%%% ----------

format_pdlist(PdList) ->
  lists:foldl(
    fun(Pd, {I, IoList}) ->
      {I - 1, [[io_lib:format("~n\e[4;32mDerivation ~w:\e[0m~n", [I]), format_pd(Pd)] | IoList]}
    end,
    {length(PdList), []}, PdList
  ).

show_pdlist(PdList) ->
  {_, IoList} = format_pdlist(PdList),
  io:format("~s~n", [IoList]).




format_pd({PdId, Rule, Act, M, M_}) ->
  Indent = length(PdId) + length(?PD_SEP),
  io_lib:format("~*s [~s, \e[1;36maxiom ~s\e[0m] ~s~n\e[0;36m~*s-(~w)->\e[0m~n~*s~s~n",
    [Indent, ?PD_SEP, pdid_to_iolist(PdId), Rule, format_m(M), Indent + 1, "", Act, Indent + 1, "", format_m(M_)]
%%    [Indent, ?PD_SEP, str_pdid(PdId), Rule, format_m2(M), Indent + 1, "", Act, Indent + 1, "", format_m2(M_)]
  );




format_pd({PdId, Rule, Act, M, M_, {pre, PdM}}) -> % mChs
  PdMFmt = format_pd(PdM),
  Indent = length(PdId) + length(?PD_SEP),
  [io_lib:format("~*s [~s, \e[1;36mrule ~s\e[0m] ~s~n\e[0;36m~*s-(~w)->\e[0m~n~*s~s~n",
    [Indent, ?PD_SEP, pdid_to_iolist(PdId), Rule, format_m(M), Indent + 1, "", Act, Indent + 1, "", format_m(M_)])
%%    [Indent, ?PD_SEP, str_pdid(PdId), Rule, format_m2(M), Indent + 1, "", Act, Indent + 1, "", format_m2(M_)])
    | PdMFmt
  ];

format_pd({PdId, Rule, Act, M, M_, N_, {pre, PdM}}) -> % mTauL and mTauR
  PdMFmt = format_pd(PdM),
  Indent = length(PdId) + length(?PD_SEP),
  [io_lib:format("~*s [~s, \e[1;36mrule ~s\e[0m] ~s~n\e[0;36m~*s-(~w)->\e[0m~n~*s ~s ~s ~s~n",
    [length(PdId) + 1, "-", pdid_to_iolist(PdId), Rule, format_m(M), Indent + 1, "", Act, Indent + 1, "", format_m(M_), unwrap_value(get_str(get_env(M))), format_m(N_)])
%%    [length(PdId) + 1, "-", str_pdid(PdId), Rule, format_m2(M), Indent + 1, "", Act, Indent + 1, "", format_m2(M_), unwrap_value(get_str(get_env(M))), format_m2(N_)])
    | PdMFmt
  ];


format_pd({PdId, Rule, Act, M, M_, N_, {pre, PdM}, {pre, PdN}}) ->
  {PdMFmt, PdNFmt} = {format_pd(PdM), format_pd(PdN)},
  Indent = length(PdId) + length(?PD_SEP),
  [
    [
      io_lib:format("~*s [~s, \e[1;36mrule ~s\e[0m] ~s~n\e[0;36m~*s-(~w)->\e[0m~n~*s~s ~s ~s~n",
        [length(PdId) + 1, "-", pdid_to_iolist(PdId), Rule, format_m(M), Indent + 1, "", Act, Indent + 1, "", format_m(M_), unwrap_value(get_str(get_env(M))), format_m(N_)])
%%        [length(PdId) + 1, "-", str_pdid(PdId), Rule, format_m2(M), Indent + 1, "", Act, Indent + 1, "", format_m2(M_), unwrap_value(get_str(get_env(M))), format_m2(N_)])
      | PdMFmt
    ]
    | PdNFmt
  ].


%%% ----------------------------------------------------------------------------
%%% Monitor instrumentation functions.
%%% ----------------------------------------------------------------------------

%% TODO: Used by the instrumenter.
%% @doc Embeds the trace event analysis function into the process dictionary.
%%
%% {@params
%%   {@name M}
%%   {@desc Monitor function that is applied to trace events to determine their
%%          correct or incorrect sequence.
%%   }
%% }
%%
%% {@returns `true' to indicate success, otherwise `false'.}
-spec embed(M :: monitor()) -> true.
embed(M) ->
  ?TRACE("Embedding monitor in ~w.", [self()]),

  % Reduce monitor internally until it is in a state where it can analyze the
  % next trace event.
  {PdList_, M_} = reduce_tau(M, []),
  undefined =:= put(?MONITOR, {PdList_, M_}).


%% @doc Dispatches the specified abstract event to the monitor for analysis.
%%
%% {@params
%%   {@name Event}
%%   {@desc The abstract event that the monitor is to analyze.}
%% }
%%
%% {@returns Depends on the event type. See {@link event:event/0}.
%%           {@ul
%%             {@item When event is of type `fork', the PID of the new child
%%                    process is returned;
%%             }
%%             {@item When event is of type `init', the PID of the parent
%%                    process is returned;
%%             }
%%             {@item When event is of type `exit', the exit reason is
%%                    returned;
%%             }
%%             {@item When event is of type `send', the message is returned;}
%%             {@item When event is of type `recv', the message is returned.}
%%           }
%% }
-spec dispatch(Event :: event:int_event()) -> term().
dispatch(Event = {fork, _Parent, Child, _Mfa}) ->
  do_monitor(event:to_evm_event(Event),
    fun(Verdict, PdList) ->
      format_verdict("Reached after analyzing event ~w.~n", [Event], Verdict)
    end
  ),
  Child;
dispatch(Event = {init, _Child, Parent, _Mfa}) ->
  do_monitor(event:to_evm_event(Event),
    fun(Verdict, PdList) ->
      format_verdict("Reached after analyzing event ~w.~n", [Event], Verdict)
    end
  ),
  Parent;
dispatch(Event = {exit, _Process, Reason}) ->
  do_monitor(event:to_evm_event(Event),
    fun(Verdict, PdList) ->
      format_verdict("Reached after analyzing event ~w.~n", [Event], Verdict)
    end
  ),
  Reason;
dispatch(Event = {send, _Sender, _Receiver, Msg}) ->
  do_monitor(event:to_evm_event(Event),
    fun(Verdict, PdList) ->
      format_verdict("Reached after analyzing event ~w.~n", [Event], Verdict)
    end
  ),
  Msg;
dispatch(Event = {recv, _Receiver, Msg}) ->
  do_monitor(event:to_evm_event(Event),
    fun(Verdict, PdList) ->
      format_verdict("Reached after analyzing event ~w.~n", [Event], Verdict)
    end
  ),
  Msg.

%% @doc Retrieves the monitor function stored in the process dictionary (if
%% any), and applies it on the event. The result is put back in the process
%% dictionary. If a verdict state is reached, the callback function is invoked,
%% otherwise nothing is done. When no monitor function is stored inside the
%% process dictionary (i.e. meaning that the process is not monitored), the atom
%% `undefined' is returned.
%%-spec do_monitor(Event, VerdictFun) -> monitor() | undefined
%%  when
%%  Event :: event:evm_event(),
%%  VerdictFun :: fun((Verdict :: verdict()) -> any()).
do_monitor(Event, VerdictFun) when is_function(VerdictFun, 2) ->
  case get(?MONITOR) of
    undefined ->
      ?TRACE("Analyzer undefined; discarding trace event ~w.", [Event]),
      undefined;
    {PdList, M} ->

      % Analyze event. At this point, monitor might have reached a verdict.
      % Check whether verdict is reached to enable immediate detection, should
      % this be the case.
%%      put(?MONITOR, Monitor0 = analyze(M, Event)),
      put(?MONITOR, {PdList_, M_} = analyze(Event, M, PdList)),
      case is_verdict(M_) of
        true ->
%%          {V, _} = M_,
          VerdictFun(M_, PdList_);
        false ->
          ok
      end,
      M_
  end.

%% @doc Default filter that allows all events to pass.
-spec filter(Event :: event:int_event()) -> true.
filter(_) ->
  true. % True = keep event.

%% @private Determines whether the specified monitor is indeed a verdict.
-spec is_verdict(V :: {?VERDICT_YES | ?VERDICT_NO, env()}) -> boolean().
is_verdict({V, _}) when V =:= ?VERDICT_YES; V =:= ?VERDICT_NO ->
  true;
is_verdict(_) ->
  false.

format_verdict(Fmt, Args, {no, _}) ->
  io:format(lists:flatten(["\e[1;31m:: Violation: ", Fmt, "\e[0m"]), Args);
format_verdict(Fmt, Args, {yes, _}) ->
  io:format(lists:flatten(["\e[1;32m:: Satisfaction: ", Fmt, "\e[0m"]), Args).

%% Tests.
%%{ok, M} = lin_7:m5().
%% lin_analyzer:embed(M).
%% lin_analyzer:dispatch({send, self(), self(), {1,3}}).
%% lin_analyzer:dispatch({send, self(), self(), {6,1}}).
%% lin_analyzer:dispatch({send, self(), self(), {2,2}}).

%% lin_analyzer:analyze_trace([{trace, self(), send, {1, 3}, self()}, {trace, self(), send, {2, 2}, self()}], M).

%% 1. lin_weaver:weave_file("/Users/duncan/Dropbox/PhD/Development/detecter/detecter/src/synthesis/calc_server.erl", fun prop_add_rec:mfa_spec/1, [{outdir, "/Users/duncan/Dropbox/PhD/Development/detecter/detecter/ebin"}]).
%% 2. calc_server:start(10).
%% 3. Pid ! {add, 1, 2}.


