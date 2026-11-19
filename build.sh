#!/bin/sh
# Compile the library, the example and the tests with fpc, then run the tests.
#   ./build.sh            build + run tests
#   FPC=/path/to/fpc ./build.sh
set -e
cd "$(dirname "$0")"
FPC=${FPC:-fpc}
OPTS="-vwn -Sew -Fu. -FUlib"   # -Sew: warnings are errors
mkdir -p lib
$FPC $OPTS -B BinDist.Factory.pas
$FPC $OPTS -FEexamples examples/SmokeTest.lpr
$FPC $OPTS -FEtests tests/TestHelpers.lpr
$FPC $OPTS -FEtests tests/TestClient.lpr
./tests/TestHelpers
./tests/TestClient
