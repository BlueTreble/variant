EXTENSION = $(shell grep -m 1 '"name":' META.json | \
sed -e 's/[[:space:]]*"name":[[:space:]]*"\([^"]*\)",/\1/')
EXTVERSION = $(shell grep -m 1 '"version":' META.json | \
sed -e 's/[[:space:]]*"version":[[:space:]]*"\([^"]*\)",\{0,1\}/\1/')

DATA         = $(filter-out $(wildcard sql/*--*.sql),$(wildcard sql/*.sql))
DOCS         = $(wildcard doc/*.md)
TESTS        = $(wildcard test/sql/*.sql)
REGRESS      = $(patsubst test/sql/%.sql,%,$(TESTS))
REGRESS_OPTS = --inputdir=test --load-language=plpgsql
MODULES      = $(patsubst %.c,%,$(wildcard src/*.c))
PG_CONFIG    = pg_config

EXTRA_CLEAN  = $(wildcard $(EXTENSION)-*.zip)
VERSION 	 = $(shell $(PG_CONFIG) --version | awk '{print $$2}' | sed -e 's/devel$$//')
MAJORVER 	 = $(shell echo $(VERSION) | cut -d . -f1,2 | tr -d .)

test		 = $(shell test $(1) $(2) $(3) && echo yes || echo no)

GE91		 = $(call test, $(MAJORVER), -ge, 91)
LT94		 = $(call test, $(MAJORVER), -lt, 94)
GE94		 = $(call test, $(MAJORVER), -ge, 94)


ifeq ($(LT94),yes)
override CFLAGS += -DOVERRIDE_FINFO
endif

ifeq ($(GE94),yes)
override CFLAGS += -DLONG_PARSETYPE
endif

ifeq ($(GE91),yes)
all: sql/$(EXTENSION)--$(EXTVERSION).sql

sql/$(EXTENSION)--$(EXTVERSION).sql: sql/$(EXTENSION).sql
	cp $< $@

DATA = $(wildcard sql/*--*.sql)
EXTRA_CLEAN += sql/$(EXTENSION)--$(EXTVERSION).sql
endif

PGXS := $(shell $(PG_CONFIG) --pgxs)

include $(PGXS)

.PHONY: results
results:
	rsync -rlpgovP results/ test/expected

tag:
	git branch $(EXTVERSION)
	git push --set-upstream origin $(EXTVERSION)

dist:
	git archive --prefix=$(EXTENSION)-$(EXTVERSION)/ -o $(EXTENSION)-$(EXTVERSION).zip HEAD

# To use this, do make print-VARIABLE_NAME
print-%  : ; @echo $* = $($*)
