%%%-------------------------------------------------------------------
%%% @author kenneth
%%% @copyright (C) 2019, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 19. 四月 2019 18:30
%%%-------------------------------------------------------------------
-module(ehttpd_swagger).
-author("kenneth").
-behaviour(gen_server).
-include("ehttpd.hrl").
-define(SERVER, ?MODULE).
-record(state, { swagger = [] }).

%% API
-export([start_link/0]).
-export([generate/5, write/3, read/2, list/0, parse_schema/3, load_schema/3, compile/2, compile/3]).
-record(api, {authorize, base_path, check_request, check_response, consumes, description, method, operationid, path, produces, summary, tags, version}).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).


%% 根据swagger动态编译出模块到文件
-spec compile(Mod::atom(), InPath::list(), OutPath::list()) ->
    {ok, Module::atom()} | {error, Reason::any()}.
compile(Mod, InPath, OutPath) when is_list(InPath) ->
    case file:read_file(InPath) of
        {ok, Bin} ->
            Schema = jsx:decode(Bin, [{labels, binary}, return_maps]),
            compile(Mod, Schema, OutPath);
        {error, Reason} ->
            {error, Reason}
    end;
compile(Mod, Schema, OutPath) when is_map(Schema) ->
    case compile(Mod, Schema) of
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

%% 根据swagger动态编译出模块
compile(Mod, Schema) ->
    Module = list_to_atom(lists:concat(["ehttpd_", Mod, "_handler"])),
    Hand = fun(Source) -> format_val(Mod, Source) end,
    case read(?WEBSERVER, #{}) of
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
            case dtl_compile(erlydtl, TplPath, Vals, Opts) of
                {ok, IoBin} ->
                    {ok, Module, IoBin};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.


dtl_compile(Mod, TplPath, Vals, Opts) ->
    case catch apply(Mod, compile, [{file, TplPath}, render, [{out_dir, false} | Opts]]) of
        {ok, Render} ->
            {ok, IoList} = Render:render(Vals),
            {ok, unicode:characters_to_binary(IoList)};
        {'EXIT', Reason} ->
            {error, Reason};
        error ->
            case file:read_file_info(TplPath) of
                {error, Reason} -> {error, Reason};
                _ -> {error, compile_error}
            end
    end.


%% 检查模块是否有swagger
generate(_ServerName, Handlers, Path, AccIn, Hand) ->
    {ok, Version} = application:get_key(ehttpd, vsn),
    {ok, #{ <<"info">> := Info } = BaseSchemas0} = load_schema(Path, [{labels, binary}, return_maps]),
    BaseSchemas = BaseSchemas0#{
        <<"info">> => Info#{
            <<"version">> => maps:get(<<"version">>, Info, list_to_binary(Version))
        }
    },
    Fun =
        fun(Mod, Acc) ->
            try
                check_mod_swagger(Mod, Acc, Hand)
            catch
                _ErrType:Reason  ->
                    logger:error("~p ~p", [Mod, Reason]),
                    Acc
            end
        end,
    lists:foldl(Fun, maps:merge(BaseSchemas, AccIn), Handlers).

%% 写入swagger文件
write(Name, Version, Schema) ->
    gen_server:call(?SERVER, {write, Name, Version, Schema}).

%% 读取swagger文件
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
                    case catch jsx:decode(Bin, Opts) of
                        {'EXIT', Reason} ->
                            logger:error("decode error,~p,~p~n", [Path, Reason]),
                            {error, Reason};
                        Schemas ->
                            {ok, Schemas}
                    end;
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
            SchemaPath = get_priv(?MODULE, ?SWAGGER(Name, Version)),
            Reply = file:write_file(SchemaPath, jsx:encode(Schema), [write]),
            {reply, Reply, State#state{swagger = [{Name, Version} | List]}};
        {Name, _Version} ->
            {reply, {error, exist}, State}
    end;

handle_call({read, Name, Config}, _From, #state{swagger = List} = State) ->
    case lists:keyfind(Name, 1, List) of
        false ->
            {reply, {error, not_find}, State};
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
            case load_schema(?MODULE, ?SWAGGER(Name, Version), [{labels, binary}, return_maps]) of
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


%%%===================================================================
%%% 内部函数
%%%===================================================================


check_mod_swagger(Mod, Schema, Hand) ->
    F =
        fun(NewSchema, AccSchema) ->
            parse_schema(NewSchema, AccSchema,
                fun(Path, Method, NewMethodInfo, AccSchemas) ->
                    Hand(Mod, Path, Method, NewMethodInfo, AccSchemas)
                end)
        end,
    Functions = Mod:module_info(exports),
    lists:foldl(
        fun
            ({Fun, 0}, Acc) ->
                case binary:split(list_to_binary(atom_to_list(Fun)), <<"swagger_">>) of
                    [<<>>, _Path] ->
                        case Mod:Fun() of
                            {error, _Reason} ->
                                Acc;
                            NewSchemas when is_list(NewSchemas) ->
                                lists:foldl(F, Acc, NewSchemas);
                            NewSchema when is_map(NewSchema) ->
                                F(NewSchema, Acc)
                        end;
                    _ ->
                        Acc
                end;
            (_, Acc) ->
                Acc
        end, Schema, Functions).


parse_schema(NewSchema, AccSchema, Hand) ->
    % add definitions to Acc
    Definitions = maps:get(<<"definitions">>, AccSchema, #{}),
    NewDefinitions = maps:get(<<"definitions">>, NewSchema, #{}),
    Tags = maps:get(<<"tags">>, AccSchema, []),
    NewTags = maps:get(<<"tags">>, NewSchema, []),
    NewAccSchema = AccSchema#{
        <<"definitions">> => maps:merge(Definitions, NewDefinitions),
        <<"tags">> => lists:concat([Tags, NewTags])
    },
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


do_method_fun(Path, Method, MethodInfo, SWSchemas, Hand) ->
    OperationId = ehttpd_router:get_operation_id(Path, Method),
    Paths = maps:get(<<"paths">>, SWSchemas, #{}),
    MethodAcc = maps:get(Path, Paths, #{}),
    case maps:get(Method, MethodAcc, no) of
        no ->
            % logger:info("Path -> ~s, ~s ~s~n", [OperationId, Method, NewPath]),
%%            BinOpId = list_to_binary(io_lib:format("~p", [OperationId])),
            PreMethodInfo = MethodInfo#{
                <<"operationId">> => OperationId
%%                <<"externalDocs">> => #{
%%                    <<"url">> => get_doc_path(BinOpId)
%%                }
            },
            NewMethodInfo = Hand(Path, Method, PreMethodInfo, SWSchemas),
            SWSchemas#{
                <<"paths">> => Paths#{
                    Path => MethodAcc#{
                        Method => NewMethodInfo
                    }
                }
            };
        _ ->
            logger:warning("Path is repeat, ~p~n", [<<Method/binary, " ", Path/binary>>]),
            SWSchemas
    end.


get_path(Path, Map) when is_list(Path) ->
    get_path(list_to_binary(Path), Map);
get_path(Path0, Map) when is_binary(Path0) ->
    Parameters = maps:get(<<"parameters">>, Map, []),
    F =
        fun
            (#{<<"name">> := Name, <<"in">> := <<"path">>}, Acc) ->
                case re:run(Path0, <<"(\\{", Name/binary, "\\})">>, [global, {capture, all_but_first, binary}]) of
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
    Tpl = lists:concat([Dir, "/priv/swagger/erlang_handler.src"]),
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


%%test() ->
%%    compile(test, )
