%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2026, Tony Rogvall
%%% @doc
%%%    Tests that api keys only go to the server they belong to,
%%%    and of the ollama backend against a fake local server.
%%%
%%%    All keys are fake. The environment variables and the authinfo
%%%    file are replaced during the tests, ~/.authinfo is never read.
%%%
%%%      make test
%%%      eunit:test(ellm_key_tests, [verbose]).
%%% @end
%%% Created : 12 Oct 2026 by Tony Rogvall <tony@rogvall.se>

-module(ellm_key_tests).

-include_lib("eunit/include/eunit.hrl").

-define(ENV_KEYS, [{"OPENAI_API_KEY", "sk-ENV-OPENAI"},
		   {"ANTHROPIC_API_KEY", "sk-ENV-ANTHROPIC"},
		   {"OLLAMA_API_KEY", "sk-ENV-OLLAMA"}]).

-define(AUTHINFO,
	"machine api.openai.com login u apikey sk-AUTH-API-OPENAI\n"
	"machine openai.com login u apikey sk-AUTH-OPENAI\n"
	"machine api.anthropic.com login u apikey sk-AUTH-API-ANTHROPIC\n"
	"machine anthropic.com login u apikey sk-AUTH-ANTHROPIC\n"
	"machine ollama.lan login u apikey OLLAMA-LAN-KEY\n").

%% every fake secret above contains one of these
-define(SECRET_MARKS, [<<"sk-">>, <<"OLLAMA-LAN-KEY">>]).

%%
%% Fixture: fake environment and authinfo file
%%

