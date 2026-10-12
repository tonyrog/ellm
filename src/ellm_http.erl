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
-export([api_key/4]).
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
%% Find the api key for a request to Url. Opts may contain apikey with:
%%   "sk-..."       the key itself
%%   "$VAR"         read from environment variable VAR
%%   ".authinfo"    look up the host of Url in the authinfo file
%% If not set, try the environment variable EnvVar, then the
%% authinfo file for the host of Url and then for Domain.
%%
%% A key must not leak to another server, so only a key stored in the
%% authinfo file under the exact host of Url is used everywhere (but
%% not over plain http to the known vendor domains). All other keys
%% (apikey option, environment, Domain entry) are only used when Url
%% is https and its host is Domain or a subdomain of it.
%% Domain 'any' (backends with no home server, like ollama) trusts
%% explicit apikey options but never reads EnvVar or a Domain entry.
%%
%% Opts may contain authinfo => Filename (default ~/.authinfo).
%%
-spec api_key(Opts::map(), Url::string(), EnvVar::string()|undefined,
	      Domain::string()|any) ->
	  {ok, binary()} | {error, no_api_key | {untrusted_host, string()}}.
api_key(Opts, Url, EnvVar, Domain) ->
    #{ host := Host } = U = uri_string:parse(Url),
    Trusted = trusted(maps:get(scheme, U, ""), Host, Domain),
    AuthFile = maps:get(authinfo, Opts, default_authinfo()),
    HostKey = case vendor_host(Host) andalso
		      maps:get(scheme, U, "") =/= "https" of
		  true -> [];
		  false -> [fun() -> authinfo_key(Host, AuthFile) end]
	      end,
    {EnvKey, DomainKey} =
	if Trusted, Domain =/= any ->
		{[fun() -> env_key(EnvVar) end],
		 [fun() -> authinfo_key(Domain, AuthFile) end]};
	   true ->
		{[], []}
	end,
    case maps:get(apikey, Opts, undefined) of
	undefined ->
	    first(EnvKey ++ HostKey ++ DomainKey);
	".authinfo" ->
	    first(HostKey ++ DomainKey);
	_ when not Trusted ->
	    {error, {untrusted_host, Host}};
	"$"++Var ->
	    env_key(Var);
	Key ->
	    {ok, iolist_to_binary(Key)}
    end.

-define(VENDOR_DOMAINS, ["openai.com", "anthropic.com"]).

trusted(_Scheme, _Host, any) -> true;
trusted("https", Host, Domain) -> in_domain(Host, Domain);
trusted(_Scheme, _Host, _Domain) -> false.

vendor_host(Host) ->
    lists:any(fun(D) -> in_domain(Host, D) end, ?VENDOR_DOMAINS).

in_domain(Host, Domain) ->
    H = string:lowercase(Host),
    D = string:lowercase(Domain),
    (H =:= D) orelse lists:suffix("." ++ D, H).

first([F|Fs]) ->
    case F() of
	{ok, Key} -> {ok, Key};
	_ -> first(Fs)
    end;
first([]) ->
    {error, no_api_key}.

env_key(undefined) ->
    {error, no_api_key};
env_key(Var) ->
    case os:getenv(Var) of
	false -> {error, no_api_key};
	"" -> {error, no_api_key};
	Key -> {ok, list_to_binary(Key)}
    end.

authinfo_key(Host, Filename) ->
    case get_auth_info(Host, Filename) of
	{_User, Key} -> {ok, Key};
	_ -> {error, no_api_key}
    end.

%% machine HOST login NAME password VALUE port NUMBER
%% fixme: support gpg formatted file!
get_auth_info(Host) ->
    get_auth_info(Host, default_authinfo()).

default_authinfo() ->
    filename:join(os:getenv("HOME"),".authinfo").

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
