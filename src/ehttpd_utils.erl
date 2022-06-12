-module(ehttpd_utils).
-author("weixingzheng").
-include_lib("stdlib/include/qlc.hrl").

%% API
-export([query_table/4, check_module/1]).

-define(IGNORE_APPS, [
    kernel, sasl, crypto, public_key, asn1, syntax_tools,
    ssl, os_mon, inets, compiler, runtime_tools, redbug,
    xmerl, sasl, stdlib, appmon, eldap, erts, mnesia, inets,
    goldrush, gproc, snmp, otp_mibs, ssh, hipe, common_test,
    observer, webtool, xmerl, tools, debugger, eunit, et,
    wx
]).


query_table(Tab, PageNo, PageSize, RowFun) ->
    Qh = qlc:q([R || R <- ets:tab2list(Tab)]),
    Cursor = qlc:cursor(Qh),
    case PageNo > 1 of
        true -> qlc:next_answers(Cursor, (PageNo - 1) * PageSize);
        false -> ok
    end,
    Rows = qlc:next_answers(Cursor, PageSize),
    qlc:delete_cursor(Cursor),
    [RowFun(Row) || Row <- Rows].


check_module(Name) ->
    Fun =
        fun(Mod, {Handlers, Routers}) ->
            Handlers1 =
                case check_attributes(Name, Mod, ehttpd_rest) of
                    false -> Handlers;
                    true -> [Mod | Handlers]
                end,
            Routers1 =
                case check_attributes(Name, Mod, ehttpd_router) of
                    true -> [Mod | Routers];
                    false -> Routers
                end,
            {Handlers1, Routers1}
        end,
    filter_module(Fun).

filter_module(Check) ->
    Fun =
        fun(Dir, Acc) ->
            Re = ".+/(.+?)(-.+)?/ebin",
            case re:run(Dir, Re, [{capture, all_but_first, list}]) of
                {match, [App | _]} ->
                    case lists:member(list_to_atom(App), ?IGNORE_APPS) of
                        true ->
                            Acc;
                        false ->
                            lists:foldl(
                                fun(Mod, Acc1) ->
                                    Check(Mod, Acc1)
                                end, Acc, get_module(Dir))
                    end;
                _ ->
                    Acc
            end
        end,
    lists:foldl(Fun, {[], []}, code:get_path()).

check_attributes(Name, Mod, ehttpd_router) ->
    Fun = string:to_lower(lists:concat([Name, '_route'])),
    erlang:function_exported(Mod, list_to_atom(Fun), 1);
check_attributes(Name, Mod, ehttpd_rest) ->
    Fun = string:to_lower(lists:concat([Name, '_swagger'])),
    erlang:function_exported(Mod, list_to_atom(Fun), 1).

get_module(Dir) ->
    case file:list_dir(Dir) of
        {ok, FS} ->
            lists:foldl(
                fun(FileName, Acc) ->
                    case filename:extension(FileName) == ".beam" of
                        true ->
                            Mod = filename:basename(FileName, ".beam"),
                            [list_to_atom(Mod) | Acc];
                        false ->
                            Acc
                    end
                end, [], FS);
        {error, _Reason} ->
            []
    end.
