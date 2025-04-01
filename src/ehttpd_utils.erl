-module(ehttpd_utils).
-author("weixingzheng").
-include_lib("stdlib/include/qlc.hrl").

%% API
-export([md5/1, filename_join/2, get_log/1, apply_module_attributes/2]).

md5(V) ->
    list_to_binary(lists:flatten([io_lib:format("~2.16.0b", [C]) || <<C>> <= erlang:md5(V)])).


filename_join(Dir, <<"/", Path/binary>>) ->
    filename_join(Dir, Path);
filename_join(Dir, Path) ->
    filename:join([Dir, Path]).

apply_module_attributes(Name, SerName) ->
    [Module || {_App, Module, Attrs} <- all_module_attributes(Name), lists:member(SerName, Attrs)].

%% Copy from rabbit_misc.erl
all_module_attributes(Name) ->
    Targets =
        lists:usort(
            lists:append(
                [[{App, Module} || Module <- Modules] ||
                    {App, _, _}   <- ignore_lib_apps(application:loaded_applications()),
                    {ok, Modules} <- [application:get_key(App, modules)]])),
    lists:foldl(
        fun ({App, Module}, Acc) ->
            case lists:append([Atts || {N, Atts} <- module_attributes(Module),
                N =:= Name]) of
                []   -> Acc;
                Atts -> [{App, Module, Atts} | Acc]
            end
        end, [], Targets).

module_attributes(Module) ->
    case catch Module:module_info(attributes) of
        {'EXIT', {undef, [{Module, module_info, [attributes], []} | _]}} ->
            [];
        {'EXIT', Reason} ->
            exit(Reason);
        V ->
            V
    end.

ignore_lib_apps(Apps) ->
    LibApps = [kernel, stdlib, sasl, appmon, eldap, erts,
        syntax_tools, ssl, crypto, mnesia, os_mon,
        inets, goldrush, gproc, runtime_tools,
        snmp, otp_mibs, public_key, asn1, ssh, hipe,
        common_test, observer, webtool, xmerl, tools,
        test_server, compiler, debugger, eunit, et,
        wx],
    [App || App = {Name, _, _} <- Apps, not lists:member(Name, LibApps)].




get_log(Req) ->
    Path = cowboy_req:path(Req),
    UserAgent = cowboy_req:header(<<"user-agent">>, Req),
    Peer = get_peer(Req),
    Method = cowboy_req:method(Req),
    #{
        <<"Method">> => Method,
        <<"UserAgent">> => UserAgent,
        <<"OS">> => get_os(Req, UserAgent),
        <<"Path">> => Path,
        <<"Peer">> => Peer
    }.

get_os(Req, UserAgent) ->
    case cowboy_req:header(<<"sec-ch-ua-platform">>, Req) of
        undefined ->
            case re:run(UserAgent, <<"Mac|Windows|IOS|Android|HarmonyOS|Linux">>, [{capture,all,binary}]) of
                {match, [Os|_]} -> Os;
                nomatch -> undefined
            end;
        Os ->
            re:replace(Os, <<"\"">>, <<>>, [global, {return, binary}])
    end.

get_peer(Req) ->
    case cowboy_req:header(<<"x-real-ip">>, Req) of
        undefined ->
            {Addr, Port} = cowboy_req:peer(Req),
            list_to_binary(inet:ntoa(Addr) ++ ":" ++ integer_to_list(Port));
        Peer ->
            Peer
    end.

