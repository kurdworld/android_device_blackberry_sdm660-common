// Stand-in for the stock vendor libstdc++_vendor.so. Blobs that need it only
// import the C++ runtime (operator new/delete, __cxa_*, unwinder), which
// libc++ provides; linking it here keeps it in the blob's lookup group.
#include <new>

extern "C" void libstdcpp_vendor_shim_keepalive() {
    delete new (std::nothrow) char;
}
