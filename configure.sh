#!/usr/bin/env bash

# Removes all generated makefiles
make -f Makefile mrproper

# Dependencies for local or global builds.
# When building the packages separately, dependencies are not set as everything
# should already be available in $(COQMF_LIB)/user-contrib/MetaCoq/*
# For local builds, we set specific dependencies of each subproject in */metacoq-config

# CWD=`pwd`

if command -v coqc >/dev/null 2>&1
then
    COQLIB=`coqc -where`

    if [ "$1" = "local" ]; then
        echo "Building MetaCoq locally"
        PCUIC_DEPS="-I ../template-coq/build -R ../template-coq/theories MetaCoq.Template"
        SAFECHECKER_DEPS="-R ../pcuic/theories MetaCoq.PCUIC"
        ERASURE_DEPS="-R ../safechecker/theories MetaCoq.SafeChecker"
        TRANSLATIONS_DEPS=""
    else
        echo "Building MetaCoq globally (default)"
        # The safechecker and erasure plugins depend on the extractable template-coq plugin
        # These dependencies should not be necessary when separate linking of ocaml object
        # files is supported by coq_makefile
        PCUIC_DEPS="-I ${COQLIB}/user-contrib/MetaCoq/Template"
        SAFECHECKER_DEPS=""
        ERASURE_DEPS=""
        TRANSLATIONS_DEPS=""
    fi

    echo "# DO NOT EDIT THIS FILE: autogenerated from ./configure.sh" > pcuic/metacoq-config
    echo "# DO NOT EDIT THIS FILE: autogenerated from ./configure.sh" > safechecker/metacoq-config
    echo "# DO NOT EDIT THIS FILE: autogenerated from ./configure.sh" > erasure/metacoq-config
    echo "# DO NOT EDIT THIS FILE: autogenerated from ./configure.sh" > translations/metacoq-config

    echo ${PCUIC_DEPS} >> pcuic/metacoq-config
    echo ${PCUIC_DEPS} ${SAFECHECKER_DEPS} >> safechecker/metacoq-config
    echo ${PCUIC_DEPS} ${SAFECHECKER_DEPS} ${ERASURE_DEPS} >> erasure/metacoq-config
    echo ${PCUIC_DEPS} ${TRANSLATIONS_DEPS} >> translations/metacoq-config
else
    echo "Error: coqc not found in path"
fi
