%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2026, Tony Rogvall
%%% @doc
%%%    Anthropic Claude backend (Messages API, /v1/messages)
%%%
%%%    Options (application env `{ellm, [{claude, [...]}]}' or per call):
%%%      baseurl    default "https://api.anthropic.com"
%%%      apikey     key | "$VAR" | ".authinfo"
%%%                 (default $ANTHROPIC_API_KEY, then ~/.authinfo
%%%                  machine api.anthropic.com or anthropic.com)
%%%      model      default "claude-opus-5-5"
%%%      max_tokens default 16000
%%%      effort     low | medium | high | xhigh | max (model default if unset)
%%%      fallbacks  "default" | none   server side fallback on refusal
%%%      tools      [ellm_backend:tool()]
%%% @end
%%% Created : 12 Oct 2026 by Tony Rogvall <tony@rogvall.se>

-module(ellm_claude).

-behaviour(ellm_backend).

-export([chat/2, list_models/1]).
%% exported for testing
-export([encode_request/2, decode_reply/1]).

-define(DEFAULT_BASEURL, "https://api.anthropic.com").
-define(DEFAULT_MODEL, <<"claude-opus-5-5">>).
-define(DEFAULT_MAX_TOKENS, 16000).
-define(API_VERSION, "2023-06-01").
-define(FALLBACK_BETA, "server-side-fallback-2026-07-01").

chat(Messages, Opts) ->
    case headers(Opts) of
	{ok, Hs} ->
	    Url = baseurl(Opts) ++ "/v1/messages",
	    Hs1 = case fallbacks(Opts) of
		      none -> Hs;
		      _ -> [{"anthropic-beta", ?FALLBACK_BETA} | Hs]
		  end,
	    case ellm_http:post_json(Url, Hs1, encode_request(Messages, Opts)) of
		{ok, Reply} -> {ok, decode_reply(Reply)};
		Error -> Error
	    end;
	Error ->
	    Error
    end.

list_models(Opts) ->
    case headers(Opts) of
	{ok, Hs} ->
	    list_models(baseurl(Opts) ++ "/v1/models?limit=1000", Hs, []);
	Error ->
	    Error
    end.

list_models(Url, Hs, Acc) ->
    case ellm_http:get_json(Url, Hs) of
	{ok, #{ <<"data">> := Data } = R} ->
	    Ms = [#{ id => Id,
		     name => maps:get(<<"display_name">>, M, Id),
		     created => created(maps:get(<<"created_at">>, M, null)) }
		  || M = #{ <<"id">> := Id } <- Data],
	    case R of
		#{ <<"has_more">> := true, <<"last_id">> := Last } ->
		    [Base|_] = string:split(Url, "&after_id="),
		    list_models(Base ++ "&after_id=" ++ binary_to_list(Last),
				Hs, Acc ++ Ms);
		_ ->
		    {ok, Acc ++ Ms}
	    end;
	{ok, Other} ->
	    {error, {unexpected, Other}};
	Error ->
	    Error
    end.

created(null) -> 0;
created(Rfc3339) ->
    try calendar:rfc3339_to_system_time(binary_to_list(Rfc3339))
    catch error:_ -> 0
    end.

%%
%% Request encoding
%%

encode_request(Messages, Opts) ->
    {System, Rest} = lists:splitwith(fun(#{ role := R }) -> R =:= system end,
				     Messages),
    Body0 = #{ <<"model">> => iolist_to_binary(maps:get(model, Opts,
							 ?DEFAULT_MODEL)),
	       <<"max_tokens">> => maps:get(max_tokens, Opts,
					    ?DEFAULT_MAX_TOKENS),
	       <<"messages">> => encode_messages(Rest) },
    Body1 = case System of
		[] -> Body0;
		_ -> Body0#{ <<"system">> =>
				 iolist_to_binary(
				   lists:join("\n\n",
					      [C || #{content := C} <- System]))}
	    end,
    Body2 = case maps:get(tools, Opts, []) of
		[] -> Body1;
		Tools -> Body1#{ <<"tools">> => [encode_tool(T) || T <- Tools] }
	    end,
    Body3 = case maps:get(effort, Opts, undefined) of
		undefined -> Body2;
		Effort -> Body2#{ <<"output_config">> =>
				      #{ <<"effort">> => to_bin(Effort) } }
	    end,
    case fallbacks(Opts) of
	none -> Body3;
	F -> Body3#{ <<"fallbacks">> => to_bin(F) }
    end.

encode_tool(#{ name := Name, description := Desc, schema := Schema }) ->
    #{ <<"name">> => Name,
       <<"description">> => Desc,
       <<"input_schema">> => Schema }.

%% Consecutive tool results must go back in ONE user message
encode_messages([]) ->
    [];
encode_messages([#{ role := tool } | _] = Ms) ->
    {Results, Rest} = lists:splitwith(fun(#{ role := R }) -> R =:= tool end,
				      Ms),
    [#{ <<"role">> => <<"user">>,
	<<"content">> => [tool_result(R) || R <- Results] }
    | encode_messages(Rest)];
encode_messages([M | Ms]) ->
    [encode_message(M) | encode_messages(Ms)].

encode_message(#{ role := assistant, native := {?MODULE, Content} }) ->
    #{ <<"role">> => <<"assistant">>, <<"content">> => Content };
encode_message(#{ role := assistant } = M) ->
    Text = case maps:get(content, M, <<>>) of
	       <<>> -> [];
	       C -> [#{ <<"type">> => <<"text">>, <<"text">> => C }]
	   end,
    Calls = [#{ <<"type">> => <<"tool_use">>,
		<<"id">> => Id,
		<<"name">> => Name,
		<<"input">> => Args }
	     || #{ id := Id, name := Name, arguments := Args }
		    <- maps:get(tool_calls, M, [])],
    #{ <<"role">> => <<"assistant">>, <<"content">> => Text ++ Calls };
encode_message(#{ role := Role, content := Content }) ->
    %% user, or a mid conversation system message
    #{ <<"role">> => atom_to_binary(Role), <<"content">> => Content }.

tool_result(#{ tool_call_id := Id, content := Content } = R) ->
    #{ <<"type">> => <<"tool_result">>,
       <<"tool_use_id">> => Id,
       <<"content">> => Content,
       <<"is_error">> => maps:get(is_error, R, false) }.

%%
%% Reply decoding
%%

decode_reply(#{ <<"content">> := Content } = R) ->
    Text = iolist_to_binary(
	     [T || #{ <<"type">> := <<"text">>, <<"text">> := T } <- Content]),
    Calls = [#{ id => Id, name => Name, arguments => Input }
	     || #{ <<"type">> := <<"tool_use">>, <<"id">> := Id,
		   <<"name">> := Name, <<"input">> := Input } <- Content],
    Message0 = #{ role => assistant, content => Text,
		  native => {?MODULE, Content} },
    Message = case Calls of
		  [] -> Message0;
		  _ -> Message0#{ tool_calls => Calls }
	      end,
    #{ message => Message,
       stop => stop_reason(maps:get(<<"stop_reason">>, R, null)),
       usage => maps:get(<<"usage">>, R, #{}),
       raw => R }.

stop_reason(<<"end_turn">>) -> stop;
stop_reason(<<"stop_sequence">>) -> stop;
stop_reason(<<"tool_use">>) -> tool_calls;
stop_reason(<<"max_tokens">>) -> max_tokens;
stop_reason(<<"refusal">>) -> refusal;
stop_reason(<<"pause_turn">>) -> pause;
stop_reason(Other) -> Other.

%%
%% Helpers
%%

headers(Opts) ->
    case ellm_http:api_key(Opts, "ANTHROPIC_API_KEY",
			   [url_host(baseurl(Opts)), "anthropic.com"]) of
	{ok, Key} ->
	    {ok, [{"x-api-key", Key},
		  {"anthropic-version", ?API_VERSION}]};
	Error ->
	    Error
    end.

baseurl(Opts) ->
    maps:get(baseurl, Opts, ?DEFAULT_BASEURL).

url_host(Url) ->
    maps:get(host, uri_string:parse(Url), "").

fallbacks(Opts) ->
    maps:get(fallbacks, Opts, "default").

to_bin(A) when is_atom(A) -> atom_to_binary(A);
to_bin(S) -> iolist_to_binary(S).
