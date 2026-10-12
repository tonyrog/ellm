%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2021-2026, Tony Rogvall
%%% @doc
%%%    Text buffer window, a wx (wxStyledTextCtrl) view of an
%%%    ellm_text_buffer. The window can be edited by hand, from Erlang
%%%    with the API below, or by a model through the edit tool:
%%%
%%%      {ok, W} = ellm_text_window:start("hello.c"),
%%%      ellm_text_window:find(W, "main"),
%%%      ellm_text_window:run(W, "Make main exit with exit(0)", #{}).
%%%
%%%    Manual edits are synced back into the buffer before every call.
%%% @end
%%% Created : 20 Jan 2021 by Tony Rogvall <tony@rogvall.se>

-module(ellm_text_window).

-behaviour(wx_object).

-include_lib("wx/include/wx.hrl").

-export([start/0, start/1, stop/1]).
-export([read_file/2, insert_file/2, write_file/2]).
-export([setpos/2, getpos/1]).
-export([cut/2, copy/2, paste/1]).
-export([get_text/1, get_text/2]).
-export([get_buffer/1]).
-export([insert/3, replace/3, move/3, delete/2]).
-export([find/2, find/3]).
-export([find_replace/3, find_replace/4]).
-export([refind/2, refind/3]).
-export([refind_replace/3, refind_replace/4]).
%% model edit tool working on the window
-export([edit/2, handler/3, run/2, run/3]).

%% wx_object callbacks
-export([init/1, handle_event/2, handle_call/3, handle_cast/2,
	 handle_info/2, terminate/2, code_change/3]).

-define(WINDOW_WIDTH,  640).
-define(WINDOW_HEIGHT, 512).
-define(FONT_SIZE, 11).

-type window() :: wx:wx_object() | pid().
-type text_position() :: ellm_text_buffer:text_position().
-type text_range() :: ellm_text_buffer:text_range().
-type text_line() :: ellm_text_buffer:text_line().
-type text() :: ellm_text_buffer:text().

%%
%% Client API
%%

-spec start() -> {ok, window()}.
start() ->
    start(ellm_text_buffer:new()).

%% start with a text buffer or a file name
-spec start(ellm_text_buffer:text_buffer() | file:filename()) ->
	  {ok, window()} | {error, term()}.
start(File) when is_list(File); is_binary(File) ->
    case ellm_text_buffer:read_file(File) of
	{ok, Tb} -> start(Tb);
	{error, enoent} -> start(ellm_text_buffer:new_file(File));
	Error -> Error
    end;
start(Tb) ->
    case wx_object:start(?MODULE, Tb, []) of
	{error, _} = Error -> Error;
	Window -> {ok, Window}
    end.

stop(W) -> wx_object:stop(W).

-spec read_file(W::window(), Filename::file:name()) ->
	  ok | {error, Reason::file:posix()}.
read_file(W, Filename) -> call(W, {read_file, Filename}).

-spec insert_file(W::window(), Filename::file:name()) ->
	  ok | {error, Reason::file:posix()}.
insert_file(W, Filename) -> call(W, {insert_file, Filename}).

-spec write_file(W::window(), Filename::file:name()) ->
	  ok | {error, Reason::file:posix()}.
write_file(W, Filename) -> call(W, {write_file, Filename}).

-spec setpos(W::window(), Pos::text_position()) -> text_position().
setpos(W, Pos) -> call(W, {setpos, Pos}).

%% current position, the caret position in the window
-spec getpos(W::window()) -> text_position().
getpos(W) -> call(W, getpos).

-spec cut(W::window(), Range::text_range()) -> ok.
cut(W, Range) -> call(W, {cut, Range}).

-spec copy(W::window(), Range::text_range()) -> ok.
copy(W, Range) -> call(W, {copy, Range}).

%% paste at the caret position
-spec paste(W::window()) -> ok.
paste(W) -> call(W, paste).

-spec get_text(W::window()) -> text().
get_text(W) -> call(W, get_text).

-spec get_text(W::window(), Range::text_range()) -> text().
get_text(W, Range) -> call(W, {get_text, Range}).

-spec get_buffer(W::window()) -> ellm_text_buffer:text_buffer().
get_buffer(W) -> call(W, get_buffer).

-spec insert(W::window(), InsertPos::text_position(), T::text()|text_line()) ->
	  ok.
insert(W, InsertPos, T) -> call(W, {insert, InsertPos, T}).

-spec replace(W::window(), Range::text_range(), NewText::text()) -> ok.
replace(W, Range, NewText) -> call(W, {replace, Range, NewText}).

-spec move(W::window(), Range::text_range(), Target::text_position()) -> ok.
move(W, Range, Target) -> call(W, {move, Range, Target}).

-spec delete(W::window(), Range::text_range()) -> ok.
delete(W, Range) -> call(W, {delete, Range}).

%% find selects the match in the window
-spec find(W::window(), Text::text()) -> text_range() | false.
find(W, Text) -> call(W, {find, Text}).

-spec find(W::window(), Text::text(), From::text_position()) ->
	  text_range() | false.
find(W, Text, From) -> call(W, {find, Text, From}).

-spec find_replace(W::window(), Text::text(), Replace::text()) -> ok.
find_replace(W, Text, Replace) -> call(W, {find_replace, Text, Replace}).

-spec find_replace(W::window(), Text::text(), Replace::text(),
		   From::text_position()) -> ok.
find_replace(W, Text, Replace, From) ->
    call(W, {find_replace, Text, Replace, From}).

-spec refind(W::window(), RegExp::text()|re:mp()) -> text_range() | false.
refind(W, RegExp) -> call(W, {refind, RegExp}).

-spec refind(W::window(), RegExp::text()|re:mp(), From::text_position()) ->
	  text_range() | false.
refind(W, RegExp, From) -> call(W, {refind, RegExp, From}).

-spec refind_replace(W::window(), RegExp::text()|re:mp(), Replace::text()) ->
	  ok.
refind_replace(W, RegExp, Replace) ->
    call(W, {refind_replace, RegExp, Replace}).

-spec refind_replace(W::window(), RegExp::text()|re:mp(), Replace::text(),
		     From::text_position()) -> ok.
refind_replace(W, RegExp, Replace, From) ->
    call(W, {refind_replace, RegExp, Replace, From}).

%% Run ellm_text_edit tool arguments on the window buffer
-spec edit(W::window(), Args::map()) -> {ok, binary()} | {error, term()}.
edit(W, Args) -> call(W, {edit, Args}).

%% Tool handler for ellm:run/5, State is the window
handler(<<"edit">>, Args, W) ->
    case edit(W, Args) of
	{ok, Text} -> {ok, ["Ok\n", Text], W};
	{error, Reason} -> {error, io_lib:format("~p", [Reason]), W}
    end;
handler(Name, _Args, W) ->
    {error, ["unknown tool ", Name], W}.

%% Let the model edit the window content
run(W, Text) ->
    run(W, Text, #{}).
run(W, Text, Opts) ->
    Content = ellm_text_buffer:format(get_buffer(W), [{line_numbers,true}]),
    Messages =
	[#{ role => system,
	    content => <<"You edit the text shown in an editor window with the edit tool. Positions are 0 based, line -1 is the last line and character -1 is the end of a line. Leave out `text` to edit the current buffer.">> },
	 #{ role => user,
	    content => unicode:characters_to_binary(
			 ["Current buffer:\n", Content, "\n", Text]) }],
    case ellm:run(Messages, ellm_text_edit:tools(), fun handler/3, W, Opts) of
	{ok, Messages1, _W} -> {ok, Messages1};
	Error -> Error
    end.

