-module(ehttpd_rest).
-include("ehttpd.hrl").

-export([init/2]).
-export([allowed_methods/2]).
-export([allow_missing_post/2]).
-export([content_types_accepted/2]).
-export([charsets_provided/2]).
-export([content_types_provided/2]).
-export([delete_resource/2]).
-export([is_authorized/2]).
-export([known_content_type/2]).
-export([malformed_request/2]).
-export([valid_content_headers/2]).
-export([valid_entity_length/2]).

%% Handlers
-export([handle_request/2]).
-export([handle_multipart/2]).
-export([info/3]).

-record(state, {
    name :: atom(),
    operationid :: atom(),
    logic_handler :: atom(),
    context = #{} :: context()
}).

-type context() :: #{}.
-type state() :: state().
-type response() :: {Result :: stop | binary(), ehttpd_req:req(), state()}.

%% Common handler callbacks.
-callback init(Req :: ehttpd_req:req(), Config :: map()) ->
    {Mod :: module(), NewReq :: ehttpd_req:req(), Context :: map()}.
-optional_callbacks([init/2]).

-callback check_auth(Args :: map(), Req :: ehttpd_req:req()) ->
    {true, Context :: #{binary() => any()}, Req :: ehttpd_req:req()} |
    {false, Result :: #{binary() => any()}, Req :: ehttpd_req:req()} |
    {switch_handler, Mod :: module(), Req :: ehttpd_req:req()}.
-optional_callbacks([check_auth/2]).

-callback handle(OperationID :: atom(), Args :: map(), Context :: map(), Req :: ehttpd_req:req()) ->
    {Code :: ehttpd_req:http_status(), Header :: ehttpd_req:http_headers(), Body :: map()}.

-export_type([context/0]).


-spec init(Req :: ehttpd_req:req(), Opts :: map()) ->
    {cowboy_rest | cowboy_loop, Req :: ehttpd_req:req(), Opts :: state()}.
init(Req, #{
    name := Name,
    logic_handler := LogicHandler
} = Map) ->
    State = #state{
        logic_handler = LogicHandler
    },
    case ehttpd_req:method(Req) of
        <<"OPTIONS">> ->
            {cowboy_rest, Req, State#state{
                name = Name,
                operationid = options
            }};
        Method ->
            Version = ehttpd_req:get_qs(<<"version">>, Req),
            OperationId = maps:get(Method, Map),
            {ok, Context0} = ehttpd_router:get_state(Name, OperationId),
            Context = Context0#{
                name => Name,
                version => Version
            },
            case erlang:function_exported(LogicHandler, init, 2) andalso LogicHandler:init(Req, Context) of
                false ->
                    reqeust_init(OperationId, cowboy_rest, Req, State, Context);
                {Req1, NewContext} ->
                    reqeust_init(OperationId, cowboy_rest, Req1, State, NewContext);
                {Mod, Req1, NewContext} ->
                    reqeust_init(OperationId, Mod, Req1, State, NewContext)
            end
    end.

reqeust_init(OperationId, Mod, Req, State, Context) ->
    {Mod, Req, State#state{
        operationid = OperationId,
        context = Context
    }}.


-spec allowed_methods(Req :: ehttpd_req:req(), State :: state()) ->
    {Value :: [binary()], Req :: ehttpd_req:req(), State :: state()}.
allowed_methods(Req, State) ->
    Method = ehttpd_req:method(Req),
    {[Method], Req, State}.


-spec is_authorized(Req :: ehttpd_req:req(), State :: state()) ->
    {
        Value :: true | {false, AuthHeader :: iodata()},
        Req :: ehttpd_req:req(),
        State :: state()
    }.
