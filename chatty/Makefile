SUBDIRS=src test

.PHONY: all build test clean info

all build test clean:
	@for d in $(SUBDIRS); do \
	   if [ -f $$d/Makefile ] ; then \
	      (cd $$d && $(MAKE) $@) ; \
	   fi; \
	done

info:
	@echo "SUBDIRS=$(SUBDIRS)"
