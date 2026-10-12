%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2023-2026, Tony Rogvall
%%% @doc
%%%    Erlang LLM client, one API over several backends.
%%%
%%%    Backends: claude (Anthropic), openai and ollama. The default backend
%%%    is the application env `backend' (claude), a call can override
%%%    it with the option `backend'.
%%%
%%%    Examples:
%%%      ellm:start().
%%%      ellm:ask("Vad är huvudstaden i Sverige?").
%%%      ellm:ask("...", #{ backend => openai }).
%%%      ellm:chat().                       %% prompt loop on stdin
%%%      ellm:run(Messages, Tools, Handler, #{}).  %% tool loop
%%% @end
%%% Created : 19 Jun 2023 by Tony Rogvall <tony@rogvall.se>

-module(ellm).

-export([start/0]).
-export([ask/1, ask/2]).
-export([chat/0, chat/1]).
-export([chat/2]).
-export([run/4, run/5]).
-export([models/0, models/1]).
-export([show_models/0, show_models/1]).
-export([select_model/0, select_model/1, select_model/2]).
-export([default_backend/0, set_backend/1]).
-export([backend_options/2]).

-define(APP, ellm).
-define(MAX_TOOL_ROUNDS, 25).

-type backend() :: claude | openai | ollama | module().
-type message() :: ellm_backend:message().
-type tool() :: ellm_backend:tool().

%% Handler for tool calls:
%%   fun(Name, Arguments, State) -> {ok|error, Result::iodata(), State}
-type tool_handler() ::
	fun((binary(), map(), term()) ->
		   {ok | error, iodata(), term()}).

start() ->
    application:ensure_all_started(?APP).

%%
%% Single question, returns the reply text
%%
-spec ask(Text::unicode:chardata()) -> {ok, binary()} | {error, term()}.
ask(Text) ->
    ask(Text, #{}).

-spec ask(Text::unicode:chardata(), Opts::map()) ->
	  {ok, binary()} | {error, term()}.
ask(Text, Opts) ->
    Message = #{ role => user, content => unicode:characters_to_binary(Text) },
    case chat([Message], Opts) of
	{ok, #{ message := #{ content := Content } }} -> {ok, Content};
	Error -> Error
    end.

%%
%% One request to the backend
%%
-spec chat(Messages::[message()], Opts::map()) ->
	  {ok, ellm_backend:reply()} | {error, term()}.
chat(Messages, Opts) ->
    {Mod, Opts1} = resolve(Opts),
    Mod:chat(Messages, Opts1).

%%
%% Tool loop: send Messages, run requested tools with Handler and
%% send the results back until the model stops asking for tools.
%% Returns the full message list (including the final reply).
%%
-spec run(Messages::[message()], Tools::[tool()],
	  Handler::tool_handler(), Opts::map()) ->
	  {ok, [message()]} | {error, term()}.
run(Messages, Tools, Handler, Opts) ->
    case run(Messages, Tools, Handler, undefined, Opts) of
	{ok, Messages1, _State} -> {ok, Messages1};
	Error -> Error
    end.

-spec run(Messages::[message()], Tools::[tool()],
	  Handler::tool_handler(), State::term(), Opts::map()) ->
	  {ok, [message()], term()} | {error, term()}.
run(Messages, Tools, Handler, State, Opts) ->
    run_(Messages, Handler, State, Opts#{ tools => Tools },
	 maps:get(max_rounds, Opts, ?MAX_TOOL_ROUNDS)).

run_(_Messages, _Handler, _State, _Opts, 0) ->
    {error, too_many_tool_rounds};
run_(Messages, Handler, State, Opts, Rounds) ->
    case chat(Messages, Opts) of
	{ok, #{ message := Reply, stop := Stop }} ->
	    Messages1 = Messages ++ [Reply],
	    print_text(Reply, Opts),
	    case {Stop, maps:get(tool_calls, Reply, [])} of
		{tool_calls, Calls} when Calls =/= [] ->
		    {Results, State1} = call_tools(Calls, Handler, State),
		    run_(Messages1 ++ Results, Handler, State1, Opts, Rounds-1);
		{pause, _} ->
		    %% server tool paused a long turn, just continue
		    run_(Messages1, Handler, State, Opts, Rounds-1);
		{stop, _} ->
		    {ok, Messages1, State};
		{Other, _} ->
		    logger:warning("ellm: stopped with ~p", [Other]),
		    {ok, Messages1, State}
	    end;
	Error ->
	    Error
    end.

call_tools([#{ id := Id, name := Name, arguments := Args } | Calls],
	   Handler, State) ->
    {Status, Result, State1} =
	try Handler(Name, Args, State)
	catch
	    Class:Reason:Stack ->
		logger:error("ellm: tool ~s crashed ~p:~p ~p",
			     [Name, Class, Reason, Stack]),
		{error, io_lib:format("~p", [Reason]), State}
	end,
    Message = #{ role => tool,
		 tool_call_id => Id,
		 content => unicode:characters_to_binary(Result),
		 is_error => Status =:= error },
    {Results, State2} = call_tools(Calls, Handler, State1),
    {[Message | Results], State2};
call_tools([], _Handler, State) ->
    {[], State}.

print_text(#{ content := Text }, Opts) when Text =/= <<>> ->
    case maps:get(verbose, Opts, true) of
	true -> io:format("~ts\n", [Text]);
	false -> ok
    end;
print_text(_, _) ->
    ok.

%%
%% Prompt reply loop on standard input, "bye", "quit" or eof stops.
%% Options: backend, model, system => SystemPrompt, log => Filename
%%
chat() ->
    chat(#{}).

chat(Opts) when is_map(Opts) ->
    io:setopts(standard_io, [{encoding, unicode}]),
    Log = case maps:get(log, Opts, undefined) of
	      undefined -> undefined;
	      File -> {ok, Fd} = file:open(File, [write, {encoding, utf8}]), Fd
	  end,
    Messages = case maps:get(system, Opts, undefined) of
		   undefined -> [];
		   S -> [#{ role => system,
			    content => unicode:characters_to_binary(S) }]
	       end,
    {Mod, Opts1} = resolve(Opts),
    io:format("[~s ~s]\n", [Mod, maps:get(model, Opts1, "")]),
    try chat_loop(1, Messages, Mod, Opts1, Log)
    after
	Log =/= undefined andalso file:close(Log)
    end.

chat_loop(I, Messages, Mod, Opts, Log) ->
    case io:get_line(integer_to_list(I)++"|> ") of
	eof -> ok;
	{error, _} -> ok;
	Line ->
	    case string:trim(unicode:characters_to_binary(Line)) of
		<<"bye">> -> ok;
		<<"quit">> -> ok;
		<<>> -> chat_loop(I, Messages, Mod, Opts, Log);
		Input ->
		    Prompt = #{ role => user, content => Input },
		    Messages1 = Messages ++ [Prompt],
		    case Mod:chat(Messages1, Opts) of
			{ok, #{ message := Reply }} ->
			    io:format("\n~ts\n\n", [maps:get(content, Reply)]),
			    log(Log, [Prompt, maps:remove(native, Reply)]),
			    chat_loop(I+1, Messages1 ++ [Reply], Mod, Opts, Log);
			{error, Reason} ->
			    io:format("**ERROR** ~p\n", [Reason]),
			    chat_loop(I, Messages, Mod, Opts, Log)
		    end
	    end
    end.

log(undefined, _) -> ok;
log(Fd, Terms) -> [io:format(Fd, "~tp.\n", [T]) || T <- Terms], ok.

%%
%% Models
%%
models() ->
    models(default_backend()).

models(Backend) ->
    {Mod, Opts} = resolve(#{ backend => Backend }),
    Mod:list_models(Opts).

show_models() ->
    show_models(default_backend()).

show_models(Backend) ->
    case numbered_models(Backend) of
	{ok, Models} -> print_numbered_models(Backend, Models);
	Error -> Error
    end.

select_model() ->
    select_model(default_backend()).

%% select_model(Backend) asks interactively
select_model(Backend) when is_atom(Backend) ->
    {ok, Models} = numbered_models(Backend),
    print_numbered_models(Backend, Models),
    N = length(Models),
    Line = io:get_line(io_lib:format("Select model: [1-~w]: ", [N])),
    try list_to_integer(string:trim(Line)) of
	I when I > 0, I =< N ->
	    {I, ID, _} = lists:nth(I, Models),
	    set_model(Backend, ID),
	    {ok, ID};
	_ ->
	    {error, bad_selection}
    catch
	error:badarg ->
	    {error, bad_selection}
    end.

select_model(Backend, Model) ->
    Model1 = iolist_to_binary([Model]),
    {ok, Models} = numbered_models(Backend),
    case lists:keyfind(Model1, 2, Models) of
	false -> {error, {bad_model, Model}};
	_ -> set_model(Backend, Model1)
    end.

set_model(Backend, Model) ->
    Env = application:get_env(?APP, Backend, []),
    application:set_env(?APP, Backend,
			lists:keystore(model, 1, Env,
				       {model, binary_to_list(Model)})).

numbered_models(Backend) ->
    case models(Backend) of
	{ok, Ms} ->
	    Sorted = lists:sort(fun(#{ id := A }, #{ id := B }) -> A =< B end,
				Ms),
	    {ok, lists:zip3(lists:seq(1, length(Sorted)),
			    [Id || #{ id := Id } <- Sorted],
			    [maps:get(created, M, 0) || M <- Sorted])};
	Error ->
	    Error
    end.

print_numbered_models(Backend, Models) ->
    {_, Opts} = resolve(#{ backend => Backend }),
    Current = iolist_to_binary(maps:get(model, Opts, "")),
    io:format("Current model: ~s\n", [Current]),
    lists:foreach(
      fun({I, ID, Created}) ->
	      Date = if Created > 0 ->
			     calendar:system_time_to_rfc3339(Created);
			true -> ""
		     end,
	      Mark = if ID =:= Current -> "*"; true -> "" end,
	      io:format("~w~s: ~s [~s]\n", [I, Mark, ID, Date])
      end, Models).

%%
%% Backend selection and options
%%
default_backend() ->
    application:get_env(?APP, backend, claude).

set_backend(Backend) ->
    application:set_env(?APP, backend, Backend).

%% Merge application env for Backend with call options
backend_options(Backend, Opts) ->
    application:load(?APP),
    Env = maps:from_list(application:get_env(?APP, Backend, [])),
    maps:merge(Env, maps:remove(backend, Opts)).

-spec resolve(Opts::map()) -> {module(), map()}.
resolve(Opts) ->
    Backend = maps:get(backend, Opts, default_backend()),
    {backend_module(Backend), backend_options(Backend, Opts)}.

-spec backend_module(backend()) -> module().
backend_module(claude) -> ellm_claude;
backend_module(openai) -> ellm_openai;
backend_module(ollama) -> ellm_ollama;
backend_module(Mod) when is_atom(Mod) -> Mod.
