%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2026, Tony Rogvall
%%% @doc
%%%    Ollama backend, uses the OpenAI compatible /v1/chat/completions
%%%    endpoint of an ollama server (message encoding is shared with
%%%    ellm_openai). Works with any OpenAI compatible server.
%%%
%%%    Options (application env `{ellm, [{ollama, [...]}]}' or per call):
%%%      baseurl    default "http://localhost:11434"
%%%      apikey     key | "$VAR" | ".authinfo"   (optional)
%%%                 default: only ~/.authinfo for the baseurl host,
%%%                 never $OPENAI_API_KEY or other backends' keys
%%%      model      default "llama3.1"
%%%      max_tokens optional
%%%      tools      [ellm_backend:tool()]
%%%
%%%    The context length is set on the server (OLLAMA_CONTEXT_LENGTH),
%%%    the OpenAI compatible endpoint can not change it.
%%% @end
%%% Created : 12 Oct 2026 by Tony Rogvall <tony@rogvall.se>

-module(ellm_ollama).

-behaviour(ellm_backend).

-export([chat/2, list_models/1]).
%% exported for testing
-export([encode_request/2, headers/1]).

-define(DEFAULT_BASEURL, "http://localhost:11434").
-define(DEFAULT_MODEL, "llama3.1").

chat(Messages, Opts) ->
    case headers(Opts) of
	{ok, Hs} ->
	    case ellm_http:post_json(baseurl(Opts) ++ "/v1/chat/completions",
				     Hs, encode_request(Messages, Opts)) of
		{ok, Reply} -> {ok, ellm_openai:decode_reply(Reply)};
		Error -> Error
	    end;
	Error ->
	    Error
    end.

%% local models from the native /api/tags
list_models(Opts) ->
    case headers(Opts) of
	{ok, Hs} ->
	    case ellm_http:get_json(baseurl(Opts) ++ "/api/tags", Hs) of
		{ok, #{ <<"models">> := Models }} ->
		    {ok, [#{ id => Name,
			     name => Name,
			     created => modified(M),
			     size => maps:get(<<"size">>, M, 0) }
			  || M = #{ <<"name">> := Name } <- Models]};
		{ok, Other} ->
		    {error, {unexpected, Other}};
		Error ->
		    Error
	    end;
	Error ->
	    Error
    end.

encode_request(Messages, Opts) ->
    Opts1 = maps:merge(#{ model => ?DEFAULT_MODEL },
		       maps:remove(max_tokens, Opts)),
    Body = ellm_openai:encode_request(Messages, Opts1),
    case maps:get(max_tokens, Opts, undefined) of
	undefined -> Body;
	N -> Body#{ <<"max_tokens">> => N }
    end.

%% ollama needs no key, send one only if configured for this server
headers(Opts) ->
    case ellm_http:api_key(Opts, baseurl(Opts), undefined, any) of
	{ok, Key} -> {ok, [{'Authorization', ["Bearer ", Key]}]};
	{error, no_api_key} -> {ok, []};
	Error -> Error
    end.

baseurl(Opts) ->
    maps:get(baseurl, Opts, ?DEFAULT_BASEURL).

modified(#{ <<"modified_at">> := T }) ->
    try calendar:rfc3339_to_system_time(binary_to_list(T))
    catch error:_ -> 0
    end;
modified(_) ->
    0.