call(W, Request) ->
    wx_object:call(W, Request).

%%
%% wx_object callbacks
%%

init(Tb) ->
    wx:new(),
    Frame = wxFrame:new(wx:null(), ?wxID_ANY, "",
			[{size, {?WINDOW_WIDTH, ?WINDOW_HEIGHT}}]),
    MenuBar = wxMenuBar:new(),
    File = wxMenu:new(),
    wxMenu:append(File, ?wxID_OPEN, "&Open...\tCtrl+O"),
    wxMenu:append(File, ?wxID_SAVE, "&Save\tCtrl+S"),
    wxMenu:append(File, ?wxID_SAVEAS, "Save &As..."),
    wxMenu:appendSeparator(File),
    wxMenu:append(File, ?wxID_CLOSE, "&Close\tCtrl+W"),
    wxMenuBar:append(MenuBar, File, "&File"),
    wxFrame:setMenuBar(Frame, MenuBar),
    wxFrame:createStatusBar(Frame),

    Stc = wxStyledTextCtrl:new(Frame),
    Font = wxFont:new(?FONT_SIZE, ?wxFONTFAMILY_TELETYPE,
		      ?wxFONTSTYLE_NORMAL, ?wxFONTWEIGHT_NORMAL),
    wxStyledTextCtrl:styleSetFont(Stc, ?wxSTC_STYLE_DEFAULT, Font),
    wxStyledTextCtrl:styleClearAll(Stc),
    wxStyledTextCtrl:setMarginType(Stc, 0, ?wxSTC_MARGIN_NUMBER),
    wxStyledTextCtrl:setMarginWidth(
      Stc, 0, wxStyledTextCtrl:textWidth(Stc, ?wxSTC_STYLE_LINENUMBER,
					 "_99999")),
    wxStyledTextCtrl:setTabWidth(Stc, 8),

    wxFrame:connect(Frame, command_menu_selected),
    wxFrame:connect(Frame, close_window),
    wxStyledTextCtrl:connect(Stc, stc_savepointleft),
    wxStyledTextCtrl:connect(Stc, stc_updateui),

    State = #{ frame => Frame, stc => Stc, tb => Tb, dirty => false },
    State1 = refresh(State, false),
    wxStyledTextCtrl:emptyUndoBuffer(Stc),
    wxFrame:show(Frame),
    {Frame, State1}.

