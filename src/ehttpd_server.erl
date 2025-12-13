-module(ehttpd_server).
-behaviour(gen_server).
-include("ehttpd.hrl").
-export([start/3, stop/1, bind/4, reload_paths/2, rewrite_path/2, rewrite_rule/2, get_env/3]).
-export([start_link/3, init/1, handle_call/3, handle_info/2, handle_cast/2, code_change/3, terminate/2]).

-record(state, { name }).
-define(SERVER(Name), list_to_atom(lists:concat(['http_', Name]))).

-type env() :: #{
    docroot => binary(),
    swagger => binary(),
    cacertfile => binary(),
    certfile => binary(),
    keyfile => binary()
}.

-spec start(Name :: atom(), Port :: integer(), Env :: env()) ->
    supervisor:startchild_ret().
start(Name, Port, Env) ->
    Child = {Name, {?MODULE, start_link, [Name, Port, Env]}, permanent, 5000, worker, [?MODULE]},
    supervisor:start_child(ehttpd_sup, Child).

-spec stop(Name :: atom()) -> ok.
stop(Name) ->
    gen_server:call(?SERVER(Name), stop).

%% add path
bind(Path, Mod, _Options, priv) ->
    case ehttpd_swagger:load_schema(Mod, Path, [return_maps]) of
        {ok, Schemas} ->
            Schemas;
        {error, Reason} ->
            throw({error, Reason})
    end.

reload_paths(Name, Env) ->
    Dispatch = get_dispatch(Name, Env),
    cowboy:set_env(Name, dispatch, Dispatch).

get_env(Name, Key, Default) ->
    case ehttpd_cache:lookup({Name, env}) of
        {ok, Env} ->
            maps:get(Key, Env, Default);
        {error, Reason} ->
            {error, Reason}
    end.


start_link(Name, Port, Env) ->
    gen_server:start_link({local, ?SERVER(Name)}, ?MODULE, [Name, Port, Env], []).


init([Name, Port, Env]) ->
    NewEnv = format_env(Env),
    load_rewrite(Name, NewEnv),
    ehttpd_cache:insert({Name, env}, NewEnv),
    case start_server(Name, Port, NewEnv) of
        {ok, _Pid} ->
            {ok, #state{name = Name}};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(stop, _From, #state{name = Name} = State) ->
    Reply = cowboy:stop_listener(Name),
    ehttpd_cache:delete({Name, env}),
    {stop, normal, Reply, State};

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


start_server(Name, Port, Env) ->
    ProtoOpts = #{
        env => #{
            dispatch => get_dispatch(Name, Env)
        }
    },
    TransOpts = [{port, Port}],
    SSL = maps:with([cacertfile, certfile, keyfile], Env),
    case maps:size(SSL) > 0 of
        true ->
            cowboy:start_tls(Name, TransOpts ++ maps:to_list(SSL), ProtoOpts);
        false ->
            cowboy:start_clear(Name, TransOpts, ProtoOpts)
    end.

get_dispatch(Name, Env) ->
    Dispatch = ehttpd_router:get_paths(Name, Env),
    cowboy_router:compile([{'_', Dispatch}]).


-spec format_env(Env) -> Env when
    Env :: env().
format_env(Env) ->
    maps:fold(fun format_env/3, #{}, Env).

-spec format_env(Key :: atom(), Value :: any(), Acc) -> Acc when
    Acc :: map().
format_env(Key, Value, Acc) when
    Key == rewrite;
    Key == swagger;
    Key == docroot;
    Key == cacertfile;
    Key == certfile;
    Key == keyfile ->
    Acc#{Key => format_path(Value)};
format_env(Key, Value, Acc) ->
    Acc#{Key => Value}.

-spec format_path(Path) -> Path when
    Path :: string().
format_path(Value) ->
    case Value of
        "app/" ++ Path ->
            [App, "priv/" ++ Path1] = string:split(Path, "/"),
            Dir = code:priv_dir(list_to_atom(App)),
            filename:join([Dir, Path1]);
        "priv/" ++ _ = Path ->
            {file, Here} = code:is_loaded(?MODULE),
            Dir = filename:dirname(filename:dirname(Here)),
            filename:join([Dir, Path]);
        Path ->
            Path
    end.

-spec load_rewrite(Name :: atom(), map()) -> boolean().
load_rewrite(Name, NewEnv) ->
    case maps:get(rewrite, NewEnv, "") of
        "" ->
            false;
        Path ->
            case file:read_file(Path) of
                {ok, Data} ->
                    load_rewrite(Name, <<"RewriteRule">>, Data),
                    load_rewrite(Name, <<"RewritePath">>, Data);
                _ ->
                    false
            end
    end.

load_rewrite(Name, Key, Data) ->
    Opts = [global, multiline, {capture, all_but_first, binary}],
    case re:run(Data, <<"^", Key/binary, "\s+([^\s]+)\s+([^\s\n]+)">>, Opts) of
        nomatch -> false;
        {match, Match} ->
            ehttpd_cache:insert({Name, Key}, Match)
    end.



-spec rewrite_path(Name :: atom(), Path) -> Path when
    Path :: binary().
rewrite_path(Name, Path) ->
    case ehttpd_cache:lookup({Name, <<"RewritePath">>}) of
        {error, notfound} ->
            Path;
        {ok, Rules} ->
            re_path(Rules, Path)
    end.

-spec rewrite_rule(Name :: atom(), Path) -> Path when
    Path :: binary().
rewrite_rule(Name, Path) ->
    case ehttpd_cache:lookup({Name, <<"RewriteRule">>}) of
        {error, notfound} ->
            Path;
        {ok, Rules} ->
            re_path(Rules, Path)
    end.

re_path([], Path) -> Path;
re_path([[Re, Replacement] | Rules], Path) ->
    case re:run(Path, Re) of
        nomatch ->
            re_path(Rules, Path);
        {match, _} ->
            re:replace(Path, Re, Replacement, [{return, binary}])
    end.
