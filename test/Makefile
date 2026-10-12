ERLC="$(shell which erlc)"
ERL_SOURCES=$(wildcard *.erl)
ERL_OBJECTS=$(ERL_SOURCES:%.erl=ebin/%.beam)
EBIN_PATH=-pa ../ebin -pa ../../rester/ebin -pa ebin

all: $(ERL_OBJECTS)

ebin/%.beam: %.erl
	@mkdir -p ebin
	$(ERLC) +debug_info -I ../.. -o ebin $<

test: all
	erl -noshell $(EBIN_PATH) -eval \
	  'case eunit:test(ellm_key_tests, [verbose]) of ok -> halt(0); _ -> halt(1) end.'

clean:
	rm -f $(ERL_OBJECTS)
