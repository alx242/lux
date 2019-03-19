LUXDIRS=$(filter-out .,$(shell lux --mode=list_dir *))

.PHONY: all build test clean info

all: build test

build:
	@for d in $(LUXDIRS); do \
	   if test -f $$d/Makefile ; then \
	      (cd $$d && $(MAKE) $@) ; \
	   fi; \
	done
test:
	lux .

clean:
	rm -rf lux_logs chatty_*.log erl_crash.dump *~
	@for d in $(LUXDIRS); do \
	   if test -f $$d/Makefile ; then \
	      (cd $$d && $(MAKE) $@) ; \
	   fi; \
	done
info:
	@echo "LUXDIRS=$(LUXDIRS)"
