%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2026, Tony Rogvall
%%% @doc
%%%    Behaviour for ellm backends.
%%%
%%%    All backends speak the same neutral message format:
%%%
%%%      #{ role => system | user, content => binary() }
%%%      #{ role => assistant, content => binary(),
%%%         tool_calls => [tool_call()],   %% optional
%%%         native => term() }             %% backend's own encoding
%%%      #{ role => tool, tool_call_id => binary(), content => binary(),
%%%         is_error => boolean() }        %% is_error optional
%%%
%%%    Tools are given as
%%%
%%%      #{ name => binary(), description => binary(), schema => map() }
%%%
%%%    where schema is a JSON schema for the tool arguments.
%%%
%%%    The `native' field of an assistant message holds the reply exactly
%%%    as the backend returned it, so it can be sent back unchanged on the
%%%    next turn (needed for Claude thinking blocks). A backend ignores
%%%    `native' it did not produce itself.
%%% @end
%%% Created : 12 Oct 2026 by Tony Rogvall <tony@rogvall.se>

-module(ellm_backend).

-export_type([role/0, message/0, tool/0, tool_call/0,
	      stop_reason/0, reply/0, options/0]).

-type role() :: system | user | assistant | tool.

-type tool_call() :: #{ id := binary(),
			name := binary(),
			arguments := map() }.

-type message() :: #{ role := role(),
		      content := binary(),
		      tool_calls => [tool_call()],
		      tool_call_id => binary(),
		      is_error => boolean(),
		      native => term() }.

-type tool() :: #{ name := binary(),
		   description := binary(),
		   schema := map() }.

-type stop_reason() :: stop | tool_calls | max_tokens | refusal |
		       pause | binary().

-type reply() :: #{ message := message(),
		    stop := stop_reason(),
		    usage => map(),
		    raw => map() }.

%% Merged options: application env for the backend overlaid with
%% the per call options. Common keys: model, max_tokens, tools.
-type options() :: #{ atom() => term() }.

-callback chat(Messages :: [message()], Options :: options()) ->
    {ok, reply()} | {error, Reason :: term()}.

-callback list_models(Options :: options()) ->
    {ok, [#{ id := binary(), created => integer() }]} |
    {error, Reason :: term()}.