keys_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     fun(#{ authinfo := File }) ->
	     O = fun(M) -> M#{ authinfo => File } end,
	     [{"openai default server uses env key",
	       ?_assertEqual({ok, [{'Authorization', ["Bearer ", <<"sk-ENV-OPENAI">>]}]},
			     ellm_openai:headers(O(#{})))},
	      {"claude default server uses env key",
	       ?_assertMatch({ok, [{"x-api-key", <<"sk-ENV-ANTHROPIC">>}|_]},
			     ellm_claude:headers(O(#{})))},
	      {"no env: authinfo for exact host first",
	       ?_assertEqual({ok, <<"sk-AUTH-API-OPENAI">>},
			     without_env(fun() -> key(openai, O(#{})) end))},
	      {"no env: authinfo domain entry for subdomain",
	       ?_assertEqual({ok, <<"sk-AUTH-OPENAI">>},
			     without_env(
			       fun() -> key(openai, O(#{ baseurl => "https://eu.api.openai.com" })) end))},
	      {"openai backend on other host gets no key",
	       ?_assertEqual({error, no_api_key},
			     key(openai, O(#{ baseurl => "http://gpu.lan:11434" })))},
	      {"other host only gets its own authinfo key",
	       ?_assertEqual({ok, <<"OLLAMA-LAN-KEY">>},
			     key(openai, O(#{ baseurl => "http://ollama.lan:11434" })))},
	      {"openai over plain http gets no key",
	       ?_assertEqual({error, no_api_key},
			     key(openai, O(#{ baseurl => "http://api.openai.com" })))},
	      {"look alike hosts get no key",
	       [?_assertEqual({error, no_api_key},
			      key(openai, O(#{ baseurl => Url })))
		|| Url <- ["https://api.openai.com.evil.example",
			   "https://evilopenai.com",
			   "https://openai.com.evil.example/v1"]]},
	      {"claude backend on other host gets no key",
	       ?_assertEqual({error, no_api_key},
			     key(claude, O(#{ baseurl => "https://localhost:8080" })))},
	      {"explicit key refused for untrusted host",
	       [?_assertEqual({error, {untrusted_host, "ollama.lan"}},
			      key(openai, O(#{ baseurl => "http://ollama.lan:11434",
					       apikey => K })))
		|| K <- ["sk-LITERAL", "$OPENAI_API_KEY"]]},
	      {"explicit .authinfo only looks at the request host",
	       ?_assertEqual({error, no_api_key},
			     key(openai, O(#{ baseurl => "https://openai.example",
					      apikey => ".authinfo" })))},
	      {"ollama default sends no key at all",
	       ?_assertEqual({ok, []}, ellm_ollama:headers(O(#{})))},
	      {"ollama never uses other backends' keys",
	       [?_assertEqual({ok, []},
			      ellm_ollama:headers(O(#{ baseurl => Url })))
		|| Url <- ["http://localhost:11434",
			   "http://api.openai.com",
			   "http://api.anthropic.com",
			   "https://openai.example"]]},
	      {"ollama uses authinfo for its own host",
	       ?_assertEqual({ok, [{'Authorization', ["Bearer ", <<"OLLAMA-LAN-KEY">>]}]},
			     ellm_ollama:headers(O(#{ baseurl => "http://ollama.lan:11434" })))},
	      {"ollama explicit key is used",
	       ?_assertEqual({ok, [{'Authorization', ["Bearer ", <<"sk-ENV-OLLAMA">>]}]},
			     ellm_ollama:headers(O(#{ apikey => "$OLLAMA_API_KEY" })))}
	     ]
     end}.

%%
%% Requests to a fake local server: check what is actually sent
%%

wire_test_() ->
    {setup, fun() -> S = setup(), {ok, _} = ellm:start(), S end,
     fun cleanup/1,
     fun(#{ authinfo := File }) ->
	     O = fun(M) -> M#{ authinfo => File } end,
	     [{"ollama request carries no key",
	       fun() ->
		       {Url, Server} = fake_server([completion(<<"Hej!">>)]),
		       ?assertEqual({ok, <<"Hej!">>},
				    ellm:ask("Hej", O(#{ backend => ollama,
							 baseurl => Url }))),
		       [Req] = requests(Server),
		       assert_no_secret(Req),
		       ?assertEqual(undefined, header(<<"authorization">>, Req)),
		       ?assertMatch(#{ <<"model">> := <<"llama3.1">> },
				    json:decode(body(Req)))
	       end},
	      {"openai and claude refuse a local server before connecting",
	       fun() ->
		       {Url, Server} = fake_server([]),
		       ?assertEqual({error, no_api_key},
				    ellm:ask("Hej", O(#{ backend => openai,
							 baseurl => Url }))),
		       ?assertEqual({error, no_api_key},
				    ellm:ask("Hej", O(#{ backend => claude,
							 baseurl => Url }))),
		       ?assertEqual({error, {untrusted_host, "127.0.0.1"}},
				    ellm:ask("Hej", O(#{ backend => openai,
							 baseurl => Url,
							 apikey => "$OPENAI_API_KEY" }))),
		       ?assertEqual([], requests(Server))
	       end},
	      {"ollama tool loop, no key in any request",
	       fun() ->
		       Call = #{ <<"id">> => <<"call_1">>,
				 <<"type">> => <<"function">>,
				 <<"function">> =>
				     #{ <<"name">> => <<"add">>,
					<<"arguments">> => <<"{\"a\":2,\"b\":3}">> } },
		       {Url, Server} =
			   fake_server([completion(null, [Call]),
					completion(<<"Svaret är 5"/utf8>>)]),
		       Tool = #{ name => <<"add">>,
				 description => <<"Add two integers">>,
				 schema => #{ type => <<"object">>,
					      properties =>
						  #{ a => #{ type => <<"integer">> },
						     b => #{ type => <<"integer">> } } } },
		       Handler = fun(<<"add">>, #{ <<"a">> := A, <<"b">> := B }, St) ->
					 {ok, integer_to_list(A+B), St}
				 end,
		       Msgs = [#{ role => user, content => <<"2+3?">> }],
		       {ok, Msgs1} = ellm:run(Msgs, [Tool], Handler,
					      O(#{ backend => ollama,
						   baseurl => Url,
						   print => false })),
		       ?assertMatch(#{ content := <<"Svaret är 5"/utf8>> },
				    lists:last(Msgs1)),
		       [R1, R2] = requests(Server),
		       [assert_no_secret(R) || R <- [R1, R2]],
		       #{ <<"tools">> := [_] } = json:decode(body(R1)),
		       #{ <<"messages">> := [_, _, ToolMsg] } = json:decode(body(R2)),
		       ?assertMatch(#{ <<"role">> := <<"tool">>,
				       <<"tool_call_id">> := <<"call_1">>,
				       <<"content">> := <<"5">> }, ToolMsg)
	       end},
	      {"ollama model list from /api/tags",
	       fun() ->
		       Tags = iolist_to_binary(
				json:encode(#{ <<"models">> =>
						   [#{ <<"name">> => <<"llama3.1:latest">>,
						       <<"modified_at">> => <<"2024-05-13T10:12:01.123456789-07:00">>,
						       <<"size">> => 4661224676 }] })),
		       {Url, Server} = fake_server([Tags]),
		       ?assertMatch({ok, [#{ id := <<"llama3.1:latest">>,
					     created := 1715620321 }]},
				    ellm_ollama:list_models(O(#{ baseurl => Url }))),
		       [Req] = requests(Server),
		       assert_no_secret(Req),
		       ?assertMatch(<<"GET /api/tags", _/binary>>, Req)
	       end},
	      {"ollama with authinfo for the server sends only that key",
	       fun() ->
		       {Url, Server} = fake_server([completion(<<"ok">>)]),
		       Auth = filename:join(filename:dirname(File), "authinfo2"),
		       ok = file:write_file(Auth, ?AUTHINFO ++
						"machine 127.0.0.1 login u apikey LOCAL-KEY\n"),
		       ?assertEqual({ok, <<"ok">>},
				    ellm:ask("Hej", #{ backend => ollama,
						       baseurl => Url,
						       authinfo => Auth })),
		       [Req] = requests(Server),
		       assert_no_secret(Req),
		       ?assertEqual(<<"Bearer LOCAL-KEY">>,
				    header(<<"authorization">>, Req))
	       end}
	     ]
     end}.

%%
%% Helpers
%%

key(openai, Opts) ->
    case ellm_openai:headers(Opts) of
	{ok, [{'Authorization', ["Bearer ", K]}]} -> {ok, K};
	Error -> Error
    end;
key(claude, Opts) ->
    case ellm_claude:headers(Opts) of
	{ok, [{"x-api-key", K}|_]} -> {ok, K};
	Error -> Error
    end.

setup() ->
    Saved = [{V, os:getenv(V)} || {V, _} <- ?ENV_KEYS],
    [os:putenv(V, K) || {V, K} <- ?ENV_KEYS],
    Dir = filename:join(os:getenv("TMPDIR", "/tmp"),
			"ellm_key_tests_" ++ os:getpid()),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    File = filename:join(Dir, "authinfo"),
    ok = file:write_file(File, ?AUTHINFO),
    #{ saved => Saved, dir => Dir, authinfo => File }.

cleanup(#{ saved := Saved, dir := Dir }) ->
    [case Val of
	 false -> os:unsetenv(V);
	 _ -> os:putenv(V, Val)
     end || {V, Val} <- Saved],
    file:del_dir_r(Dir).

without_env(Fun) ->
    Vars = [V || {V, _} <- ?ENV_KEYS],
    Saved = [{V, os:getenv(V)} || V <- Vars],
    [os:unsetenv(V) || V <- Vars],
    try Fun()
    after [os:putenv(V, Val) || {V, Val} <- Saved, Val =/= false]
    end.

assert_no_secret(Req) ->
    [?assertEqual({Mark, nomatch}, {Mark, binary:match(Req, Mark)})
     || Mark <- ?SECRET_MARKS],
    ?assertEqual(undefined, header(<<"x-api-key">>, Req)).

completion(Text) ->
    completion(Text, []).

completion(Text, Calls) ->
    Message = maps:merge(#{ <<"role">> => <<"assistant">>,
			    <<"content">> => Text },
			 case Calls of
			     [] -> #{};
			     _ -> #{ <<"tool_calls">> => Calls }
			 end),
    Finish = case Calls of [] -> <<"stop">>; _ -> <<"tool_calls">> end,
    iolist_to_binary(
      json:encode(#{ <<"id">> => <<"chatcmpl-1">>,
		     <<"object">> => <<"chat.completion">>,
		     <<"model">> => <<"llama3.1">>,
		     <<"choices">> => [#{ <<"index">> => 0,
					  <<"message">> => Message,
					  <<"finish_reason">> => Finish }] })).

%% Fake HTTP server on 127.0.0.1, answers one request per reply and
%% records the raw requests.
fake_server(Replies) ->
    {ok, L} = gen_tcp:listen(0, [binary, {active, false},
				 {ip, {127,0,0,1}}, {reuseaddr, true}]),
    {ok, Port} = inet:port(L),
    Pid = spawn_link(fun() -> serve(L, Replies, []) end),
    ok = gen_tcp:controlling_process(L, Pid),
    {"http://127.0.0.1:" ++ integer_to_list(Port), {Pid, L}}.

serve(L, Replies, Acc) ->
    receive
	{get, From} ->
	    gen_tcp:close(L),
	    From ! {requests, lists:reverse(Acc)}
    after 0 ->
	    case gen_tcp:accept(L, 100) of
		{ok, S} ->
		    {Req, Replies1} = serve_conn(S, Replies, <<>>, []),
		    serve(L, Replies1, lists:reverse(Req) ++ Acc);
		{error, timeout} ->
		    serve(L, Replies, Acc)
	    end
    end.

%% serve requests on one connection until closed or out of replies
serve_conn(S, Replies, Buf, Acc) ->
    case read_request(S, Buf) of
	{ok, Req, Rest} ->
	    [Reply|Replies1] = Replies,
	    ok = gen_tcp:send(S, ["HTTP/1.1 200 OK\r\n",
				  "Content-Type: application/json\r\n",
				  "Content-Length: ",
				  integer_to_list(byte_size(Reply)), "\r\n\r\n",
				  Reply]),
	    case Replies1 of
		[] -> gen_tcp:close(S), {lists:reverse([Req|Acc]), []};
		_ -> serve_conn(S, Replies1, Rest, [Req|Acc])
	    end;
	closed ->
	    {lists:reverse(Acc), Replies}
    end.

read_request(S, Buf) ->
    case binary:split(Buf, <<"\r\n\r\n">>) of
	[Head, Rest] ->
	    Len = case header(<<"content-length">>, <<Head/binary, "\r\n">>) of
		      undefined -> 0;
		      L -> binary_to_integer(L)
		  end,
	    if byte_size(Rest) >= Len ->
		    <<Body:Len/binary, Rest1/binary>> = Rest,
		    {ok, <<Head/binary, "\r\n\r\n", Body/binary>>, Rest1};
	       true -> more(S, Buf)
	    end;
	[_] -> more(S, Buf)
    end.

more(S, Buf) ->
    case gen_tcp:recv(S, 0, 5000) of
	{ok, Data} -> read_request(S, <<Buf/binary, Data/binary>>);
	{error, _} -> closed
    end.

requests({Pid, _L}) ->
    Pid ! {get, self()},
    receive {requests, Reqs} -> Reqs
    after 5000 -> error(fake_server_timeout)
    end.

header(Name, Req) ->
    [Head|_] = binary:split(Req, <<"\r\n\r\n">>),
    Lines = tl(binary:split(Head, <<"\r\n">>, [global])),
    Found = [string:trim(V) || Line <- Lines,
			       [K, V] <- [binary:split(Line, <<":">>)],
			       string:lowercase(K) =:= Name],
    case Found of
	[V|_] -> iolist_to_binary(V);
	[] -> undefined
    end.

body(Req) ->
    [_, Body] = binary:split(Req, <<"\r\n\r\n">>),
    Body.
