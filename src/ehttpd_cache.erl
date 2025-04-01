-module(ehttpd_cache).

-behaviour(gen_server).

%% API
-export([start_link/0, get_with_ttl/1, set_with_ttl/3, delete_with_ttl/1]).

-export([match_delete/1, delete/1, match/1, lookup/1, insert/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-define(DB, ?MODULE).

-record(state, {}).


-spec get_with_ttl(Key) -> undefined | expired | any() when
    Key :: any().
get_with_ttl(Key) ->
    Now = os:system_time(second),
    case lookup({ttl, Key}) of
        {error, notfound} ->
            undefined;
        {ok, {Time, _}} when Now > Time ->
            delete({ttl, Key}),
            expired;
        {ok, {_, Value}} ->
            Value
    end.

-spec set_with_ttl(Key, Value, TTL) -> true when
    Key :: any(),
    Value :: any(),
    TTL :: integer().
set_with_ttl(Key, Value, TTL) ->
    Now = os:system_time(second),
    insert({ttl, Key}, {Now + TTL, Value}).

-spec delete_with_ttl(Key) -> true when
    Key :: any().
delete_with_ttl(Key) ->
    delete({ttl, Key}).

match(Pattern) ->
    case ets:match(?DB, Pattern) of
        [] ->
            {error, empty};
        Match ->
            {ok, Match}
    end.

lookup(Key) ->
    case ets:lookup(?DB, Key) of
        [] ->
            {error, notfound};
        [{Key, Value} | _] ->
            {ok, Value};
        [Value | _] ->
            {ok, Value}
    end.

insert(Key, Value) ->
    ets:insert(?DB, {Key, Value}).

delete(Key) ->
    ets:delete(?DB, Key).

match_delete(Pattern) ->
    ets:match_delete(?DB, Pattern).


-spec(start_link() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).


init([]) ->
    ets:new(?DB, [public, named_table, ordered_set]),
    timer:send_after(1000, clean),
    {ok, #state{}}.


handle_call(_Request, _From, State = #state{}) ->
    {reply, ok, State}.


handle_cast(_Request, State = #state{}) ->
    {noreply, State}.

handle_info(clean, State) ->
    loop(ets:first(?DB)),
    timer:send_after(1000, clean),
    {noreply, State};
handle_info(_Info, State = #state{}) ->
    {noreply, State}.


terminate(_Reason, _State = #state{}) ->
    ok.

code_change(_OldVsn, State = #state{}, _Extra) ->
    {ok, State}.


loop('$end_of_table') ->
  ok;
loop({ttl, Key}) ->
  get_with_ttl(Key),
  loop(ets:next(?DB, {ttl, Key}));
loop(Key) ->
  loop(ets:next(?DB, Key)).
