%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2024-2026, Tony Rogvall
%%% @doc
%%%    SAT solver tools (solve / prove) for ellm, uses varp.
%%%    Works with any backend:
%%%      ellm_sat:test_prove().
%%%      ellm_sat:run("...", #{ backend => openai }).
%%% @end
%%% Created : 18 Dec 2024 by Tony Rogvall <tony@rogvall.se>

-module(ellm_sat).

-export([tools/0, handler/3]).
-export([run/1, run/2]).
-export([format/1, print/1]).
-export([solve/1, prove/1]).
-export([format_model/1]).

%% tests
-export([test1/0, test2/0, test3/0]).
-export([test_solve/0, test_solve2/0, test_solve3/0]).
-export([test_prove/0]).
-export([vincent_prove/0]).
-export([test_solve_abc/0]).

-define(SYSTEM, <<"Help translate problems into propositional logic and use the varp tools 'solve' and 'prove' to find solutions to the problem. Reason about the various formulations after finding models or a proof that the formula is valid.">>).

%% FORMULA keys
-define(formula, <<"formula">>).
-define(operator, <<"operator">>).
-define(operands, <<"operands">>).

formula_type() ->
    #{
      type => <<"object">>,
      properties =>
	  #{
	    operator =>
		#{
		  type => <<"string">>,
		  enum => [<<"AND">>, <<"XOR">>, <<"OR">>, <<"NOT">>,
			   <<"IMPLIES">>, <<"EQUIVALENT">>]
		 },
	    operands =>
		#{
		  type => <<"array">>,
		  items =>
		      #{
			anyOf =>
			    [
			     #{ type => <<"string">> },
			     #{ '$ref' => <<"#/$defs/formula">> }
			    ]
		       }
		 }
	   },
      required => [<<"operator">>, <<"operands">>]
     }.

formula_schema() ->
    #{ type => <<"object">>,
       properties => #{ formula => #{ '$ref' => <<"#/$defs/formula">> } },
       required => [<<"formula">>],
       additionalProperties => false,
       '$defs' => #{ formula => formula_type() }
     }.

tools() ->
    [#{ name => <<"solve">>,
	description => <<"Given a structured SAT formula solve and return False or a Model as a list of Var=Value.">>,
	schema => formula_schema() },
     #{ name => <<"prove">>,
	description => <<"Prove a structured SAT formula, return True if the formula is valid / a tautology or return a counter model that disproves the formula.">>,
	schema => formula_schema() }].

handler(<<"solve">>, Args, State) -> {ok, solve(Args), State};
handler(<<"prove">>, Args, State) -> {ok, prove(Args), State};
handler(Name, _Args, State) -> {error, ["unknown tool ", Name], State}.

run(Text) ->
    run(Text, #{}).

run(Text, Opts) ->
    Messages = [#{ role => system, content => ?SYSTEM },
		#{ role => user, content => unicode:characters_to_binary(Text) }],
    ellm:run(Messages, tools(), fun handler/3, Opts).

%%
%% Tests
%%

test_solve_abc() ->
    run("Firman ansvarar för varan och ersätter köparens ev förluster, om förseglingen är obruten, när anmärkningen göres, eller om anmärkningen göres inom åtta dagar och det kan styrkas att varan var felaktig vid leveransen.").

test_solve() ->
    run("please prove that if Brian is Happy and if being Happy is being Rich then Brian is Rich").

test_solve2() ->
    run("We know that candles need oxygen to burn. But there's no oxygen in that room, so the candle must not be burning now.").

test_solve3() ->
    run("Find a solution for the following problem: (((A xor B) xor C) and (not A and not B and C)) and (((D xor E) xor F) and (not D and not E and F)) and (((G xor H) xor I) and (not G and not H and I)) and (((A xor D) xor G) and (not A and not D and G)) and (((B xor E) xor H) and (not B and not E and H)) and (((C xor F) xor I) and (not C and not F and I))").

test_prove() ->
    run("Prove that the propositional formula (P -> Q) == (~Q -> ~P)").

vincent_prove() ->
    run("Prove that the propositional formula (~q -> s) & (q -> p) & ((~q & s) -> r) & ~p -> r").

test1() ->
    #{ ?formula => #{ ?operator => <<"NOT">>, ?operands => [<<"A">>] } }.

test2() ->
    #{ ?formula =>
	   #{ ?operator => <<"AND">>,
	      ?operands =>
		  [#{ ?operator => <<"OR">>, ?operands => [<<"A">>, <<"B">>] },
		   #{ ?operator => <<"IMPLIES">>, ?operands => [<<"C">>, <<"D">>] }]
	    }
     }.

test3() ->
    #{ ?formula =>
	   #{ ?operator => <<"AND">>,
	      ?operands =>
		  [#{ ?operator => <<"NOT">>, ?operands => [<<"A">>] },
		   #{ ?operator => <<"NOT">>,
		      ?operands => [#{ ?operator => <<"OR">>,
				       ?operands => [<<"C">>, <<"D">>] }] }]
	    }
     }.

