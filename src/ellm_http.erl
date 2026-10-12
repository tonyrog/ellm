%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2026, Tony Rogvall
%%% @doc
%%%    HTTP and credential helpers shared by the ellm backends.
%%% @end
%%% Created : 12 Oct 2026 by Tony Rogvall <tony@rogvall.se>

-module(ellm_http).

-include_lib("rester/include/rester_http.hrl").

-export([get_json/2]).
-export([post_json/3]).
-export([post/4]).
-export([api_key/3]).
-export([get_auth_info/1, get_auth_info/2]).

%% GET Url and decode a JSON reply
-spec get_json(Url::string(), Headers::[{term(),term()}]) ->
	  {ok, term()} | {error, term()}.
get_json(Url, Hs) ->
    logger:debug("ellm GET ~s", [Url]),
    reply(rester_http:wget(Url, [{'Accept',"application/json"}|Hs])).

%% POST a JSON body (map) and decode a JSON reply
-spec post_json(Url::string(), Headers::[{term(),term()}], Body::map()) ->
	  {ok, term()} | {error, term()}.
post_json(Url, Hs, Body) ->
    post(Url, Hs, "application/json", Body).

%% POST with given content type; Data is a map for "application/json"
%% or a rester multipart list for "multipart/form-data".
%% A JSON reply is decoded, other replies are returned as
%% {ok, {ContentType, Binary}}.
post(Url, Hs, ContentType, Data) ->
    logger:debug("ellm POST ~s ~p", [Url, Data]),
    Hs1 = [{'Content-Type', ContentType} | Hs],
    reply(rester_http:wpost(Url, Hs1, Data)).

reply({ok, Resp, Body}) ->
    Status = Resp#http_response.status,
    Headers = Resp#http_response.headers,
    Decoded = decode_body(Headers#http_shdr.content_type, Body),
    if Status >= 200, Status < 300 ->
	    {ok, Decoded};
       true ->
	    %% keep the error body, it explains what went wrong
	    {error, {http, Status, Decoded}}
    end;
reply({error, Reason}) ->
    {error, Reason}.

decode_body("application/json"++_, Body) when byte_size(Body) > 0 ->
    try json:decode(Body)
    catch error:_ -> Body
    end;
decode_body(undefined, Body) ->
    Body;
decode_body(ContentType, Body) ->
    {ContentType, Body}.

%%
%% Find the api key. Opts may contain apikey with:
%%   "sk-..."       the key itself
%%   "$VAR"         read from environment variable VAR
%%   ".authinfo"    look up Host in ~/.authinfo
%% If not set, try the environment variable EnvVar, then ~/.authinfo.
%% ~/.authinfo is searched for each host in Hosts, in order.
%%
-spec api_key(Opts::map(), EnvVar::string(), Hosts::[string()]) ->
	  {ok, binary()} | {error, no_api_key}.
api_key(Opts, EnvVar, Hosts) ->
    Authinfo = [fun() -> authinfo_key(H) end || H <- Hosts],
    case maps:get(apikey, Opts, undefined) of
	undefined ->
	    first([fun() -> env_key(EnvVar) end | Authinfo]);
	".authinfo" ->
	    first(Authinfo);
	"$"++Var ->
	    env_key(Var);
	Key ->
	    {ok, iolist_to_binary(Key)}
    end.

first([F|Fs]) ->
    case F() of
	{ok, Key} -> {ok, Key};
	_ -> first(Fs)
    end;
first([]) ->
    {error, no_api_key}.

env_key(Var) ->
    case os:getenv(Var) of
	false -> {error, no_api_key};
	"" -> {error, no_api_key};
	Key -> {ok, list_to_binary(Key)}
    end.

authinfo_key(Host) ->
    case get_auth_info(Host) of
	{_User, Key} -> {ok, Key};
	_ -> {error, no_api_key}
    end.

%% machine HOST login NAME password VALUE port NUMBER
%% fixme: support gpg formatted file!
get_auth_info(Host) ->
    AuthInfoFilename = filename:join(os:getenv("HOME"),".authinfo"),
    get_auth_info(Host, AuthInfoFilename).

get_auth_info(Host, Filename) ->
    case file:open(Filename, [binary, read]) of
	{ok, Fd} ->
	    try get_auth_info_(Fd, iolist_to_binary(Host))
	    after
		file:close(Fd)
	    end;
	Error ->
	    Error
    end.

get_auth_info_(Fd, Host) ->
    case file:read_line(Fd) of
	{ok, Line} ->
	    case binary:split(string:trim(Line), <<" ">>, [global,trim_all]) of
		[<<"machine">>,Host,<<"login">>,User,<<"password">>,Key|_] ->
		    {User,Key};
		[<<"machine">>,Host,<<"login">>,User,<<"apikey">>,Key|_] ->
		    {User,Key};
		_Line ->
		    get_auth_info_(Fd, Host)
	    end;
	eof ->
	    false
    end.
