-module(pg_convert).
-include_lib("eunit/include/eunit.hrl").

-type rule_tag() :: atom().
-type from_model_name() :: atom().
-type result_key() :: atom().
-type from_key() :: atom().
-type convert_action() :: from_key()
| {static, any()}
| {element, non_neg_integer(), from_key()}
| {fun(), []}
| {fun(), [from_key()]}
| {tuple, [from_key()]}.
-type op_step() :: {result_key(), convert_action()}.
-type op_steps() :: [op_step()].
-type convert_op() :: {from_model_name(), op_steps()}.
-type convert_ops() :: [convert_op()].
-type convert_rule() :: {rule_tag(), convert_ops()}.
-type convert_rules() :: [convert_rule()].

-export_type([convert_rules/0]).

%% callbacks
-callback convert_config() -> convert_rules().

%% API exports
-export([
  convert/2
  , convert/3
]).

-define(TEST_PROTOCOL, pg_convert_t_protocol_up_resp_pay).
-define(APP, pg_convert).
%%====================================================================
%% API functions
%%====================================================================

%%----------------------------------------------
-spec convert(MTo, MFrom) -> ModelNew when
  MTo :: atom(),
  MFrom :: pg_model:pg_model() | [pg_model:pg_model()],
  ModelNew :: pg_model:pg_model().
convert(MTo, MFrom) when is_atom(MTo), is_tuple(MFrom) ->
  convert(MTo, [MFrom], default);
convert(MTo, MFromList) when is_atom(MTo), is_list(MFromList) ->
  convert(MTo, MFromList, default).


-spec convert(MTo, MFromList, ConfigItemName) -> ModelNew when
  MTo :: atom(),
  MFromList :: [pg_model:pg_model()],
  ConfigItemName :: atom(),
  ModelNew :: pg_model:pg_model().

convert(MTo, Model, ConfigItemName) when is_atom(MTo), is_tuple(Model), is_atom(ConfigItemName) ->
  convert(MTo, [Model], ConfigItemName);
convert(MTo, ModelList, ConfigItemName) when is_atom(MTo), is_list(ModelList), is_atom(ConfigItemName) ->
  Config = MTo:convert_config(),
  RuleList = proplists:get_value(ConfigItemName, Config),
  xfutils:cond_lager(pg_convert, debug, error, "RuleList = ~p", [RuleList]),
  xfutils:cond_lager(pg_convert, debug, error, "ModelList=~p", [ModelList]),


  MToReal = proplists:get_value(to, RuleList, MTo),
  RuleFrom = proplists:get_value(from, RuleList),

  true = length(ModelList) =:= length(RuleFrom),

  FConvertOneModel =
    fun(I, Acc) ->
      {MFromUse, MModelUse, RuleUse} =
        case lists:nth(I, RuleFrom) of
          {MFrom, MModel, Rule} ->
            {MFrom, MModel, Rule};
          {MModel, Rule} ->
            %% default pg_model
            {pg_model, MModel, Rule}
        end,
      VL = do_convert(MFromUse, MModelUse, RuleUse, lists:nth(I, ModelList)),
      VL ++ Acc
    end,

  VL = lists:foldl(FConvertOneModel, [], lists:seq(1, length(ModelList))),


  pg_model:new(MToReal, VL).

%%-------------------------------------------------------------------
do_convert(MFrom, MModel, Rule, Model) when is_atom(MFrom), is_atom(MModel), is_list(Rule), is_tuple(Model) ->
  F =
    fun(OpTuple, Acc) ->
      do_convert_one_op(MFrom, MModel, Model, OpTuple, Acc)
    end,
  VL = lists:foldl(F, [], Rule),
  VL.

