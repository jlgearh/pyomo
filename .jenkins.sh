#!/usr/bin/env bash
# Important environment variables:
#
# WORKSPACE: path to the base WORKSPACE.  This script assumes that there
#     are 3 available subdirectories: pyomo (the pyomo source checkout,
#     pyutilib (the pyutilib source checkout) and pyomo-model-libraries
#     (the checkout of the additional model libraries repo).  It will
#     create two additional directories within WORKSPACE: python (a
#     virtualenv) and config (the local Pyomo configuration/cache
#     directory)
#
# CATEGORY: the category to pass to test.pyomo (defaults to nightly)
#
# TEST_SUITES: Paths (module or directory) to be passed to nosetests to
#     run. (defaults to "pyomo '$WORKSPACE/pyomo-model-libraries'")
#
# SLIM: If nonempty, then the virtualenv will only have pip, setuptools,
#     and wheel installed.  Otherwise the virtualenv will inherit the
#     system site-packages.
#
# CODECOV_TOKEN: the token to use when uploading results to codecov.io
#
# CODECOV_ARGS: additional arguments to pass to the codecov uploader
#     (e.g., to support SSL certificates)
#
# DISABLE_COVERAGE: if nonempty, then coverage analysis is disabled
#
# PYOMO_SETUP_ARGS: passed to the 'python setup.py develop' command
#     (e.g., to specify --with-cython)
#
# PYOMO_DOWNLOAD_ARGS: passed to the 'pyomo download-extensions" command
#     (e.g., to set up local SSL certificate authorities)
#
if test -z "$WORKSPACE"; then
    export WORKSPACE=`pwd`
fi
if test -z "$CATEGORY"; then
    export CATEGORY=nightly
fi
if test -z "$TEST_SUITES"; then
    export TEST_SUITES="pyomo ${WORKSPACE}/pyomo-model-libraries"
fi
if test -z "$SLIM"; then
    export VENV_SYSTEM_PACKAGES='--system-site-packages'
fi

if test "$WORKSPACE" != "`pwd`"; then
    echo "ERROR: pwd is not WORKSPACE"
    echo "   pwd=       `pwd`"
    echo "   WORKSPACE= $WORKSPACE"
    exit 1
fi
MODE="$1"

