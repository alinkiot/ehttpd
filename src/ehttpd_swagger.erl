-module(ehttpd_swagger).
-author("kenneth").
-behaviour(gen_server).
-include("ehttpd.hrl").
-define(SERVER, ?MODULE).
-record(state, { swagger = [] }).

%% API
-export([start_link/0]).
-export([generate/4, write/2, read/2, list/0, parse_schema/3, load_schema/3, compile/4, compile/3]).
-record(api, {authorize, base_path, check_request, check_response, consumes, description, method, operationid, path, produces, summary, tags, version}).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).


-spec compile(Name:: atom(), Mod::atom(), InPath::list(), OutPath::list()) ->
    {ok, Module::atom()} | {error, Reason::any()}.
compile(Name, Mod, InPath, OutPath) when is_list(InPath) ->
    case file:read_file(InPath) of
        {ok, Bin} ->
            Schema = jiffy:decode(Bin, [return_maps]),
            compile(Name, Mod, Schema, OutPath);
        {error, Reason} ->
            {error, Reason}
    end;
compile(Name, Mod, Schema, OutPath) when is_map(Schema) ->
    case compile(Name, Mod, Schema) of
        {ok, Module, Bin} ->
            case file:write_file(OutPath, Bin) of
                ok ->
                    {ok, Module};
                {error, Why} ->
                    {error, Why}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

compile(Name, Mod, Schema) ->
    Module = list_to_atom(lists:concat([Mod, "_controller"])),
    Hand = fun(Source) -> format_val(Mod, Source) end,
    case read(Name, #{}) of
        {ok, SWSchema} ->
            Fun =
                fun(Path, Method, MethodInfo, AccSchema) ->
                    Init = #{
                        summary => maps:get(<<"summary">>, MethodInfo, <<>>),
                        description => maps:get(<<"description">>, MethodInfo, <<>>),
                        tags => maps:get(<<"tags">>, MethodInfo, [])
                    },
                    [Route | _] = ehttpd_router:parse_path(Module, Path, Method, MethodInfo, AccSchema, Init),
                    Route
                end,
            NewSchema = parse_schema(Schema, maps:without([<<"paths">>], SWSchema), Fun),
            {TplPath, Vals, Opts} = Hand(NewSchema),
            case dtl_compile(erlydtl, TplPath, [{name, Name} | Vals], Opts) of
                {ok, IoBin} ->
                    {ok, Module, IoBin};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.


dtl_compile(Mod, TplPath, Vals, Opts) ->
    case apply(Mod, compile, [{file, TplPath}, render, [{out_dir, false} | Opts]]) of
        {ok, Render} ->
            {ok, IoList} = Render:render(Vals),
            {ok, unicode:characters_to_binary(IoList)};
        error ->
            case file:read_file_info(TplPath) of
                {error, Reason} -> {error, Reason};
                _ -> {error, compile_error}
            end
    end.


generate(Name, Handlers, BasePath, Hand) ->
    BaseSchemas = load_base_schema(BasePath),
    Fun =
        fun(Mod, Acc) ->
            check_mod_swagger(Name, Mod, Acc, Hand)
        end,
    lists:foldl(Fun, BaseSchemas, Handlers).

