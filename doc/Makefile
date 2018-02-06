###########################################################
# This file builds the documentation.
###########################################################

# tags
LATEST:=$(shell git describe --abbrev=0 --tags | tr -d v)

# binaries
DMD=dmd
RDMD=rdmd
DDOC=$(DMD) -w -c -o- -version=StdDdoc -version=Have

# folders
DOC_OUTPUT_DIR=web
DOC_SOURCE_DIR=doc
GENERATED=.generated
SOURCE_DIR=source
DLANGORG_DIR=$(DOC_SOURCE_DIR)/dlang.org

###########################################################
# setup packages
##########################################################

# Packages. Just mention the package name here. The contents of package
# xy/zz is in variable PACKAGE_xy_zz. This allows automation in iterating
# packages and their modules.
M = stdx
PACKAGES = $M $M/collections
PACKAGE_stdx_collections = array common dlist hashtable package slist

MOD_EXCLUDES=$(addprefix --ex=,)

###########################################################
# Setup macros + generate dynamic info needed
###########################################################

all: html

DLANGORG_MACROS=$(addprefix $(DLANGORG_DIR)/, macros html dlang.org)
STDDOC=$(addsuffix .ddoc, ${DLANGORG_MACROS} ${GENERATED}/${LATEST} $(DLANGORG_DIR)/std $(DOC_SOURCE_DIR)/custom ${GENERATED}/modlist) $(NODATETIME)

${GENERATED}/${LATEST}.ddoc :
	mkdir -p $(dir $@)
	echo "LATEST=${LATEST}" >$@
	echo "LATEST_STABLE=$(shell git tag | grep -vE "(alpha|beta)" | tail -n1 | tr -d v)" >> $@

${GENERATED}/modlist.ddoc: $(DOC_SOURCE_DIR)/dlang.org/modlist.d $(SOURCE_DIR)
	mkdir -p $(dir $@)
	$(RDMD) --compiler=$(DMD) $< --dump=$M $(SOURCE_DIR) $(MOD_EXCLUDES) >$@

###########################################################
# Makefile bootstrapping
# It's mostly about the conversion from abc.foo -> abc_foo
###########################################################

# Given one or more packages, returns the modules they contain
P2MODULES=$(foreach P,$1,$(addprefix $P/,$(PACKAGE_$(subst /,_,$P))))
P3_MODULES=$(call P2MODULES,$(PACKAGES))
SRC_DOCUMENTABLES = index.d $(addsuffix .d,$(P3_MODULES))

# D file to html, e.g. std/file -> std_file.html
# But "package.d" is special cased: std/range/package.d -> std_range.html
D2HTML=$(foreach p,$1,$(if $(subst package.d,,$(notdir $p)),$(subst /,_,$(subst .d,.html,$p)),$(subst /,_,$(subst /package.d,.html,$p))))

HTMLS=$(addprefix $(DOC_OUTPUT_DIR)/, \
	$(call D2HTML, $(SRC_DOCUMENTABLES)))

$(DOC_OUTPUT_DIR)/. :
	mkdir -p $@

# everything except index.d needs a source path
ADDSOURCE=$(if $(subst index.d,,$1),$(SOURCE_DIR)/$1,$1)

# For each module, define a rule e.g.:
# ../web/phobos/std_conv.html : std/conv.d $(STDDOC) ; ...
$(foreach p,$(SRC_DOCUMENTABLES),$(eval \
$(DOC_OUTPUT_DIR)/$(call D2HTML,$p) : $(call ADDSOURCE,$p) $(STDDOC) ;\
  $(DDOC) $(STDDOC) -I$(SOURCE_DIR) -Df$$@ $$<))

###########################################################
# Setup all other resources needed by dlang.org
###########################################################

IMAGES=favicon.ico

JAVASCRIPT=$(addsuffix .js, $(addprefix js/, \
	codemirror-compressed dlang ddox listanchors run run_examples jquery-1.7.2.min))

STYLES=$(addsuffix .css, $(addprefix css/, \
	style print custom codemirror))

ALL_FILES = $(addprefix $(DOC_OUTPUT_DIR)/, \
	$(STYLES) $(IMAGES) $(JAVASCRIPT))

$(DOC_OUTPUT_DIR)/css/custom.css: $(DOC_SOURCE_DIR)/custom.css
	@mkdir -p $(dir $@)
	cp $< $@

$(DOC_OUTPUT_DIR)/js/run_examples.js: $(DOC_SOURCE_DIR)/run_examples_custom.js
	@mkdir -p $(dir $@)
	cp $< $@

$(DOC_OUTPUT_DIR)/% : $(DLANGORG_DIR)/%
	@mkdir -p $(dir $@)
	cp $< $@

html : $(DOC_OUTPUT_DIR)/. $(HTMLS) $(ALL_FILES)

clean:
	rm -rf $(DOC_OUTPUT_DIR)
	rm -rf $(GENERATED)

# prints the listed modules and sources
debug:
	@echo $(SRC_DOCUMENTABLES)
	@echo $(STDDOC)
