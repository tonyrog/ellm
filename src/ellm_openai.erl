%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2023-2026, Tony Rogvall
%%% @doc
%%%    OpenAI backend (/v1/chat/completions) plus the OpenAI only
%%%    audio and file endpoints.
%%%
%%%    Options (application env `{ellm, [{openai, [...]}]}' or per call):
%%%      baseurl    default "https://api.openai.com"
%%%      apikey     key | "$VAR" | ".authinfo"
%%%                 (default $OPENAI_API_KEY, then ~/.authinfo
%%%                  machine api.openai.com or openai.com)
%%%      model      default "gpt-4o"
%%%      max_tokens optional (sent as max_completion_tokens)
%%%      tools      [ellm_backend:tool()]
%%% @end
%%% Created : 19 Jun 2023 by Tony Rogvall <tony@rogvall.se>

-module(ellm_openai).

-behaviour(ellm_backend).

-export([chat/2, list_models/1]).
-export([transcribe/1, transcribe/2]).
-export([translate/1, translate/2]).
-export([speech/1, speech/2]).
-export([upload/1]).
%% exported for testing
-export([encode_request/2, decode_reply/1, headers/1]).

-define(DEFAULT_BASEURL, "https://api.openai.com").
-define(DEFAULT_MODEL, <<"gpt-4o">>).

chat(Messages, Opts) ->
    case post_json(Opts, "/v1/chat/completions",
		   encode_request(Messages, Opts)) of
	{ok, Reply} -> {ok, decode_reply(Reply)};
	Error -> Error
    end.

list_models(Opts) ->
    case headers(Opts) of
	{ok, Hs} ->
	    case ellm_http:get_json(baseurl(Opts) ++ "/v1/models", Hs) of
		{ok, #{ <<"data">> := Data }} ->
		    {ok, [#{ id => Id,
			     name => Id,
			     created => maps:get(<<"created">>, M, 0) }
			  || M = #{ <<"id">> := Id } <- Data]};
		{ok, Other} ->
		    {error, {unexpected, Other}};
		Error ->
		    Error
	    end;
	Error ->
	    Error
    end.

%%
%% Request encoding
%%

encode_request(Messages, Opts) ->
    Body0 = #{ <<"model">> => iolist_to_binary(maps:get(model, Opts,
							 ?DEFAULT_MODEL)),
	       <<"messages">> => [encode_message(M) || M <- Messages] },
    Body1 = case maps:get(tools, Opts, []) of
		[] -> Body0;
		Tools -> Body0#{ <<"tools">> => [encode_tool(T) || T <- Tools] }
	    end,
    case maps:get(max_tokens, Opts, undefined) of
	undefined -> Body1;
	N -> Body1#{ <<"max_completion_tokens">> => N }
    end.

encode_tool(#{ name := Name, description := Desc, schema := Schema }) ->
    #{ <<"type">> => <<"function">>,
       <<"function">> => #{ <<"name">> => Name,
			    <<"description">> => Desc,
			    <<"parameters">> => Schema } }.

encode_message(#{ role := assistant, native := {?MODULE, Message} }) ->
    Message;
encode_message(#{ role := assistant } = M) ->
    Base = #{ <<"role">> => <<"assistant">>,
	      <<"content">> => maps:get(content, M, <<>>) },
    case maps:get(tool_calls, M, []) of
	[] -> Base;
	Calls ->
	    Base#{ <<"tool_calls">> =>
		       [#{ <<"id">> => Id,
			   <<"type">> => <<"function">>,
			   <<"function">> =>
			       #{ <<"name">> => Name,
				  <<"arguments">> => iolist_to_binary(
						       json:encode(Args)) } }
			|| #{ id := Id, name := Name, arguments := Args }
			       <- Calls] }
    end;
encode_message(#{ role := tool, tool_call_id := Id, content := Content }) ->
    #{ <<"role">> => <<"tool">>,
       <<"tool_call_id">> => Id,
       <<"content">> => Content };
encode_message(#{ role := Role, content := Content }) ->
    #{ <<"role">> => atom_to_binary(Role), <<"content">> => Content }.

%%
%% Reply decoding
%%

decode_reply(#{ <<"choices">> := [Choice|_] } = R) ->
    #{ <<"message">> := Message } = Choice,
    Text = case maps:get(<<"content">>, Message, null) of
	       null -> <<>>;
	       T -> T
	   end,
    Calls = [#{ id => Id, name => Name, arguments => decode_args(Args) }
	     || #{ <<"id">> := Id,
		   <<"function">> := #{ <<"name">> := Name,
					<<"arguments">> := Args } }
		    <- tool_calls(Message)],
    Message0 = #{ role => assistant, content => Text,
		  native => {?MODULE, Message} },
    Message1 = case Calls of
		   [] -> Message0;
		   _ -> Message0#{ tool_calls => Calls }
	       end,
    #{ message => Message1,
       stop => stop_reason(maps:get(<<"finish_reason">>, Choice, null)),
       usage => maps:get(<<"usage">>, R, #{}),
       raw => R }.

tool_calls(#{ <<"tool_calls">> := Calls }) when is_list(Calls) -> Calls;
tool_calls(_) -> [].

%% arguments is a JSON string, sometimes not valid JSON
decode_args(Args) ->
    try json:decode(Args)
    catch error:_ -> #{ <<"_raw">> => Args }
    end.

stop_reason(<<"stop">>) -> stop;
stop_reason(<<"tool_calls">>) -> tool_calls;
stop_reason(<<"length">>) -> max_tokens;
stop_reason(<<"content_filter">>) -> refusal;
stop_reason(Other) -> Other.

%%
%% Audio and files (OpenAI only)
%%

transcribe(AudioFilename) ->
    transcribe(AudioFilename, []).
transcribe(AudioFilename, Opts) ->
    post_audio("/v1/audio/transcriptions", AudioFilename, Opts).

translate(AudioFilename) ->
    translate(AudioFilename, []).
translate(AudioFilename, Opts) ->
    post_audio("/v1/audio/translations", AudioFilename, Opts).

post_audio(Path, AudioFilename, Opts) ->
    post_multipart(ellm:backend_options(openai, #{}), Path,
		   [{data, "model", "whisper-1"} |
		    [{data, Key, Value} || {Key,Value} <- Opts]] ++
		       [{file,"file","application/octet-stream",AudioFilename}]).

upload(Filename) ->
    post_multipart(ellm:backend_options(openai, #{}), "/v1/files",
		   [{data, "purpose", "assistants"},
		    {file,"file", "application/octet-stream",Filename}]).

%%
%% options:
%%   model => 'tts-1' | 'tts-1-hd'
%%   voice => alloy|echo|fable|onyx|nova|shimmer
%%   format => mp3 | opus | aac | flac
%% returns {ok, {"audio/...", Binary}}
%%
speech(Text) ->
    speech(Text, #{}).
speech(Text, Options) ->
    Format = maps:get(format, Options, mp3),
    Body = #{ <<"model">> => to_bin(maps:get(model, Options, 'tts-1')),
	      <<"input">> => unicode:characters_to_binary(Text),
	      <<"voice">> => to_bin(maps:get(voice, Options, alloy)),
	      <<"response_format">> => to_bin(Format) },
    post_json(ellm:backend_options(openai, #{}), "/v1/audio/speech", Body).

%%
%% Helpers
%%

post_json(Opts, Path, Body) ->
    case headers(Opts) of
	{ok, Hs} -> ellm_http:post_json(baseurl(Opts) ++ Path, Hs, Body);
	Error -> Error
    end.

post_multipart(Opts, Path, Data) ->
    case headers(Opts) of
	{ok, Hs} -> ellm_http:post(baseurl(Opts) ++ Path, Hs,
				   "multipart/form-data", Data);
	Error -> Error
    end.

headers(Opts) ->
    case ellm_http:api_key(Opts, baseurl(Opts), "OPENAI_API_KEY",
			   "openai.com") of
	{ok, Key} -> {ok, [{'Authorization', ["Bearer ", Key]}]};
	Error -> Error
    end.

baseurl(Opts) ->
    maps:get(baseurl, Opts, ?DEFAULT_BASEURL).

to_bin(A) when is_atom(A) -> atom_to_binary(A);
to_bin(S) -> iolist_to_binary(S).