if test -z "$MODE" -o "$MODE" == setup; then
    # Clean old PYC files and remove any previous virtualenv
    echo "#"
    echo "# Removing python virtual environment"
    echo "#"
    rm -rf ${WORKSPACE}/python
    echo "#"
    echo "# Cleaning out old .pyc and cython files"
    echo "#"
    for EXT in pyc pyx pyd so dylib dll; do
        find ${WORKSPACE}/pyomo -name \*.$EXT -delete
        find ${WORKSPACE}/pyutilib -name \*.$EXT -delete
    done

    # Set up the local lpython
    echo ""
    echo "#"
    echo "# Setting up virtual environment"
    echo "#"
    pyver=$(python -c 'import sys; print("%d%d" % sys.version_info[:2])')
    if [ $pyver -lt 36 ]; then
        virtualenv python $VENV_SYSTEM_PACKAGES --clear --relocatable
    else
        python -m venv $VENV_SYSTEM_PACKAGES ${WORKSPACE}/python
    fi
    # Put the venv at the beginning of the PATH
    export PATH="$WORKSPACE/python/bin:$PATH"
    # Because modules set the PYTHONPATH, we need to make sure that the
    # virtualenv appears first
    LOCAL_SITE_PACKAGES=`python -c "from distutils.sysconfig import get_python_lib; print(get_python_lib())"`
    export PYTHONPATH="$LOCAL_SITE_PACKAGES:$PYTHONPATH"

    # Set up Pyomo, PyUtilib checkouts
    echo ""
    # configure the Pyomo configuration directory
    echo "#"
    echo "# Installing python modules"
    echo "#"
    pushd "$WORKSPACE/pyutilib" || exit 1
    python setup.py develop || exit 1
    popd
    pushd "$WORKSPACE/pyomo" || exit 1
    python setup.py develop $PYOMO_SETUP_ARGS || exit 1
    popd
    #
    # DO NOT install pyomo-model-libraries
    #

    # Set up coverage tracking for subprocesses
    if test -z "$DISABLE_COVERAGE"; then
        # Clean up old coverage files
        rm -fv ${WORKSPACE}/pyomo/.coverage ${WORKSPACE}/pyomo/.coverage.*
        # Set up coverage for this build
        export COVERAGE_PROCESS_START=${WORKSPACE}/coveragerc
        cp ${WORKSPACE}/pyomo/.coveragerc ${COVERAGE_PROCESS_START}
        echo "data_file=${WORKSPACE}/pyomo/.coverage" \
            >> ${COVERAGE_PROCESS_START}
        echo 'import coverage; coverage.process_startup()' \
            > "${LOCAL_SITE_PACKAGES}/run_coverage_at_startup.pth"
    fi

    # Move into the pyomo directory
    pushd ${WORKSPACE}/pyomo || exit 1

    # Set a local Pyomo configuration dir within this workspace
    export PYOMO_CONFIG_DIR="${WORKSPACE}/config"
    echo ""
    echo "PYOMO_CONFIG_DIR=$PYOMO_CONFIG_DIR"
    echo ""

    # Use Pyomo to download & compile binary extensions
    i=0
    while /bin/true; do
        i=$[$i+1]
        echo "Downloading pyomo extensions (attempt $i)"
        pyomo download-extensions $PYOMO_DOWNLOAD_ARGS
        if test $? == 0; then
            break
        elif test $i -ge 3; then
            exit 1
        fi
        DELAY=$(( RANDOM % 30 + 15))
        echo "Pausing $DELAY seconds before re-attempting download"
        sleep $DELAY
    done
    pyomo build-extensions || exit 1

    # Print useful version information
    echo ""
    echo "#"
    echo "# Package information:"
    echo "#"
    python --version
    pip --version
    pip list
    echo "#"
    echo "# Installed programs:"
    echo "#"
    gjh -v || echo "GJH not found"
    glpsol -v || echo "GLPK not found"
    cbc -quit || echo "CBC not found"
    cplex -c quit || echo "CPLEX not found"
    gurobi_cl --version || echo "GUROBI not found"
    ipopt -v || echo "IPOPT not found"
    gams || echo "GAMS not found"

    # Exit ${WORKSPACE}/pyomo
    popd
fi

if test -z "$MODE" -o "$MODE" == test; then
    # Move into the pyomo directory
    pushd ${WORKSPACE}/pyomo || exit 1

    echo ""
    echo "#"
    echo "# Running Pyomo tests"
    echo "#"
    test.pyomo -v --cat=$CATEGORY $TEST_SUITES

    # Combine the coverage results and upload
    if test -z "$DISABLE_COVERAGE"; then
        echo ""
        echo "#"
        echo "# Processing coverage information in "`pwd`
        echo "#"
        #
        # Note, that the PWD should still be $WORKSPACE/pyomo
        #
        coverage combine || exit 1
        coverage report -i
        export OS=`uname`
        if test -z "$CODECOV_TOKEN"; then
            coverage xml
        else
            CODECOV_JOB_NAME=`echo ${JOB_NAME} | sed -r 's/^(.*autotest_)?Pyomo_([^\/]+).*/\2/'`.$BUILD_NUMBER.$python
            i=0
            while /bin/true; do
                i=$[$i+1]
                echo "Uploading coverage to codecov (attempt $i)"
                codecov -X gcovcodecov -X gcov -X s3 --no-color \
                    -t $CODECOV_TOKEN --root `pwd` -e OS,python \
                    --name $CODECOV_JOB_NAME $CODECOV_ARGS \
                    | tee .cover.upload
                if test $? == 0 -a `grep -i error .cover.upload | wc -l` -eq 0; then
                    break
                elif test $i -ge 4; then
                    exit 1
                fi
                DELAY=$(( RANDOM % 30 + 15))
                echo "Pausing $DELAY seconds before re-attempting upload"
                sleep $DELAY
            done
        fi
        rm .coverage
    fi

    # Exit ${WORKSPACE}/pyomo
    popd
fi