handle_event(#wx{ id = ?wxID_OPEN }, State = #{ frame := Frame }) ->
    case file_dialog(Frame, ?wxFD_OPEN, "") of
	{ok, Path} ->
	    case ellm_text_buffer:read_file(maps:get(tb, State), Path) of
		{ok, Tb1} ->
		    State1 = refresh(State#{ tb => Tb1 }, false),
		    wxStyledTextCtrl:emptyUndoBuffer(maps:get(stc, State)),
		    {noreply, State1};
		{error, Reason} ->
		    status(State, "Open failed: ~p", [Reason]),
		    {noreply, State}
	    end;
	cancel ->
	    {noreply, State}
    end;
handle_event(#wx{ id = ?wxID_SAVE }, State) ->
    State1 = sync(State),
    {noreply, save(State1, ellm_text_buffer:filename(maps:get(tb, State1)))};
handle_event(#wx{ id = ?wxID_SAVEAS }, State = #{ frame := Frame }) ->
    State1 = sync(State),
    Tb = maps:get(tb, State1),
    case file_dialog(Frame, ?wxFD_SAVE bor ?wxFD_OVERWRITE_PROMPT,
		     ellm_text_buffer:filename(Tb)) of
	{ok, Path} -> {noreply, save(State1, Path)};
	cancel -> {noreply, State1}
    end;
handle_event(#wx{ id = ?wxID_CLOSE }, State) ->
    {stop, normal, State};
handle_event(#wx{ event = #wxClose{} }, State) ->
    {stop, normal, State};
handle_event(#wx{ event = #wxStyledText{ type = stc_savepointleft } },
	     State = #{ stc := Stc }) ->
    %% refresh/2 calls setText + setSavePoint, ignore that
    case wxStyledTextCtrl:getModify(Stc) of
	true -> {noreply, set_title(State#{ dirty => true })};
	false -> {noreply, State}
    end;
handle_event(#wx{ event = #wxStyledText{ type = stc_updateui } }, State) ->
    #{ line := L, character := C } = caret(maps:get(stc, State)),
    status(State, "~s  L~w C~w", [ellm_text_buffer:filename(maps:get(tb, State)),
				  L+1, C]),
    {noreply, State};
handle_event(_Event, State) ->
    {noreply, State}.

handle_call(Request, From, State) ->
    try request(Request, From, sync(State))
    catch
	error:Reason ->
	    {reply, {error, Reason}, State}
    end.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #{ frame := Frame }) ->
    wxFrame:destroy(Frame),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%
%% Requests, State is synced with manual edits
%%

request({read_file, Filename}, _From, State = #{ tb := Tb }) ->
    case ellm_text_buffer:read_file(Tb, Filename) of
	{ok, Tb1} ->
	    State1 = refresh(State#{ tb => Tb1 }, false),
	    wxStyledTextCtrl:emptyUndoBuffer(maps:get(stc, State)),
	    {reply, ok, State1};
	Error ->
	    {reply, Error, State}
    end;
request({insert_file, Filename}, _From, State = #{ tb := Tb }) ->
    case ellm_text_buffer:insert_file(Tb, Filename) of
	{ok, Tb1} -> {reply, ok, refresh(State#{ tb => Tb1 }, true)};
	Error -> {reply, Error, State}
    end;
request({write_file, Filename}, _From, State = #{ tb := Tb }) ->
    case ellm_text_buffer:write_file(Tb, Filename) of
	ok ->
	    Tb1 = ellm_text_buffer:set_filename(Tb, Filename),
	    {reply, ok, set_title(State#{ tb => Tb1, dirty => false })};
	Error ->
	    {reply, Error, State}
    end;
request({setpos, Pos}, _From, State = #{ tb := Tb, stc := Stc }) ->
    goto(Stc, Tb, Pos),
    Tb1 = ellm_text_buffer:setpos(Tb, Pos),
    {reply, ellm_text_buffer:getpos(Tb1), State#{ tb => Tb1 }};
request(getpos, _From, State = #{ stc := Stc }) ->
    {reply, caret(Stc), State};
request({cut, Range}, _From, State) ->
    update(fun(Tb) -> ellm_text_buffer:cut(Tb, Range) end, State);
request({copy, Range}, _From, State = #{ tb := Tb }) ->
    {reply, ok, State#{ tb => ellm_text_buffer:copy(Tb, Range) }};
request(paste, _From, State = #{ stc := Stc }) ->
    Pos = caret(Stc),
    update(fun(Tb) -> ellm_text_buffer:paste(Tb, Pos) end, State);
request(get_text, _From, State = #{ tb := Tb }) ->
    {reply, ellm_text_buffer:get_text(Tb), State};
request({get_text, Range}, _From, State = #{ tb := Tb }) ->
    {reply, ellm_text_buffer:get_text(Tb, Range), State};
request(get_buffer, _From, State = #{ tb := Tb }) ->
    {reply, Tb, State};
request({insert, Pos, T}, _From, State) ->
    update(fun(Tb) -> ellm_text_buffer:insert(Tb, Pos, T) end, State);
request({replace, Range, NewText}, _From, State) ->
    update(fun(Tb) -> ellm_text_buffer:replace(Tb, Range, NewText) end, State);
request({move, Range, Target}, _From, State) ->
    update(fun(Tb) -> ellm_text_buffer:move(Tb, Range, Target) end, State);
request({delete, Range}, _From, State) ->
    update(fun(Tb) -> ellm_text_buffer:delete(Tb, Range) end, State);
request({find, Text}, _From, State = #{ tb := Tb }) ->
    {reply, select(State, ellm_text_buffer:find(Tb, Text)), State};
request({find, Text, From}, _From, State = #{ tb := Tb }) ->
    {reply, select(State, ellm_text_buffer:find(Tb, Text, From)), State};
request({find_replace, Text, Replace}, _From, State) ->
    update(fun(Tb) -> ellm_text_buffer:find_replace(Tb, Text, Replace) end,
	   State);
request({find_replace, Text, Replace, From}, _From, State) ->
    update(fun(Tb) ->
		   ellm_text_buffer:find_replace(Tb, Text, Replace, From)
	   end, State);
request({refind, RegExp}, _From, State = #{ tb := Tb }) ->
    {reply, select(State, ellm_text_buffer:refind(Tb, RegExp)), State};
request({refind, RegExp, From}, _From, State = #{ tb := Tb }) ->
    {reply, select(State, ellm_text_buffer:refind(Tb, RegExp, From)), State};
request({refind_replace, RegExp, Replace}, _From, State) ->
    update(fun(Tb) ->
		   ellm_text_buffer:refind_replace(Tb, RegExp, Replace)
	   end, State);
request({refind_replace, RegExp, Replace, From}, _From, State) ->
    update(fun(Tb) ->
		   ellm_text_buffer:refind_replace(Tb, RegExp, Replace, From)
	   end, State);
request({edit, Args}, _From, State = #{ tb := Tb }) ->
    case ellm_text_edit:edit(Args, Tb) of
	{ok, Tb1} ->
	    Changed = ellm_text_buffer:get_text(Tb1) =/=
		ellm_text_buffer:get_text(Tb),
	    State1 = refresh(State#{ tb => Tb1 }, Changed),
	    {reply, {ok, ellm_text_buffer:format(Tb1, [{line_numbers,true}])},
	     State1};
	Error ->
	    {reply, Error, State}
    end;
request(Request, _From, State) ->
    {reply, {error, {bad_request, Request}}, State}.

update(Fun, State = #{ tb := Tb }) ->
    {reply, ok, refresh(State#{ tb => Fun(Tb) }, true)}.

%%
%% Buffer <-> window
%%

%% read back manual edits into the text buffer
sync(State = #{ stc := Stc, tb := Tb }) ->
    case wxStyledTextCtrl:getModify(Stc) of
	true ->
	    Tb1 = ellm_text_buffer:set_text(Tb, wxStyledTextCtrl:getText(Stc)),
	    wxStyledTextCtrl:setSavePoint(Stc),
	    State#{ tb => Tb1 };
	false ->
	    State
    end.

%% show the text buffer, keep caret and scroll position
refresh(State = #{ stc := Stc, tb := Tb }, Dirty) ->
    Caret = wxStyledTextCtrl:getCurrentPos(Stc),
    First = wxStyledTextCtrl:getFirstVisibleLine(Stc),
    Text = lists:join($\n, ellm_text_buffer:get_text(Tb)),
    wxStyledTextCtrl:setText(Stc, unicode:characters_to_list(Text)),
    wxStyledTextCtrl:setSavePoint(Stc),
    wxStyledTextCtrl:scrollToLine(Stc, First),
    wxStyledTextCtrl:gotoPos(Stc, min(Caret,
				      wxStyledTextCtrl:getLength(Stc))),
    set_title(State#{ dirty => Dirty orelse maps:get(dirty, State) }).

save(State = #{ tb := Tb }, Filename) ->
    case ellm_text_buffer:write_file(Tb, Filename) of
	ok ->
	    status(State, "Wrote ~s", [Filename]),
	    Tb1 = ellm_text_buffer:set_filename(Tb, Filename),
	    set_title(State#{ tb => Tb1, dirty => false });
	{error, Reason} ->
	    status(State, "Save failed: ~p", [Reason]),
	    State
    end.

set_title(State = #{ frame := Frame, tb := Tb, dirty := Dirty }) ->
    Mark = if Dirty -> " *"; true -> "" end,
    wxFrame:setTitle(Frame, lists:flatten(
			      io_lib:format("~ts~s",
					    [ellm_text_buffer:filename(Tb),
					     Mark]))),
    State.

status(#{ frame := Frame }, Fmt, Args) ->
    wxFrame:setStatusText(Frame, lists:flatten(io_lib:format(Fmt, Args))).

%% select a find result in the window
select(_State, false) ->
    false;
select(#{ stc := Stc, tb := Tb }, Range = #{ start := Start, stop := Stop }) ->
    From = stc_pos(Stc, Tb, Start),
    To = stc_pos(Stc, Tb, Stop),
    wxStyledTextCtrl:setSelection(Stc, From, To),
    wxStyledTextCtrl:ensureCaretVisible(Stc),
    Range.

goto(Stc, Tb, Pos) ->
    wxStyledTextCtrl:gotoPos(Stc, stc_pos(Stc, Tb, Pos)).

%% text position (characters) -> styled text position (utf8 bytes)
stc_pos(Stc, Tb, Pos) ->
    {Line, Char} = ellm_text_buffer:char_position(Tb, Pos),
    Lines = ellm_text_buffer:get_text(Tb),
    Prefix = case lists:nthtail(min(Line, length(Lines)), Lines) of
		 [] -> [];
		 [TextLine|_] -> lists:sublist(TextLine, Char)
	     end,
    wxStyledTextCtrl:positionFromLine(Stc, Line) +
	byte_size(unicode:characters_to_binary(Prefix)).

%% caret as text position
caret(Stc) ->
    Pos = wxStyledTextCtrl:getCurrentPos(Stc),
    Line = wxStyledTextCtrl:lineFromPosition(Stc, Pos),
    Bytes = Pos - wxStyledTextCtrl:positionFromLine(Stc, Line),
    Utf8 = unicode:characters_to_binary(wxStyledTextCtrl:getLine(Stc, Line)),
    Char = string:length(binary:part(Utf8, 0, min(Bytes, byte_size(Utf8)))),
    #{ line => Line, character => Char }.

file_dialog(Frame, Style, Default) ->
    Dialog = wxFileDialog:new(Frame, [{style, Style},
				      {defaultFile, Default}]),
    Result = case wxFileDialog:showModal(Dialog) of
		 ?wxID_OK -> {ok, wxFileDialog:getPath(Dialog)};
		 _ -> cancel
	     end,
    wxFileDialog:destroy(Dialog),
    Result.
