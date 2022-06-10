-module(ehttpd_rest_check).
-export([check_request/2, check_response/3]).


check_request(Context, Req) ->
    Params = maps:get(check_request, Context, []),
    check_request_params(Params, Req, #{}).

check_response(Code, Context, Body) ->
    RtnParams = maps:get(check_response, Context, #{}),
    Schema = maps:get(Code, RtnParams, #{}),
    validate(schema, Schema, Body).


check_request_params([], Req, Model) ->
    {ok, Model, Req};
check_request_params([{Name, #{<<"in">> := <<"body">>} = Schema} | Acc], Req0, Model) ->
    {ok, Body, Req} = ehttpd_req:read_body(Req0),
    Params =
        try
            case jiffy:decode(Body, [return_maps]) of
                Items when is_list(Items) ->
                    Model#{
                        Name => Items
                    };
                Map when is_map(Map) ->
                    maps:merge(Model, Map)
            end
        catch
            _:_ ->
                #{Name => Body}
        end,
    ok = validate(schema, Schema, Params),
    check_request_params(Acc, Req, Params);
check_request_params([{Name, #{<<"in">> := Source} = Rules} | Acc], Req, Model) ->
    {Result, Req1} = ehttpd_req:get_value(Source, Name, Req),
    Value = prepare_param(Rules, Name, Result),
    NewModel = Model#{Name => Value},
    check_request_params(Acc, Req1, NewModel).


validate(Rule = {<<"type">>, <<"object">>}, Name, Value) ->
    case catch jiffy:decode(Value, [return_maps]) of
        Object when is_map(Object) ->
            {ok, Object};
        _ ->
            Err = <<"value:", Value/binary, " is not object.">>,
            validation_error(Rule, Name, Err)
    end;

validate(Rule = {<<"type">>, IntType}, Name, Value)
    when IntType == <<"number">>; IntType == <<"integer">> ->
    try
        case Value of
            _ when is_binary(Value) ->
                {ok, binary_to_integer(Value)};
            _ when is_list(Value) ->
                {ok, list_to_integer(Value)}
        end
    catch
        error:badarg ->
            Err = <<"value:", Value/binary, " is not integer.">>,
            validation_error(Rule, Name, Err)
    end;

validate(Rule = {<<"type">>, <<"float">>}, Name, Value) ->
    try
        Data = iolist_to_binary([Value]),
        case binary:split(Data, <<$.>>) of
            [Data] ->
                {ok, binary_to_integer(Data)};
            [<<>>, _] ->
                {ok, binary_to_float(<<$0, Data/binary>>)};
            _ ->
                {ok, binary_to_float(Data)}
        end
    catch
        error:badarg ->
            Err = <<"value:", Value/binary, " is not float.">>,
            validation_error(Rule, Name, Err)
    end;

validate(Rule = {<<"type">>, <<"binary">>}, Name, Value) ->
    case is_binary(Value) of
        true -> ok;
        false ->
            Err = <<"value:", Value/binary, " is not binary.">>,
            validation_error(Rule, Name, Err)
    end;

validate(Rule = {<<"type">>, <<"string">>}, Name, Value) ->
    case is_binary(Value) orelse is_list(Value) of
        true -> ok;
        false ->
            Err = <<"value:", Value/binary, " is not string.">>,
            validation_error(Rule, Name, Err)
    end;

validate(_Rule = {<<"type">>, <<"boolean">>}, _Name, Value) when is_boolean(Value) ->
    {ok, Value};

validate(Rule = {<<"type">>, <<"boolean">>}, Name, Value) ->
    Err = <<"value:", Value/binary, " is not boolean.">>,
    V = ehttpd_req:to_lower(Value),
    try
        case binary_to_existing_atom(V, utf8) of
            B when is_boolean(B) -> {ok, B};
            _ -> validation_error(Rule, Name, Err)
        end
    catch
        error:badarg ->
            validation_error(Rule, Name, Err)
    end;

validate(Rule = {<<"type">>, <<"date">>}, Name, Value) ->
    case is_binary(Value) of
        true -> ok;
        false ->
            Err = <<"value:", Value/binary, " is not date.">>,
            validation_error(Rule, Name, Err)
    end;

validate(Rule = {<<"type">>, <<"datetime">>}, Name, Value) ->
    case is_binary(Value) of
        true -> ok;
        false ->
            Err = <<"value:", Value/binary, " is not datetime.">>,
            validation_error(Rule, Name, Err)
    end;

validate(Rule = {<<"enum">>, Values}, Name, Value) ->
    Err = <<"value:", Value/binary, " is not enum.">>,
    try
        FormattedValue = erlang:binary_to_existing_atom(Value, utf8),
        case lists:member(FormattedValue, Values) of
            true -> {ok, FormattedValue};
            false ->
                validation_error(Rule, Name, Err)
        end
    catch
        error:badarg ->
            validation_error(Rule, Name, Err)
    end;

validate(Rule = {<<"max">>, Max}, Name, Value) ->
    case Value =< Max of
        true -> ok;
        false ->
            Err = <<"max:", Max/binary, ", but value:", Value/binary>>,
            validation_error(Rule, Name, Err)
    end;

validate(Rule = {<<"exclusive_max">>, ExclusiveMax}, Name, Value) ->
    case Value > ExclusiveMax of
        true -> ok;
        false ->
            Err = <<"exclusive_max:", ExclusiveMax/binary, ", but value:", Value/binary>>,
            validation_error(Rule, Name, Err)
    end;

validate(Rule = {<<"min">>, Min}, Name, Value) ->
    case Value >= Min of
        true -> ok;
        false ->
            Err = <<"min:", Min/binary, ", but value:", Value/binary>>,
            validation_error(Rule, Name, Err)
    end;

validate(Rule = {<<"exclusive_min">>, ExclusiveMin}, Name, Value) ->
    case Value =< ExclusiveMin of
        true -> ok;
        false ->
            Err = <<"exclusive_min:", ExclusiveMin/binary, ", but value:", Value/binary>>,
            validation_error(Rule, Name, Err)
    end;

validate(Rule = {<<"max_length">>, MaxLength}, Name, Value) ->
    case size(Value) =< MaxLength of
        true -> ok;
        false ->
            Err = <<"max_length:", MaxLength/binary, ", but value:", Value/binary>>,
            validation_error(Rule, Name, Err)
    end;

validate(Rule = {<<"min_length">>, MinLength}, Name, Value) ->
    case size(Value) >= MinLength of
        true ->
            ok;
        false ->
            Err = <<"min_length:", MinLength/binary, ", but value:", Value/binary>>,
            validation_error(Rule, Name, Err)
    end;

validate(Rule = {<<"pattern">>, Pattern}, Name, Value) ->
    {ok, MP} = re:compile(Pattern),
    case re:run(Value, MP) of
        {match, _} ->
            ok;
        _ ->
            Err = <<"pattern:", Pattern/binary, ", but value:", Value/binary>>,
            validation_error(Rule, Name, Err)
    end;

validate(schema, _Schema, _Data) ->
    ok;
%%    case jesse:validate_with_schema(Schema, Data) of
%%        {error, [{schema_invalid, _, Reason}]} ->
%%            logger:error("validate_with_schema ~p,~p,~p~n", [Schema, Data, Reason]),
%%            validation_error(schema, schema, schema_invalid);
%%        {error, [{data_invalid, _, Error, _, Names}]} ->
%%            logger:error("validate_with_schema ~p,~p,~p~n", [Schema, Data, Error]),
%%            validation_error(schema, Names, Error);
%%        {ok, _} ->
%%            ok
%%    end;

validate(Rule, Name, _Value) ->
    Err = io_lib:format("Can't validate ~p with ~p", [Name, Rule]),
    validation_error(Rule, Name, iolist_to_binary(Err)).

validation_error(Rule, Name, Err) ->
    throw({wrong_param, Name, Rule, Err}).

prepare_param(Rules, Name, Value) ->
    Required = maps:get(<<"required">>, Rules, false),
    Fun =
        fun(RuleType, Value0) ->
            case maps:get(RuleType, Rules, no) of
                no ->
                    Value0;
                Rule ->
                    case Value0 of
                        undefined when Required == true ->
                            validation_error(required, Name, <<Name/binary, " is undefined.">>);
                        undefined when Required == false ->
                            Value0;
                        _ ->
                            case validate({RuleType, Rule}, Name, Value0) of
                                ok -> Value0;
                                {ok, Value1} -> Value1
                            end
                    end
            end
        end,
    lists:foldl(Fun, Value, [<<"type">>]).



