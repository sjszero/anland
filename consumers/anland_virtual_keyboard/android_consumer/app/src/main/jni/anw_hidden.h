#ifndef ANW_HIDDEN_H
#define ANW_HIDDEN_H

#include <android/native_window.h>
#include <dlfcn.h>
#include <stdint.h>

/* Query constants */
#define ANATIVEWINDOW_QUERY_MIN_UNDEQUEUED_BUFFERS 3

/* Hidden API function pointers, resolved via dlsym */
typedef int (*pfn_ANativeWindow_setBufferCount)(ANativeWindow *, size_t);
typedef int (*pfn_ANativeWindow_query)(const ANativeWindow *, int, int *);
struct anw_api {
    pfn_ANativeWindow_setBufferCount setBufferCount;
    pfn_ANativeWindow_query         query;
};

static inline int anw_api_load(struct anw_api *api)
{
    void *lib = dlopen("libnativewindow.so", RTLD_NOW);
    if (!lib)
        return -1;

    api->setBufferCount = (pfn_ANativeWindow_setBufferCount) dlsym(lib, "ANativeWindow_setBufferCount");
    api->query          = (pfn_ANativeWindow_query)         dlsym(lib, "ANativeWindow_query");

    if (!api->setBufferCount || !api->query)
        return -1;

    return 0;
}

#endif
