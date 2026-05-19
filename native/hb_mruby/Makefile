ERL_TOP   ?= $(shell erl -noshell -eval 'io:format("~s", [code:root_dir()]), halt().' 2>/dev/null)
EILIBS    = -L$(ERL_TOP)/usr/lib -lei
EINC      = -I$(ERL_TOP)/usr/include

MRUBY_REF ?= 3.3.0
MRUBY_DIR ?= _build/mruby
MRUBY_CONFIG ?= $(shell command -v mruby-config 2>/dev/null)
ifeq ($(MRUBY_CONFIG),)
MRUBY_CONFIG := $(CURDIR)/$(MRUBY_DIR)/build/host/bin/mruby-config
endif

MRUBY_CFLAGS = $(shell $(MRUBY_CONFIG) --cflags)
MRUBY_LDFLAGS = $(shell $(MRUBY_CONFIG) --ldflags)
MRUBY_LIBS = $(shell $(MRUBY_CONFIG) --libs)

CC      = gcc
CFLAGS  = -O2 -Wall $(EINC) $(MRUBY_CFLAGS)
LDFLAGS = $(EILIBS) $(MRUBY_LDFLAGS) $(MRUBY_LIBS)

TARGET  = hb_mruby
SRC     = hb_mruby.c

.PHONY: all clean

all: $(TARGET)

$(MRUBY_CONFIG):
	mkdir -p _build
	test -d $(MRUBY_DIR)/.git || \
		git clone --depth 1 --branch $(MRUBY_REF) https://github.com/mruby/mruby.git $(MRUBY_DIR)
	cd $(MRUBY_DIR) && rake

$(TARGET): $(SRC) $(MRUBY_CONFIG)
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

clean:
	rm -f $(TARGET)
