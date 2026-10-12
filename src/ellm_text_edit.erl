%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2023-2026, Tony Rogvall
%%% @doc
%%%    Text editor tool for ellm. The edit buffer is kept in the tool
%%%    loop state, so the model can load a file in one call and edit it
%%%    in the next.
%%%
%%%      ellm_text_edit:test_edit1().
%%%      ellm_text_edit:run("Load hello.c and ...", #{ backend => openai }).
%%% @end
%%% Created : 10 Nov 2023 by Tony Rogvall <tony@rogvall.se>

-module(ellm_text_edit).

-export([tools/0, handler/3]).
-export([run/1, run/2]).
-export([edit/2, apply_operations/2]).
-export([load/1]).

-export([test1/0, test2/0]).
-export([test_edit1/0, test_edit2/0]).

-define(OBJECT, <<"object">>).
-define(STRING, <<"string">>).
-define(ARRAY, <<"array">>).
-define(INTEGER, <<"integer">>).

-define(SYSTEM, <<"You edit text files with the edit tool. Positions are 0 based, line -1 is the last line and character -1 is the end of a line. The tool returns the buffer with line numbers after each call.">>).

operations() ->
    [<<"load">>, <<"save">>,
     <<"insert">>, <<"delete">>, <<"replace">>,
     <<"copy">>, <<"move">>].

position_type() ->
    #{ type => ?OBJECT,
       properties =>
	   #{ line => #{ type => ?INTEGER,
			 description => <<"Line number, 0 based, -1 is the last line.">> },
	      character => #{ type => ?INTEGER,
			      description => <<"Character position in the line, 0 based, -1 is end of line.">> } },
       required => [<<"line">>, <<"character">>] }.

range_type() ->
    #{ type => ?OBJECT,
       properties =>
	   #{ start => #{ '$ref' => <<"#/$defs/position">>,
			  description => <<"Start position of the range.">> },
	      stop => #{ '$ref' => <<"#/$defs/position">>,
			 description => <<"End position of the range (exclusive).">> } },
       required => [<<"start">>, <<"stop">>] }.

operation_type() ->
    #{ type => ?OBJECT,
       properties =>
	   #{ operation => #{ type => ?STRING, enum => operations(),
			      description => <<"Type of the operation.">> },
	      position => #{ '$ref' => <<"#/$defs/position">>,
			     description => <<"Position for insert.">> },
	      range => #{ '$ref' => <<"#/$defs/range">>,
			  description => <<"Range for delete, replace or copy.">> },
	      text => #{ type => ?STRING,
			 description => <<"Text to insert, or the replacement text. In regexp replacements \\1..\\9 refer to groups.">> },
	      source => #{ type => ?STRING,
			   description => <<"Plain text to replace everywhere (when no regexp is needed).">> },
	      regexp => #{ type => ?STRING,
			   description => <<"Regular expression for the text to replace everywhere.">> },
	      filename => #{ type => ?STRING,
			     description => <<"File name for load and save.">> },
	      sourceRange => #{ '$ref' => <<"#/$defs/range">>,
				description => <<"Source range for move.">> },
	      targetPosition => #{ '$ref' => <<"#/$defs/position">>,
				   description => <<"Target position for move.">> } },
       required => [<<"operation">>] }.

schema() ->
    #{ type => ?OBJECT,
       properties =>
	   #{ text => #{ type => ?ARRAY,
			 items => #{ type => ?STRING },
			 description => <<"Optional new buffer content, one string per line without end of line. Leave out to keep editing the current buffer.">> },
	      operations => #{ type => ?ARRAY,
			       items => #{ '$ref' => <<"#/$defs/operation">> },
			       description => <<"Edit operations, performed in order.">> } },
       required => [<<"operations">>],
       additionalProperties => false,
       '$defs' => #{ position => position_type(),
		     range => range_type(),
		     operation => operation_type() } }.

tools() ->
    [#{ name => <<"edit">>,
	description => <<"Run a list of edit operations on the edit buffer (load, save, insert, delete, replace, copy, move). Returns the resulting buffer with line numbers.">>,
	schema => schema() }].

%% Tool handler, State is the current text buffer (or undefined)
handler(<<"edit">>, Args, undefined) ->
    handler(<<"edit">>, Args, ellm_text_buffer:new());
handler(<<"edit">>, Args, Tb) ->
    case edit(Args, Tb) of
	{ok, Tb1} ->
	    {ok, ["Ok\n", ellm_text_buffer:format(Tb1, [{line_numbers,true}])],
	     Tb1};
	{error, Reason} ->
	    {error, io_lib:format("~p", [Reason]), Tb}
    end;
handler(Name, _Args, Tb) ->
    {error, ["unknown tool ", Name], Tb}.