is_authorized(Req, #state{ name = Name, operationid = options} = State) ->
    case list_to_binary(ehttpd_server:get_env(Name, access_control_allow_headers, "")) of
        <<>> ->
            reply(403, #{code => 403, msg => <<"forbidden">>}, Req, State);
        Header ->
            Header1 = ?HEADER#{
                <<"access-control-allow-headers">> => Header
            },
            reply(200, Header1, #{}, Req, State)
    end;

is_authorized(Req0, #state{context = Context} = State) ->
    AuthList = maps:get(authorize, Context, []),
    {Args, Req} = ehttpd_auth:pre_check(AuthList, Req0),
    case ehttpd_auth:check_auth(Args, Context, Req) of
        {true, Token, UserInfo} ->
            Log = ehttpd_utils:get_log(Req),
            ehttpd_hook:run('log.request', [UserInfo, Log], #{}),
            NewContext = Context#{token => Token, user => UserInfo},
            {true, Req, State#state{context = NewContext}};
        anonymous when AuthList == [] ->
            {true, Req, State};
        anonymous ->
            reply(401, #{ code => 401, msg => <<"unauthorized">>}, Req, State);
        {forbidden, _Token, _UserInfo} ->
            reply(403, #{ code => 403, msg => <<"forbidden">>}, Req, State)
    end.

-spec content_types_accepted(Req :: ehttpd_req:req(), State :: state()) ->
    {
        Value :: [{binary(), AcceptResource :: atom()}],
        Req :: ehttpd_req:req(),
        State :: state()
    }.
content_types_accepted(Req, #state{context = #{consumes := Consumes}} = State) ->
    Accepts =
        lists:foldl(
            fun
                (<<"multipart/form-data">>, Accepted) ->
                    [{'*', handle_multipart} | Accepted];
                (_, Accepted) ->
                    [{'*', handle_request} | Accepted]
            end, [], Consumes),
    {Accepts, Req, State}.


-spec valid_content_headers(Req :: ehttpd_req:req(), State :: state()) ->
    {Value :: boolean(), Req :: ehttpd_req:req(), State :: state()}.
valid_content_headers(Req, State) ->
    {true, Req, State}.


-spec content_types_provided(Req :: ehttpd_req:req(), State :: state()) ->
    {
        Value :: [{binary(), ProvideResource :: atom()}],
        Req :: ehttpd_req:req(),
        State :: state()
    }.
content_types_provided(Req, #state{context = #{produces := Produces}} = State) ->
    Product =
        lists:foldl(
            fun
                (<<"*">>, Accepted) ->
                    [{'*', handle_request} | Accepted];
                (Consume, Accepted) ->
                    [{Consume, handle_request} | Accepted]
            end, [], Produces),
    {Product, Req, State}.


charsets_provided(Req, State) ->
    {[<<"UTF-8">>], Req, State}.


-spec malformed_request(Req :: ehttpd_req:req(), State :: state()) ->
    {Value :: false, Req :: ehttpd_req:req(), State :: state()}.
malformed_request(Req, State) ->
    {false, Req, State}.


-spec allow_missing_post(Req :: ehttpd_req:req(), State :: state()) ->
    {Value :: false, Req :: ehttpd_req:req(), State :: state()}.
allow_missing_post(Req, State) ->
    {false, Req, State}.


-spec delete_resource(Req :: ehttpd_req:req(), State :: state()) -> response().
delete_resource(Req, State) ->
    handle_request(Req, State).


-spec known_content_type(Req :: ehttpd_req:req(), State :: state()) ->
    {Value :: true, Req :: ehttpd_req:req(), State :: state()}.
known_content_type(Req, State) ->
    {true, Req, State}.


-spec valid_entity_length(Req :: ehttpd_req:req(), State :: state()) ->
    {Value :: true, Req :: ehttpd_req:req(), State :: state()}.
valid_entity_length(Req, State) ->
    %% @TODO check the length
    {true, Req, State}.


-spec handle_multipart(ehttpd_req:req(), state()) -> response().
handle_multipart(Req, State) ->
    Fun =  fun() -> check_multipart(State#state.context, Req, #{}) end,
    safe_handle_request(Fun, Req, State).

-spec handle_request(ehttpd_req:req(), state()) -> response().
handle_request(Req, State) ->
    Fun =  fun() -> ehttpd_check:check_request(State#state.context, Req) end,
    safe_handle_request(Fun, Req, State).


-spec info(Message :: any(), Req :: ehttpd_req:req(), State :: state()) ->
    {ok, Req :: ehttpd_req:req(), State :: state()} |
    {ok, Req :: ehttpd_req:req(), State :: state(), hibernate} |
    {stop, Req :: ehttpd_req:req(), State :: state()}.
info(Message, Req, State) ->
    Fun = fun() -> {ok, Message, Req} end,
    safe_handle_request(Fun, Req, State).


safe_handle_request(Fun, Req0, #state{
    operationid = OperationID,
    logic_handler = LogicHandler,
    context = Context
} = State) ->
    try
        {ok, Populated, Req} = Fun(),
        Args = [OperationID, Populated, Context, Req],
        case apply(LogicHandler, handle, Args) of
            {ok, Req} ->
                {ok, Req, State};
            {ok, Req, hibernate} ->
                {ok, Req, State, hibernate};
            {stop, Req} ->
                {stop, Req, State};
            {Status, Data} ->
                reply(Status, Data, Req, State);
            {Status, Headers, Data} ->
                reply(Status, Headers, Data, Req, State);
            {Status, Headers, Data, NewReq} ->
                reply(Status, Headers, Data, NewReq, State)
        end
    catch
        throw:{wrong_param, _Name, required, Reason} ->
            reply(400, #{ code => 400, msg => Reason}, Req0, State);
        throw:{wrong_param, Reason, schema, wrong_type} ->
            Err = list_to_binary(io_lib:format("~p, wrong type", [Reason])),
            reply(400, #{ code => 400, msg => Err}, Req0, State);
        throw:{wrong_param, _, _, Reason} ->
            Err = list_to_binary(io_lib:format("~p, wrong type", [Reason])),
            reply(400, #{ code => 400, msg => Err}, Req0, State);
        _:Reason:Stacktrace ->
            logger:error("~w,~p", [LogicHandler, Stacktrace]),
            Err = case application:get_env(ehttpd, debug, false) of
                      true ->
                          list_to_binary(io_lib:format("~p", [Reason]));
                      false ->
                          <<"Server Internal Error">>
                  end,
            reply(500, #{ code => 500,  msg => Err}, Req0, State)
    end.

reply(Status, Data, Req, State) ->
    reply(Status, #{}, Data, Req, State).


reply(Status, Header, Body, Req, State) when is_binary(Body) ->
    NewHeaders = maps:merge(Header, ?HEADER),
    Req1 = ehttpd_req:reply(Status, NewHeaders, Body, Req),
    {stop, Req1, State};

reply(Status, Header, Data, Req, State) ->
    Body = jiffy:encode(Data),
    NewHeaders = maps:merge(Header, ?HEADER),
    Req1 = ehttpd_req:reply(Status, NewHeaders, Body, Req),
    {stop, Req1, State}.

check_multipart(Context, Req, Acc) ->
    case cowboy_req:read_part(Req) of
        undefined ->
            {ok, Acc, Req};
        {ok, Headers, Req1} ->
            check_multipart(Context, cow_multipart:form_data(Headers), Req1, Acc);
        {done, Req1} ->
            {ok, Acc, Req1}
    end.
check_multipart(Context, {data, Name}, Req, Acc) ->
    {ok, Data, Req1} = cowboy_req:read_part_body(Req),
    check_multipart(Context, Req1, Acc#{Name => Data});
check_multipart(Context, {file, Name, Filename, ContentType}, Req, Acc) ->
    #{ name := SerName, base_path := BasePath } = Context,
    DocRoot = list_to_binary(ehttpd_server:get_env(SerName, docroot, "")),
    {{Y, M, D}, {H, N, S}} = calendar:local_time(),
    Now = list_to_binary(lists:concat([Y, M, D, H, N, S])),
    Exe = filename:extension(Filename),
    FilePath = <<BasePath/binary, "/upload/", Now/binary, Exe/binary>>,
    Path = ehttpd_utils:filename_join(DocRoot, FilePath),
    case filelib:ensure_dir(Path) of
        ok ->
            {ok, Bin, Req1} = cowboy_req:read_part_body(Req),
            case file:write_file(Path, Bin, [append]) of
                ok ->
                    check_multipart(Context, Req1, Acc#{
                        Name => #{
                            <<"path">> => <<"upload/", Now/binary, Exe/binary>>,
                            <<"filename">> => Filename,
                            <<"contentType">> => ContentType
                        }});
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.
