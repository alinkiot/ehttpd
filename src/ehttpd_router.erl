-module(ehttpd_router).
-include("ehttpd.hrl").

%% API
-export([path/1, generate_paths/2, get_state/2, parse_path/6]).
-export([get_operation_id/2]).

%% Static Callback
-export([init/2]).
-export([malformed_request/2]).
-export([forbidden/2]).
-export([content_types_provided/2]).
-export([resource_exists/2]).
-export([last_modified/2]).
-export([generate_etag/2]).
-export([get_file/2]).


%% 获取路径
generate_paths(Name, #{ swagger := BasePath  } = Env) ->
    DefRoutes = [
        {"/swaggers", ?MODULE, swagger_list},
        {"/swagger/:Name", ?MODULE, swagger},
        {"/[...]/swagger/:Name", ?MODULE, swagger},
        {"/[...]", ?MODULE, {static, Name, Env}}
    ],
    Routers = ehttpd_utils:apply_module_attributes(ehttpd_router, Name),
    Routers1 = lists:concat([Router:route(Name, Env)|| Router <- Routers]),
    Handlers = ehttpd_utils:apply_module_attributes(ehttpd_rest, Name),
    Router2 = get_routes_by_swagger(Name, Handlers, BasePath),
    lists:concat([Router2, Routers1, DefRoutes]).

path(Name) ->
    ehttpd_cache:match({{Name, {'$1', router}}, '$2'}).



get_routes_by_swagger(Name, Handlers, BasePath) ->
    Fun =
        fun(Mod, Path, Method, MethodInfo, SWSchema) ->
            create_route(Name, Mod, Path, Method, MethodInfo, SWSchema)
        end,
    SWSchema = ehttpd_swagger:generate(Name, Handlers, BasePath, Fun),
    ehttpd_swagger:write(Name, SWSchema),
    erase(routes).

create_route(Name, Mod, Path0, Method, MethodInfo, SWSchema) ->
    Acc = case get(routes) of
              undefined -> [];
              Value -> Value
          end,
    NewPath = ehttpd_server:rewrite_rule(Name, Path0),
    Path = re:replace(NewPath, <<"(\{([^\}]+)\})">>, <<":\\2">>, [global, {return, binary}]),
    {RealPath, State} = parse_path(Name, Mod, Path, Method, MethodInfo, SWSchema),
    NewRoutes = case lists:keyfind(RealPath, 1, Acc) of
                    {RealPath, RestMod, OldState} ->
                        NewAcc = lists:keydelete(RealPath, 1, Acc),
                        NewState = maps:merge(OldState, State),
                        [{RealPath, RestMod, NewState} | NewAcc];
                    false ->
                        [{RealPath, ehttpd_rest, State} | Acc]
                end,
    put(routes, NewRoutes),
    NewPath.


parse_path(Name, Mod, Path, Method, MethodInfo, SWSchema) ->
    OperationId = maps:get(<<"operationId">>, MethodInfo),
    Extend = maps:get(<<"x-extend">>, MethodInfo, #{}),
    Permission = maps:get(<<"x-permission">>, MethodInfo, <<>>),
    save_permission(Name, Path, Permission, MethodInfo),
    BasePath = maps:get(<<"basePath">>, SWSchema, <<>>),
    Config = #{
        extend => Extend,
        rule => Permission,
        base_path => BasePath,
        authorize => get_security(MethodInfo, SWSchema),
        consumes => get_consumes(MethodInfo, SWSchema),
        produces => get_produces(MethodInfo, SWSchema),
        check_request => get_check_request(MethodInfo, SWSchema),
        check_response => get_check_response(MethodInfo, SWSchema)
    },
    set_state(Name, OperationId, Config),
    State = #{
        name => Name,
        logic_handler => Mod,
        Method => OperationId
    },
    RealPath = <<BasePath/binary, Path/binary>>,
    {RealPath, State}.

save_permission(_, _, <<>>, _) -> ignore;
save_permission(Name, Path, Rule, MethodInfo) ->
    Summary = maps:get(<<"summary">>, MethodInfo, <<>>),
    Desc = maps:get(<<"description">>, MethodInfo, <<>>),
    ehttpd_cache:insert({Name, {Rule, permission}}, {Path, Summary, Desc}).



