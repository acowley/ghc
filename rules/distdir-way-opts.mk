# -----------------------------------------------------------------------------
#
# (c) 2009 The University of Glasgow
#
# This file is part of the GHC build system.
#
# To understand how the build system works and how to modify it, see
#      http://hackage.haskell.org/trac/ghc/wiki/Building/Architecture
#      http://hackage.haskell.org/trac/ghc/wiki/Building/Modifying
#
# -----------------------------------------------------------------------------


# Set compilation flags that additionally depend on a particular way

define distdir-way-opts # args: $1 = dir, $2 = distdir, $3 = way, $4 = stage

# Options for a Haskell compilation:
#   - CONF_HC_OPTS                 source-tree-wide options, selected at
#				   configure-time
#   - SRC_HC_OPTS                  source-tree-wide options from build.mk
#				   (optimisation, heap settings)
#   - libraries/base_HC_OPTS       options from libraries/base for all ways
#   - libraries/base_v_HC_OPTS     options from libraries/base for way v
#   - WAY_v_HC_OPTS                options for this way
#   - EXTRA_HC_OPTS                options from the command-line
#   - -Idir1 -Idir2 ...		   include-dirs from this package
#   - -odir/-hidir/-stubdir        put the output files under $3/build
#   - -osuf/-hisuf/-hcsuf          suffixes for the output files in this way

