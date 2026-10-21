SCRIPTING := addons/sourcemod/scripting
PLUGINS := addons/sourcemod/plugins
NAMES := $(patsubst $(SCRIPTING)/%.sp,%,$(wildcard $(SCRIPTING)/*.sp))
INCLUDES := $(shell find $(SCRIPTING)/include -name '*.inc' 2>/dev/null)
SPCOMP ?= spcomp64

all: $(NAMES)
$(NAMES): %: $(PLUGINS)/%.smx

# A plugin also depends on the sources in its own folder and every include.
.SECONDEXPANSION:
$(PLUGINS)/%.smx: $(SCRIPTING)/%.sp \
		$$(shell find $(SCRIPTING)/$$* -name '*.sp' 2>/dev/null) \
		$(INCLUDES) | $(PLUGINS)
	cd $(SCRIPTING) && $(SPCOMP) -i include $*.sp -o $(CURDIR)/$@

$(PLUGINS):
	mkdir -p $@

DIST_NAME := sm-showtriggers
DIST := dist
TREE := $(DIST)/tree
COMMIT_TIME = $(shell TZ=UTC git log -1 --date=format-local:$(1) --format=%cd)
VERSION = $(or $(patsubst v%,%,$(shell git describe --tags --exact-match \
	--match 'v*' 2>/dev/null)),dev-$(shell git rev-parse HEAD | cut -c1-8))$(if \
	$(shell git status --porcelain -- addons LICENSE.txt README.md),-dirty)

dist:
	@git rev-parse -q --verify HEAD >/dev/null || { echo "make dist" \
		"needs a commit" >&2; exit 1; }
	@test -x "$(SMDIR)/spcomp64" || { echo "SMDIR must be a SourceMod" \
		"scripting folder with spcomp64 in it" >&2; exit 1; }
	rm -rf $(DIST)
	mkdir -p $(TREE)
	cp -R addons LICENSE.txt README.md $(TREE)/
	rm -rf $(TREE)/$(PLUGINS)
	mkdir $(TREE)/$(PLUGINS) $(TREE)/$(SCRIPTING)/smdir
	cp "$(SMDIR)/spcomp64" $(TREE)/$(SCRIPTING)/smdir/
	cp -R "$(SMDIR)/include" $(TREE)/$(SCRIPTING)/smdir/
	cd $(TREE)/$(SCRIPTING) && for name in $(NAMES); do \
		smdir/spcomp64 -i include '__DATE__="$(call COMMIT_TIME,%m/%d/%Y)"' \
			'__TIME__="$(call COMMIT_TIME,%H:%M:%S)"' \
			'PLUGIN_VERSION="$(VERSION)"' \
			$$name.sp -o ../plugins/$$name.smx || exit 1; \
	done
	cd $(TREE) && find addons LICENSE.txt README.md \
		-path $(SCRIPTING)/smdir -prune -o -type f \
		-exec chmod 644 {} + \
		-exec env TZ=UTC touch -t $(call COMMIT_TIME,%Y%m%d%H%M.%S) {} + \
		-print | LC_ALL=C sort | \
		TZ=UTC zip -X -D ../$(DIST_NAME)-$(VERSION).zip -@

clean:
	rm -rf $(PLUGINS) $(DIST)

.PHONY: all clean dist $(NAMES)