%% hand swagger.json
init(Req0, swagger_list) ->
    Req =
        case ehttpd_swagger:list() of
            {ok, List} ->
                Swaggers =
                    lists:foldl(
                        fun({Name, Version}, Acc) ->
                            [#{
                                app => Name,
                                path => list_to_binary(lists:concat(["/swagger/", Name, ".json"])),
                                version => Version
                            } | Acc]
                        end, [], List),
                ehttpd_req:reply(200, ?HEADER#{
                    <<"content-type">> => <<"application/json; charset=utf-8">>
                }, jiffy:encode(Swaggers), Req0);
            {error, Reason} ->
                Err = list_to_binary(io_lib:format("~p", [Reason])),
                ehttpd_req:reply(500, ?HEADER#{
                    <<"content-type">> => <<"application/json; charset=utf-8">>
                }, jiffy:encode(#{error => Err}), Req0)
        end,
    {ok, Req, swagger_list};

init(Req0, swagger = Opts) ->
    Name0 = ehttpd_req:binding(<<"Name">>, Req0),
    Name = re:replace(Name0, <<".json">>, <<>>, [global, {return, binary}]),
    Config = ehttpd_req:parse_qs(Req0, [{return, map}]),
    Req =
        case ehttpd_swagger:read(binary_to_atom(Name), Config) of
            {ok, Schema} ->
                ehttpd_req:reply(200, ?HEADER#{
                    <<"content-type">> => <<"application/json; charset=utf-8">>
                }, jiffy:encode(Schema), Req0);
            {error, Reason} ->
                Err = list_to_binary(io_lib:format("~p", [Reason])),
                ehttpd_req:reply(500, ?HEADER#{
                    <<"content-type">> => <<"application/json; charset=utf-8">>
                }, jiffy:encode(#{error => Err }), Req0)
        end,
    {ok, Req, Opts};


init(Req, {static, Name, #{docroot := DocRoot}}) ->
    Path = cowboy_req:path(Req),
    Fun =
        fun() ->
            case binary:last(Path) == $/ of
                true ->
                    Index = lists:concat([DocRoot, binary_to_list(<<Path/binary, "index.html">>)]),
                    cowboy_static:init(Req, {file, Index, []});
                false ->
                    case ehttpd_server:rewrite_path(Name, Path) of
                        Path ->
                            cowboy_static:init(Req, {dir, DocRoot, []});
                        NewPath ->
                            File = lists:concat([DocRoot, binary_to_list(NewPath)]),
                            cowboy_static:init(Req, {file, File, []})
                    end
            end
        end,
    do_without_options(Req, Fun).


do_without_options(Req, Fun) ->
    case ehttpd_req:method(Req) of
        <<"OPTIONS">> ->
            case ?ACCESS_CONTROL_ALLOW_HEADERS of
                <<>> ->
                    ehttpd_req:reply(403, ?HEADER, <<>>, Req);
                Header ->
                    ehttpd_req:reply(200, ?HEADER#{
                        <<"access-control-allow-headers">> => Header
                    }, <<>>, Req)
            end;
        _ ->
            Fun()
    end.

malformed_request(Req, State) ->
    cowboy_static:malformed_request(Req, State).

forbidden(Req, State) ->
    cowboy_static:forbidden(Req, State).

content_types_provided(Req, State) ->
    cowboy_static:content_types_provided(Req, State).

resource_exists(Req, State) ->
    cowboy_static:resource_exists(Req, State).

generate_etag(Req, State) ->
    cowboy_static:generate_etag(Req, State).

last_modified(Req, State) ->
    cowboy_static:last_modified(Req, State).

get_file(Req, State) ->
    cowboy_static:get_file(Req, State).


get_check_request(Map, SWSchema) ->
    Parameters = maps:get(<<"parameters">>, Map, #{}),
    lists:foldl(
        fun(Parameter, Acc) ->
            Parameter1 = maps:without([<<"name">>, <<"description">>, <<"schema">>, <<"default">>], Parameter),
            case Parameter of
                #{<<"$ref">> := Paths} ->
                    {DefName, Props} = get_definitions(Paths, SWSchema),
                    [{DefName, Parameter1#{
                        <<"properties">> => Props
                    }} | Acc];
                #{<<"schema">> := #{<<"$ref">> := Paths}} ->
                    {DefName, Props} = get_definitions(Paths, SWSchema),
                    [{DefName, Parameter1#{
                        <<"properties">> => Props
                    }} | Acc];
                _ ->
                    DefName = maps:get(<<"name">>, Parameter),
                    [{DefName, Parameter1} | Acc]
            end
        end, [], Parameters).



get_check_response(Map, SWSchema) ->
    Responses = maps:get(<<"responses">>, Map, #{}),
    Fun =
        fun(Code, Response, Acc) ->
            HTTPCode = binary_to_integer(Code),
            Acc#{
                HTTPCode => parse_ref_schema(Response, SWSchema)
            }
        end,
    maps:fold(Fun, #{}, Responses).

parse_ref_schema(#{<<"description">> := _} = Schema, SWSchema) ->
    parse_ref_schema(maps:without([<<"description">>], Schema), SWSchema);
parse_ref_schema(#{<<"schema">> := Schema}, SWSchema) ->
    parse_ref_schema(Schema, SWSchema);
parse_ref_schema(#{<<"$ref">> := Paths}, SWSchema) ->
    {DefName, Props} = get_definitions(Paths, SWSchema),
    #{ DefName => Props };
parse_ref_schema(#{<<"type">> := <<"array">>, <<"items">> := Items} = Rule, SWSchema) ->
    Array = parse_ref_schema(Items, SWSchema),
    Rule#{<<"items">> => Array};
parse_ref_schema(#{<<"type">> := <<"object">>, <<"properties">> := Properties} = Rule, SWSchema) ->
    NewProps = maps:fold(
        fun(Name, Rule1, Acc) ->
            Map = parse_ref_schema(Rule1, SWSchema),
            Acc#{Name => Map}
        end, #{}, Properties),
    maps:without([<<"description">>], maps:merge(Rule, NewProps));
parse_ref_schema(Item, _SWSchema) ->
    Item.


get_definitions(<<"#/components/", Paths/binary>>, SWSchema) ->
    Components = maps:get(<<"components">>, SWSchema, #{}),
    List = re:split(Paths, <<"/">>, [{return, binary}]),
    DefName = lists:last(List),
    Definition =
        lists:foldl(
            fun(Key, Acc) ->
                maps:get(Key, Acc)
            end, Components, List),
    {DefName, parse_ref_schema(Definition, SWSchema)}.

get_operation_id(Path, Method) ->
    OId =
        case re:run(Path, <<"[a-zA-Z0-9]+">>, [global, {capture, all, list}]) of
            {match, M0} ->
                [F | T] = lists:concat(M0),
                M =
                    case lists:member(F, ["get", "put", "delete", "post"]) of
                        true -> T;
                        false -> [F | T]
                    end,
                list_to_binary(string:join(M, "_"));
            _ ->
                re:replace(Path, <<"[^a-zA-Z0-9]">>, <<>>, [global, [{return, binary}]])
        end,
    list_to_atom(string:to_lower(binary_to_list(<<Method/binary, "_", OId/binary>>))).

get_security(Map, SWSchema) ->
    Components = maps:get(<<"components">>, SWSchema, #{}),
    SecurityDefinitions = maps:get(<<"securitySchemes">>, Components, #{}),
    AllTypes = maps:keys(SecurityDefinitions),
    GlobalSecurity = maps:get(<<"security">>, SWSchema, []),
    SecurityList = maps:get(<<"security">>, Map, GlobalSecurity),
    Fun =
        fun(Map1, Acc) ->
            Types = maps:keys(Map1),
            CTypes = Types -- (Types -- AllTypes),
            Security = maps:with(CTypes, SecurityDefinitions),
            maps:fold(fun format_security/3, Acc, Security)
        end,
    lists:foldr(Fun, [], SecurityList).

format_security(<<"CookieAuth">> = Key, Auth, Acc) ->
    Name = application:get_env(ehttpd, token_name, "token"),
    [{Key, Auth#{
        <<"in">> => <<"cookie">>,
        <<"type">> => <<"CookieAuth3.0">>,
        <<"name">> => list_to_binary(Name)
    }} | Acc];
format_security(Key, Auth, Acc) ->
    Name = application:get_env(ehttpd, token_name, "token"),
    [{Key, Auth#{
        <<"name">> => list_to_binary(Name)
    }} | Acc].

get_consumes(Map, SWSchema) ->
    maps:get(<<"consumes">>, Map, maps:get(<<"consumes">>, SWSchema, [])).

get_produces(Map, SWSchema) ->
    maps:get(<<"produces">>, Map, maps:get(<<"produces">>, SWSchema, [])).

set_state(Name, OperationId, State) ->
    ehttpd_cache:insert({Name, {OperationId, router}}, State).

get_state(Name, OperationId) ->
    ehttpd_cache:lookup({Name, {OperationId,  router}}).
