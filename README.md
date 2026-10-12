# ellm

Erlang LLM client with one API over several backends:

| backend  | module        | endpoint                    |
|----------|---------------|-----------------------------|
| `claude` | `ellm_claude` | Anthropic `/v1/messages`    |
| `openai` | `ellm_openai` | OpenAI `/v1/chat/completions` (+ audio, files) |

Depends on `rester` and OTP 27+ (`json` module).

## Quick start

    erl -s ellm -config <config-file (see sys.config)> [-ellm backend <name>]

    ellm:start().
    ellm:ask("Vad heter Sveriges huvudstad?").
    ellm:ask("...", #{ backend => openai, model => "gpt-4o" }).
    ellm:chat().                          %% prompt loop, "bye" to quit
    ellm:chat(#{ system => "Svara kort", log => "chat.log" }).
    ellm:show_models(claude).
    ellm:set_backend(openai).

## API keys

Per backend option `apikey` in sys.config:

* `"sk-..."` the key itself (keep it out of git)
* `"$VAR"` read from environment variable
* `".authinfo"` look up `~/.authinfo`

Unset: `$ANTHROPIC_API_KEY` / `$OPENAI_API_KEY`, then `~/.authinfo` with
`machine api.anthropic.com login USER apikey KEY` (or `anthropic.com`,
`api.openai.com`, `openai.com`).

## Messages

Neutral format, the same for all backends:

    #{ role => system | user, content => Bin }
    #{ role => assistant, content => Bin, tool_calls => [Call], native => _ }
    #{ role => tool, tool_call_id => Id, content => Bin, is_error => Bool }

    Call = #{ id => Bin, name => Bin, arguments => Map }

`native` keeps the backend's own reply (e.g. Claude thinking blocks) so it
can be sent back unchanged; another backend ignores it, so a conversation
can move between backends.

## Tools

    Tool = #{ name => Bin, description => Bin, schema => JsonSchemaMap }
    Handler = fun(Name, Args, State) -> {ok | error, IoData, State1} end
    {ok, Messages1, State1} = ellm:run(Messages, Tools, Handler, State, Opts).

Example: `ellm_sat` (needs `varp`)

    ellm_sat:test_prove().
    ellm_sat:run("...", #{ backend => openai }).

Text editing: `ellm_text_buffer` (buffer), `ellm_text_edit` (edit tool,
buffer kept in the loop state) and `ellm_text_window` (wx editor window).

    ellm_text_buffer:test().              %% unit tests
    ellm_text_edit:test2().               %% run from the ellm directory
    ellm_text_edit:run("Create hello.c with a hello world program").
    {ok, W} = ellm_text_window:start("hello.c"),
    ellm_text_window:find(W, "main"),
    ellm_text_window:run(W, "Make main return via exit(0)", #{}).

The window can also be edited by hand; manual edits are read back into
the buffer before every API call.

## Claude options

`model` (default `claude-opus-5-5`), `max_tokens` (16000),
`effort` (`low`..`max`), `fallbacks` (`"default"` or `none`, server side
fallback model on refusal).