load_base_schema(Path) ->
    {ok, BaseSchemas} = load_schema(Path, [return_maps]),
    case application:get_env(ehttpd, token_name) of
        undefined ->
            BaseSchemas;
        {ok, Name} ->
            Definitions = maps:get(<<"securityDefinitions">>, BaseSchemas, #{}),
            Definitions1 = maps:fold(
                fun(Key, Map, Acc) ->
                    Acc#{ Key => Map#{ <<"name">> => list_to_binary(Name)}}
                end, #{}, Definitions),
            BaseSchemas#{
                <<"securityDefinitions">> => Definitions1
            }
    end.



write(Name, Schema) ->
    Info = maps:get(<<"info">>, Schema, #{}),
    Version = maps:get(<<"version">>, Info),
    gen_server:call(?SERVER, {write, Name, Version, Schema}).

read(Name, Config) ->
    gen_server:call(?SERVER, {read, Name, Config}).

list() ->
    gen_server:call(?SERVER, list).

load_schema(Mod, FileName, Opts) ->
    Path = get_priv(Mod, FileName),
    load_schema(Path, Opts).

load_schema(Path, Opts) ->
    case catch file:read_file(Path) of
        {Err, Reason} when Err == 'EXIT'; Err == error ->
            logger:error("read swagger error,~p,~p~n", [Path, Reason]),
            {error, Reason};
        {ok, Bin} ->
            case lists:member(return_maps, Opts) of
                true ->
                    {ok, jiffy:decode(Bin, [return_maps])};
                false ->
                    {ok, Bin}
            end
    end.


start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).


%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    {ok, #state{}}.


handle_call(list, _From, #state{swagger = List} = State) ->
    {reply, {ok, List}, State};

handle_call({write, Name, Version, Schema}, _From, #state{swagger = List} = State) ->
    case lists:keyfind(Name, 1, List) of
        false ->
            SchemaPath =
                case ehttpd_server:get_env(Name, docroot, "") of
                    "" ->
                        get_priv(?MODULE, ?SWAGGER(Name, Version));
                    DocRoot ->
                        filename:join([DocRoot, ?SWAGGER(Name, Version)])
                end,
            Reply = file:write_file(SchemaPath, jiffy:encode(Schema), [write]),
            {reply, Reply, State#state{swagger = [{Name, Version} | List]}};
        {Name, _Version} ->
            {reply, {error, exist}, State}
    end;

handle_call({read, Name, Config}, _From, #state{swagger = List} = State) ->
    case lists:keyfind(Name, 1, List) of
        false ->
            {reply, {error, notfound}, State};
        {Name, CurVersion} ->
            Version = maps:get(<<"version">>, Config, CurVersion),
            Fun =
                fun(Keys) ->
                    lists:foldl(
                        fun(Key, Acc) ->
                            case maps:get(Key, Config, undefined) of
                                undefined -> Acc;
                                Value -> Acc#{Key => Value}
                            end
                        end, #{}, Keys)
                end,
            Map = Fun([<<"host">>, <<"basePath">>]),
            SchemaPath =
                case ehttpd_server:get_env(Name, docroot, "") of
                    "" ->
                        get_priv(?MODULE, ?SWAGGER(Name, Version));
                    DocRoot ->
                        filename:join([DocRoot, ?SWAGGER(Name, Version)])
                end,
            case load_schema(SchemaPath, [{labels, binary}, return_maps]) of
                {ok, Schema} ->
                    NewSchema = maps:merge(Schema, Map),
                    FinSchema =
                        case maps:get(<<"tags">>, Config, no) of
                            no ->
                                NewSchema;
                            TagsB ->
                                Tags = re:split(TagsB, <<",">>),
                                get_swagger_by_tags(NewSchema, Tags)
                        end,
                    {reply, {ok, FinSchema}, State};
                {error, Reason} ->
                    {reply, {error, Reason}, State}
            end
    end;

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.


handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


check_mod_swagger(Name, Mod, Schema, Hand) ->
    F =
        fun(NewSchema, AccSchema) ->
            parse_schema(NewSchema, AccSchema,
                fun(Path, Method, NewMethodInfo, AccSchemas) ->
                    Hand(Mod, Path, Method, NewMethodInfo, AccSchemas)
                end)
        end,
    case Mod:swagger(Name) of
        NewSchemas when is_list(NewSchemas) ->
            lists:foldl(F, Schema, NewSchemas);
        NewSchema when is_map(NewSchema) ->
            F(NewSchema, Schema)
    end.


parse_schema(NewSchema, AccSchema, Hand) ->
    % add definitions to Acc
%%    Components = maps:get(<<"components">>, AccSchema, #{}),
%%    Definitions = maps:get(<<"schemas">>, Components, #{}),
%%    NewDefinitions = maps:get(<<"schemas">>, NewSchema, #{}),
%%    Tags = maps:get(<<"tags">>, AccSchema, []),
%%    NewTags = maps:get(<<"tags">>, NewSchema, []),
%%    NewAccSchema = AccSchema#{
%%        <<"components">> => Components#{
%%            <<"schemas">> => maps:merge(Definitions, NewDefinitions)
%%        },
%%        <<"tags">> => lists:concat([Tags, NewTags])
%%    },
    NewAccSchema = deep_merge(AccSchema, maps:without([<<"paths">>], NewSchema)),
    % get paths from NewSchema
    Paths = maps:get(<<"paths">>, NewSchema, #{}),
    Fun =
        fun(Path, Methods, Acc) ->
            maps:fold(
                fun(Method, MethodInfo, Acc1) ->
                    NewPath = get_path(Path, MethodInfo),
                    do_method_fun(NewPath, Method, MethodInfo, Acc1, Hand)
                end, Acc, Methods)
        end,
    maps:fold(Fun, NewAccSchema, Paths).

deep_merge(Map1, Map2) ->
    maps:fold(
        fun(K, V2, Acc) ->
            case maps:find(K, Acc) of
                {ok, V1} when is_map(V1), is_map(V2) ->
                    Acc#{K => deep_merge(V1, V2)};
                {ok, V1} when is_list(V1), is_list(V2) ->
                    Acc#{K => lists:concat([V1, V2])};
                _ ->
                    Acc#{K => V2}
            end
        end, Map1, Map2).


do_method_fun(Path, Method, MethodInfo, SWSchemas, Hand) ->
    OperationId = ehttpd_router:get_operation_id(Path, Method),
    Paths = maps:get(<<"paths">>, SWSchemas, #{}),
    PreMethodInfo = MethodInfo#{
        <<"operationId">> => OperationId
    },
    Method1 = list_to_binary(string:to_upper(binary_to_list(Method))),
    NewPath = Hand(Path, Method1, PreMethodInfo, SWSchemas),
    MethodAcc = maps:get(NewPath, Paths, #{}),
    SWSchemas#{
        <<"paths">> => Paths#{
            NewPath => MethodAcc#{
                Method => remove_extend(MethodInfo)
            }
        }
    }.

remove_extend(MethodInfo) ->
    maps:fold(
        fun(Key, Value, Acc) ->
            case re:run(Key, <<"^x-">>, [unicode]) of
                {match, _} -> Acc;
                nomatch -> Acc#{Key => Value}
            end
        end, #{}, MethodInfo).

get_path(Path, Map) when is_list(Path) ->
    get_path(list_to_binary(Path), Map);
get_path(Path0, Map) when is_binary(Path0) ->
    Parameters = maps:get(<<"parameters">>, Map, []),
    F =
        fun
            (#{<<"name">> := Name, <<"in">> := <<"path">>}, Acc) ->
                case re:run(Path0, <<"(\{", Name/binary, "\})">>, [global, {capture, all_but_first, binary}]) of
                    {match, _PS} -> Acc;
                    nomatch -> [<<"{", Name/binary, "}">> | Acc]
                end;
            (_, Acc) ->
                Acc
        end,
    filename:join([Path0 | lists:foldr(F, [], Parameters)]).


get_swagger_by_tags(Swagger, []) ->
    Swagger;
get_swagger_by_tags(Swagger, Tags) ->
    TagsDef = maps:get(<<"tags">>, Swagger, []),
    Definitions = maps:get(<<"definitions">>, Swagger, []),
    New =
        maps:fold(
            fun(Path, Map, #{<<"paths">> := Paths, <<"tags">> := TagsDef1, <<"definitions">> := Definitions1} = Acc) ->
                NewMap = maps:fold(
                    fun(Method, Info, Acc1) ->
                        case Tags -- maps:get(<<"tags">>, Info, []) == Tags of
                            true ->
                                maps:remove(Method, Acc1);
                            false ->
                                Acc1
                        end
                    end, Map, Map),
                case maps:size(NewMap) == 0 of
                    true ->
                        Acc;
                    false ->
                        #{
                            <<"paths">> => Paths#{Path => NewMap},
                            <<"tags">> => TagsDef1,
                            <<"definitions">> => Definitions1
                        }
                end
            end, #{<<"paths">> => #{}, <<"tags">> => TagsDef, <<"definitions">> => Definitions}, maps:get(<<"paths">>, Swagger, #{})),
    maps:merge(Swagger, New).


get_priv(Mod, <<"/", Path/binary>>) ->
    get_priv(Mod, Path);
get_priv(Mod, Path) ->
    case code:is_loaded(Mod) of
        false ->
            throw({Mod, not_loaded});
        {file, Here} ->
            Dir = filename:dirname(filename:dirname(Here)),
            filename:join([Dir, "priv/swagger/", Path])
    end.


format_val(Mod, Schema) ->
    {file, Here} = code:is_loaded(?MODULE),
    Dir = filename:dirname(filename:dirname(Here)),
    Tpl = lists:concat([Dir, "/priv/swagger/controller.src"]),
    Paths = maps:values(maps:get(<<"paths">>, Schema, #{})),
    Apis = lists:foldl(
        fun(Methods, Acc) ->
            maps:fold(
                fun(Method, {Path, _, State}, Acc1) ->
                    NewMethod = list_to_binary(string:to_upper(binary_to_list(Method))),
                    Index = maps:get(NewMethod, State),
                    {ok, {_, Info}}= ehttpd_router:get_state(Index),
                    [maps:to_list(Info#{
                        method => NewMethod,
                        path => list_to_binary(Path)
                    }) | Acc1]
                end, Acc, Methods)
        end, [], Paths),
    {Tpl, [{mod, Mod}, {apis, Apis}], [{api, record_info(fields, api)}]}.
