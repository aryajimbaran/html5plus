#!/bin/bash
# Copyright (c) 2012, the Dart project authors.  Please see the LICENSE file
# for details. All rights reserved. Use of this source code is governed by a
# MIT-style license that can be found in the LICENSE file.

# bail on error
set -e

# TODO(sigmund): replace with a real test runner
DIR=$( cd $( dirname "${BASH_SOURCE[0]}" ) && pwd )

# Note: dart_analyzer needs to be run from the root directory for proper path
# canonicalization.
pushd $DIR/..
echo Analyzing library for warnings or type errors
dart_analyzer --fatal-warnings --fatal-type-errors lib/*.dart
popd

for test in $DIR/*_test.dart; do
  echo "Running test suite: $test"
  dart --enable-type-checks --enable-asserts $test
done
