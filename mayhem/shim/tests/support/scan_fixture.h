// Stand-in for upstream's tests/support/scan_fixture.h: libscan/pst/rtf.spec.cpp only needs gtest
// from it, and the real fixture drags in the whole vcpkg dependency closure.
#pragma once
#include <gtest/gtest.h>