do_convert_test() ->
  Protocol = pg_model:new(?TEST_PROTOCOL, [{encoding, {a, b, c}}]),

  R1 = [
    {t1, version}
    , {t2, {static, 333}}
    , {t3, {element, 3, encoding}}
    , {t4, {fun t1/0, []}}
    , {t5, {fun t3/1, [version]}}
    , {t6, {tuple, [encoding, version]}}
  ],
  ?assertEqual(
    lists:reverse([
      {t1, <<"5.0.0">>}
      , {t2, 333}
      , {t3, c}
      , {t4, <<"test">>}
      , {t5, <<"5.0.0hello">>}
      , {t6, {{a, b, c}, <<"5.0.0">>}}
    ]),
    do_convert(pg_model, ?TEST_PROTOCOL, R1, Protocol)),
  ok.


do_convert_one_op(M, MModel, Model, {KeyTo, KeyFrom}, AccIn)
  when is_atom(M), is_atom(KeyTo), is_atom(KeyFrom), is_list(AccIn) ->
  Value = M:get(MModel, Model, KeyFrom),
  [{KeyTo, Value} | AccIn];
do_convert_one_op(M, _, _Model, {KeyTo, {static, Value}}, AccIn)
  when is_atom(M), is_atom(KeyTo), is_list(AccIn) ->
  [{KeyTo, Value} | AccIn];
do_convert_one_op(M, MModel, Model, {KeyTo, {element, N, KeyFrom}}, AccIn)
  when is_atom(M), is_atom(KeyTo), is_list(AccIn) ->
  Value = M:get(MModel, Model, KeyFrom),
  [{KeyTo, element(N, Value)} | AccIn];
do_convert_one_op(M, _, _Model, {KeyTo, {Fun, []}}, AccIn)
  when is_atom(M), is_atom(KeyTo), is_function(Fun), is_list(AccIn) ->
  Value = Fun(),
  [{KeyTo, Value} | AccIn];
do_convert_one_op(M, MModel, Model, {KeyTo, {Fun, KeyFromList}}, AccIn)
  when is_atom(M), is_atom(KeyTo), is_function(Fun), is_list(KeyFromList), is_list(AccIn) ->
  VL = [M:get(MModel, Model, Key) || Key <- KeyFromList],
  Value = apply(Fun, VL),
  [{KeyTo, Value} | AccIn];
do_convert_one_op(M, MModel, Model, {KeyTo, {tuple, KeyFromList}}, AccIn)
  when is_atom(M), is_atom(KeyTo), is_list(KeyFromList), is_list(AccIn) ->
  VL = [M:get(MModel, Model, Key) || Key <- KeyFromList],
  [{KeyTo, list_to_tuple(VL)} | AccIn].

do_convert_one_op_test() ->
  Protocol = pg_model:new(?TEST_PROTOCOL, [{encoding, {a, b, c}}]),
  ?assertEqual([{test, <<"5.0.0">>}, aa],
    do_convert_one_op(pg_model, ?TEST_PROTOCOL, Protocol, {test, version}, [aa])),

  ?assertEqual([{test, 444}, aa],
    do_convert_one_op(pg_model, ?TEST_PROTOCOL, Protocol, {test, {static, 444}}, [aa])),

  ?assertEqual([{test, a}, aa],
    do_convert_one_op(pg_model, ?TEST_PROTOCOL, Protocol, {test, {element, 1, encoding}}, [aa])),
  ?assertEqual([{test, c}, aa],
    do_convert_one_op(pg_model, ?TEST_PROTOCOL, Protocol, {test, {element, 3, encoding}}, [aa])),

  ?assertEqual([{test, <<"test">>}, aa],
    do_convert_one_op(pg_model, ?TEST_PROTOCOL, Protocol, {test, {fun t1/0, []}}, [aa])),

  ?assertEqual([{test, <<"5.0.0hello">>}, aa],
    do_convert_one_op(pg_model, ?TEST_PROTOCOL, Protocol, {test, {fun t3/1, [version]}}, [aa])),

  ?assertEqual([{test, {<<"5.0.0">>, {a, b, c}}}, aa],
    do_convert_one_op(pg_model, ?TEST_PROTOCOL, Protocol, {test, {tuple, [version, encoding]}}, [aa])),
  ok.

t1() ->
  <<"test">>.

t3(V) ->
  <<V/binary, "hello">>.
%%====================================================================
%% Internal functions
%%====================================================================