$1_$2_$3_MOST_HC_OPTS = \
 $$(WAY_$3_HC_OPTS) \
 $$(CONF_HC_OPTS) \
 $$(SRC_HC_OPTS) \
 $$($1_HC_OPTS) \
 $$($1_$2_HC_PKGCONF) \
 $$(if $$($1_$2_PROG),, \
        $$(if $$($1_PACKAGE),-package-name $$($1_PACKAGE)-$$($1_$2_VERSION))) \
 $$(if $$($1_PACKAGE),-hide-all-packages) \
 -i $$(if $$($1_$2_HS_SRC_DIRS),$$(foreach dir,$$($1_$2_HS_SRC_DIRS),-i$1/$$(dir)),-i$1) \
 -i$1/$2/build -i$1/$2/build/autogen \
 -I$1/$2/build -I$1/$2/build/autogen \
 $$(foreach dir,$$(filter-out /%,$$($1_$2_INCLUDE_DIRS)),-I$1/$$(dir)) \
 $$(foreach dir,$$(filter /%,$$($1_$2_INCLUDE_DIRS)),-I$$(dir)) \
 $$(foreach inc,$$($1_$2_INCLUDE),-\#include "$$(inc)") \
 $$(foreach opt,$$($1_$2_CPP_OPTS),-optP$$(opt)) \
 $$(if $$($1_PACKAGE),-optP-include -optP$1/$2/build/autogen/cabal_macros.h) \
 $$(foreach pkg,$$($1_$2_DEPS),-package $$(pkg)) \
 $$(if $$(findstring YES,$$($1_$2_SplitObjs)),$$(if $$(findstring dyn,$3),,-split-objs),) \
 $$($1_$2_HC_OPTS) \
 $$($1_$2_EXTRA_HC_OPTS) \
 $$($1_$2_$3_HC_OPTS) \
 $$($$(basename $$<)_HC_OPTS) \
 $$(EXTRA_HC_OPTS)

# For real Haskell compilations we add -hidir etc.
$1_$2_$3_ALL_HC_OPTS = \
 $$($1_$2_$3_MOST_HC_OPTS) \
 -odir $1/$2/build -hidir $1/$2/build -stubdir $1/$2/build \
 -hisuf $$($3_hisuf) -osuf  $$($3_osuf) -hcsuf $$($3_hcsuf)

ifeq "$4" "0"
# This is a bit of a hack.
# If we are compiling something with the bootstrapping compiler on
# cygwin, and it uses an include file from the rts (say), then we
# need to stop mkdependC from generating a dependincy on
#     c:/ghc/rts/include/Rts.h
# as that confuses make. So we use -isystem instead of -I, which stops
# these dependencies from being generated. Technically this is wrong if
# we depend on a library that is built inside the build tree, and we
# use headers from that library, but currently I don't think that's the
# case.
$1_$2_DEP_INCLUDE_DIRS_FLAG = -isystem
else
$1_$2_DEP_INCLUDE_DIRS_FLAG = -I
endif

# We have to do this mangling using the shell, because words may contain
# spaces and GNU make doesn't have any quoting interpretation.
$1_$2_CC_INC_FLAGS:=$$(shell for i in $$($1_$2_DEP_INCLUDE_DIRS); do echo $$($1_$2_DEP_INCLUDE_DIRS_FLAG)\"$$$$i\"; done)

$1_$2_DIST_CC_OPTS = \
 $$(CONF_CC_OPTS) \
 $$(SRC_CC_OPTS) \
 $$($1_CC_OPTS) \
 $$(foreach dir,$$(filter-out /%,$$($1_$2_INCLUDE_DIRS)),-I$1/$$(dir)) \
 $$(foreach dir,$$(filter /%,$$($1_$2_INCLUDE_DIRS)),-I$$(dir)) \
 $$($1_$2_CC_OPTS) \
 $$($1_$2_CPP_OPTS) \
 $$($1_$2_CC_INC_FLAGS) \
 $$($1_$2_DEP_CC_OPTS)

$1_$2_DIST_LD_LIB_DIRS:=$$(shell for i in $$($1_$2_DEP_LIB_DIRS); do echo \"-L$$$$i\"; done)

$1_$2_DIST_LD_OPTS = \
 $$(CONF_LD_OPTS) \
 $$(SRC_LD_OPTS) \
 $$($1_LD_OPTS) \
 $$($1_$2_LD_OPTS) \
 $$($1_$2_DIST_LD_LIB_DIRS) \
 $$(foreach opt,$$($1_$2_DEP_EXTRA_LIBS),-l$$(opt)) \
 $$($1_$2_DEP_LD_OPTS)

# c.f. Cabal's Distribution.Simple.PreProcess.ppHsc2hs
# We use '' around cflags and lflags to handle paths with backslashes in
# on Windows
$1_$2_$3_HSC2HS_CC_OPTS:=$$(shell for i in $$($1_$2_DIST_CC_OPTS); do echo \'--cflag=$$$$i\'; done)
$1_$2_$3_HSC2HS_LD_OPTS:=$$(shell for i in $$($1_$2_DIST_LD_OPTS); do echo \'--lflag=$$$$i\'; done)

$1_$2_$3_ALL_HSC2HS_OPTS = \
 --cc=$$(WhatGccIsCalled) \
 --ld=$$(WhatGccIsCalled) \
 $$(CONF_HSC2HS_OPTS) \
 $$(SRC_HSC2HS_OPTS) \
 $$(WAY_$3_HSC2HS_OPTS) \
 --cflag=-D__GLASGOW_HASKELL__=$$(ProjectVersionInt) \
 $$($1_$2_$3_HSC2HS_CC_OPTS) \
 $$($1_$2_$3_HSC2HS_LD_OPTS) \
 $$($$(basename $$<)_HSC2HS_OPTS) \
 $$(EXTRA_HSC2HS_OPTS)

$1_$2_$3_ALL_CC_OPTS = \
 $$(WAY_$3_CC_OPTS) \
 $$($1_$2_DIST_CC_OPTS) \
 $$($1_$2_$3_CC_OPTS) \
 $$($$(basename $$<)_CC_OPTS) \
 $$(EXTRA_CC_OPTS)

$1_$2_$3_GHC_CC_OPTS = \
 $$(addprefix -optc, $$($1_$2_$3_ALL_CC_OPTS)) \
 $$($1_$2_$3_MOST_HC_OPTS)

$1_$2_$3_ALL_AS_OPTS = \
 $$(CONF_AS_OPTS) \
 $$(SRC_AS_OPTS)
 $$(WAY_$3_AS_OPTS) \
 $$($1_AS_OPTS) \
 $$($1_$2_AS_OPTS) \
 $$($1_$2_$3_AS_OPTS) \
 $$(EXTRA_AS_OPTS)

$1_$2_$3_ALL_ALEX_OPTS = \
 $$(CONF_ALEX_OPTS) \
 $$(SRC_ALEX_OPTS)
 $$(WAY_$3_ALEX_OPTS) \
 $$($1_ALEX_OPTS) \
 $$($1_$2_ALEX_OPTS) \
 $$($1_$2_$3_ALEX_OPTS) \
 $$(EXTRA_ALEX_OPTS)

$1_$2_$3_ALL_HAPPY_OPTS = \
 $$(CONF_HAPPY_OPTS) \
 $$(SRC_HAPPY_OPTS) \
 $$(WAY_$3_HAPPY_OPTS) \
 $$($1_HAPPY_OPTS) \
 $$($1_$2_HAPPY_OPTS) \
 $$($1_$2_$3_HAPPY_OPTS) \
 $$(EXTRA_HAPPY_OPTS)

endef