%%
%% Formatting
%%

format(#{ ?formula := Formula }) ->
    format_formula(Formula, "").

format_formula(#{ ?operator := Op, ?operands := [A] }, Parent) ->
    [L,R] = paren(Op, Parent),
    [L,Op, " ",format_formula(A,Op),R];
format_formula(#{ ?operator := Op, ?operands := A }, Parent)
  when is_binary(A) ->
    [L,R] = paren(Op, Parent),
    [L,Op, " ",format_formula(A,Op),R];
format_formula(#{ ?operator := Op, ?operands := [A,B] }, Parent) ->
    [L,R] = paren(Op, Parent),
    [L, format_formula(A,Op)," ",Op," ",format_formula(B,Op),R];
format_formula(#{ ?operator := Op, ?operands := As }, Parent)
  when is_list(As) ->
    [L,R] = paren(Op, Parent),
    Fs = [format_formula(A, Op) || A <- As],
    [L,lists:join([" ",Op," "], Fs),R];
format_formula(Var, _Parent) when is_binary(Var) ->
    [Var].

paren(Op, Parent) ->
    case prio(Op) > prio(Parent) of
	true -> ["(", ")"];
	false -> ["", ""]
    end.

prio(<<"NOT">>) -> 10;
prio(<<"AND">>) -> 20;
prio(<<"XOR">>) -> 30;
prio(<<"OR">>) -> 40;
prio(<<"IMPLIES">>) -> 50;
prio(<<"EQUIVALENT">>) -> 60;
prio(_) -> 70.

print(Formula) ->
    io:put_chars([format(Formula),"\n"]).

%%
%% Solving (Json is the decoded tool arguments)
%%

solve(Json) ->
    io:format("Solve: formula = "),
    print(Json),
    Vp = varp_nif:new(#{xref => true}),
    X = build(Json, Vp),
    varp_nif:bind(Vp, X),
    varp_nif:push(Vp),
    case varp_circuit:bt(Vp) of
	true ->
	    M = varp_circuit:model(Vp, undefined),
	    iolist_to_binary(format_model(M));
	false ->
	    <<"False">>
    end.

prove(Json) ->
    io:format("Prove: formula = "),
    print(Json),
    Vp = varp_nif:new(#{xref => true}),
    X = build(Json, Vp),
    varp_nif:bind(Vp, varp_circuit:inv(X)),
    varp_nif:push(Vp),
    case varp_circuit:bt(Vp) of
	true ->
	    M = varp_circuit:model(Vp, undefined),
	    iolist_to_binary(format_model(M));
	false ->
	    <<"True">>
    end.

format_model(M) ->
    lists:join(",", [[Var, "=", value(Value)] || {{Var,[]},Value} <- M]).

value(true) -> "True";
value(false) -> "False".

%% build varp circuit from Json formula
build(#{ ?formula := Formula }, Vp) ->
    build_formula(Formula, Vp).

build_formula(#{ ?operator := <<"NOT">>, ?operands := [A] }, Vp) ->
    varp_circuit:inv_gate(Vp, build_formula(A, Vp));
build_formula(#{ ?operator := <<"NOT">>, ?operands := A }, Vp)
  when is_binary(A) ->
    varp_circuit:inv_gate(Vp, build_formula(A, Vp));
build_formula(#{ ?operator := Op, ?operands := [A,B] }, Vp) ->
    X = build_formula(A,Vp),
    Y = build_formula(B,Vp),
    case Op of
	<<"AND">> -> varp_circuit:and_gate(Vp, X, Y);
	<<"XOR">> -> varp_circuit:xor_gate(Vp, X, Y);
	<<"OR">> -> varp_circuit:or_gate(Vp, X, Y);
	<<"IMPLIES">> -> varp_circuit:imp_gate(Vp, X, Y);
	<<"EQUIVALENT">> -> varp_circuit:equ_gate(Vp, X, Y)
    end;
build_formula(#{ ?operator := Op, ?operands := As }, Vp) ->
    Bs = [build_formula(A, Vp) || A <- As],
    case Op of
	<<"AND">> -> varp_circuit:all(Vp, Bs);
	<<"OR">> -> varp_circuit:any(Vp, Bs);
	<<"XOR">> -> varp_circuit:odd(Vp, Bs);
	<<"EQUIVALENT">> -> varp_circuit:even(Vp, Bs)
    end;
build_formula(<<"NOT ",Var/binary>>, Vp) ->
    varp_circuit:inv_gate(Vp, build_var(Var, Vp));
build_formula(Var, Vp) when is_binary(Var) ->
    build_var(Var, Vp).

build_var(Var, Vp) ->
    case varp_nif:find_symbol(Vp, {Var,[]}) of
	false -> varp_circuit:atom(Vp, Var);
	{bool,X} -> X
    end.