run(Text) ->
    run(Text, #{}).

%% returns {ok, Messages, TextBuffer}
run(Text, Opts) ->
    Messages = [#{ role => system, content => ?SYSTEM },
		#{ role => user, content => unicode:characters_to_binary(Text) }],
    ellm:run(Messages, tools(), fun handler/3, ellm_text_buffer:new(), Opts).

%% Apply decoded tool arguments to text buffer Tb
edit(Args, Tb) ->
    try
	Tb1 = case maps:get(<<"text">>, Args, undefined) of
		  undefined -> Tb;
		  Lines -> ellm_text_buffer:new(Lines)
	      end,
	apply_operations(Tb1, maps:get(<<"operations">>, Args, []))
    catch
	error:Reason -> {error, Reason}
    end.

load(File) ->
    {ok, Tb} = ellm_text_buffer:read_file(File),
    ellm_text_buffer:get_text(Tb).

apply_operations(Tb, [Operation|Operations]) ->
    case operation(Tb, Operation) of
	{ok, Tb1} -> apply_operations(Tb1, Operations);
	Error -> Error
    end;
apply_operations(Tb, []) ->
    {ok, Tb}.

operation(Tb, Op) ->
    case Op of
	#{ <<"operation">> := <<"load">>, <<"filename">> := FileName } ->
	    case ellm_text_buffer:read_file(Tb, FileName) of
		{ok, Tb1} -> {ok, Tb1};
		{error, enoent} -> {ok, ellm_text_buffer:new_file(FileName)};
		Error -> Error
	    end;
	#{ <<"operation">> := <<"save">>, <<"filename">> := FileName } ->
	    case ellm_text_buffer:write_file(Tb, FileName) of
		ok -> {ok, Tb};
		Error -> Error
	    end;
	#{ <<"operation">> := <<"insert">>,
	   <<"position">> := Pos, <<"text">> := Text } ->
	    {ok, ellm_text_buffer:insert(Tb, Pos, Text)};
	#{ <<"operation">> := <<"delete">>, <<"range">> := Range } ->
	    {ok, ellm_text_buffer:delete(Tb, Range)};
	#{ <<"operation">> := <<"replace">>,
	   <<"source">> := Source, <<"text">> := Text } ->
	    {ok, ellm_text_buffer:find_replace(Tb, Source, Text)};
	#{ <<"operation">> := <<"replace">>,
	   <<"regexp">> := RegExp, <<"text">> := Text } ->
	    {ok, ellm_text_buffer:refind_replace(Tb, RegExp, Text)};
	#{ <<"operation">> := <<"replace">>,
	   <<"range">> := Range, <<"text">> := Text } ->
	    {ok, ellm_text_buffer:replace(Tb, Range, Text)};
	#{ <<"operation">> := <<"copy">>, <<"range">> := Range } ->
	    {ok, ellm_text_buffer:copy(Tb, Range)};
	#{ <<"operation">> := <<"move">>,
	   <<"sourceRange">> := Range, <<"targetPosition">> := Target } ->
	    {ok, ellm_text_buffer:move(Tb, Range, Target)};
	_ ->
	    {error, {invalid_operation, Op}}
    end.

%%
%% Tests, run from the ellm top directory
%%

%% replace data in a file
test1() ->
    apply_operations(
      ellm_text_buffer:new(),
      [#{ <<"operation">> => <<"load">>,
	  <<"filename">> => <<"test/data/source1.txt">> },
       #{ <<"operation">> => <<"replace">>,
	  <<"regexp">> => <<"16#([A-Fa-f0-9]+)">>,
	  <<"text">> => <<"0x\\1">> },
       #{ <<"operation">> => <<"replace">>,
	  <<"regexp">> => <<"Erlang">>,
	  <<"text">> => <<"C">> },
       #{ <<"operation">> => <<"replace">>,
	  <<"source">> => <<"constants">>,
	  <<"text">> => <<"const">> },
       #{ <<"operation">> => <<"save">>,
	  <<"filename">> => <<"test/data/destination1.txt">> }]).

%% rewrite C .h file with definitions into a .hrl file
test2() ->
    R = fun(S, T) -> #{ <<"operation">> => <<"replace">>,
			<<"source">> => S, <<"text">> => T } end,
    apply_operations(
      ellm_text_buffer:new(),
      [#{ <<"operation">> => <<"load">>,
	  <<"filename">> => <<"test/data/source2.h">> },
       #{ <<"operation">> => <<"replace">>,
	  <<"regexp">> => <<"0x([A-Fa-f0-9]+)">>,
	  <<"text">> => <<"16#\\1">> },
       R(<<"!">>, <<" not ">>),
       R(<<"||">>, <<" or ">>),
       R(<<"&&">>, <<" and ">>),
       R(<<"~">>, <<" bnot ">>),
       R(<<"|">>, <<" bor ">>),
       R(<<"&">>, <<" band ">>),
       #{ <<"operation">> => <<"replace">>,
	  <<"regexp">> => <<"#define[ ]+([a-zA-Z_][a-zA-Z0-9_]*)(.*)">>,
	  <<"text">> => <<"-define(\\1,\\2).">> },
       #{ <<"operation">> => <<"save">>,
	  <<"filename">> => <<"test/data/destination2.hrl">> }]).

test_edit1() ->
    run("Create a file and insert a hello world C file into it, then save it as hello.c").

test_edit2() ->
    run("Load the file called hello.c and update the file to make an exit instead of return from the main program").
