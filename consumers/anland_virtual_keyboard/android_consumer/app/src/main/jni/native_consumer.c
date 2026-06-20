#define _GNU_SOURCE
#include <android/log.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>
#include <errno.h>
#include <jni.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <dirent.h>
#include <unistd.h>

#include "anw_hidden.h"
#include "display_consumer.h"
#include "protocol.h"

#define TAG "Anland"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

#define PIXEL_FORMAT_RGBA_8888 1
#define MAX_COLLECT_BUFS 8

static struct anw_api api;
static bool api_loaded = false;

struct consumer_state {
    pthread_mutex_t lock;
    ANativeWindow *window;
    display_ctx *ctx;
    pthread_t render_thread;
    volatile bool running;
    volatile bool need_reconnect;

    int buf_count;
    int dmabuf_fds[MAX_COLLECT_BUFS];
    struct buf_info dmabuf_infos[MAX_COLLECT_BUFS];
    void *buf_bits[MAX_COLLECT_BUFS];

    int screen_w;
    int screen_h;
};

static struct consumer_state g_state = {
    .lock = PTHREAD_MUTEX_INITIALIZER,
};

static bool motion_has_last = false;
static float motion_last_x = 0.0f;
static float motion_last_y = 0.0f;

static int find_buf_index(struct consumer_state *s, int fd)
{
    for (int i = 0; i < s->buf_count; i++) {
        if (s->dmabuf_fds[i] == fd)
            return i;
    }
    return -1;
}

/* Find the fd backing a mmap'd address by matching inode from /proc/self/maps
 * against fstat of open fds. */
static int fd_from_maps(void *addr)
{
    FILE *fp = fopen("/proc/self/maps", "r");
    if (!fp)
        return -1;

    uintptr_t target = (uintptr_t)addr;
    char line[512];
    unsigned long map_inode = 0;
    bool found_region = false;

    while (fgets(line, sizeof(line), fp)) {
        uintptr_t start, end;
        char perms[8];
        unsigned long offset;
        unsigned int dev_major, dev_minor;
        unsigned long inode;
        if (sscanf(line, "%lx-%lx %s %lx %x:%x %lu",
                   &start, &end, perms, &offset, &dev_major, &dev_minor, &inode) < 7)
            continue;
        if (target >= start && target < end) {
            map_inode = inode;
            found_region = true;
            break;
        }
    }
    fclose(fp);

    if (!found_region || map_inode == 0)
        return -1;

    DIR *dir = opendir("/proc/self/fd");
    if (!dir)
        return -1;

    struct dirent *ent;
    while ((ent = readdir(dir)) != NULL) {
        if (ent->d_name[0] == '.')
            continue;
        int candidate = atoi(ent->d_name);
        struct stat st;
        if (fstat(candidate, &st) == 0 && st.st_ino == (ino_t)map_inode) {
            closedir(dir);
            return candidate;
        }
    }
    closedir(dir);
    return -1;
}

static int collect_dmabufs(struct consumer_state *s)
{
    ANativeWindow *win = s->window;
    int target = s->buf_count;
    int found = 0;

    LOGI("collecting %d dma-bufs via lock/post", target);

    for (int attempt = 0; attempt < target * 4 && found < target; attempt++) {
        ANativeWindow_Buffer buf;
        if (ANativeWindow_lock(win, &buf, NULL) != 0) {
            LOGE("ANativeWindow_lock failed on attempt %d", attempt);
            break;
        }

        void *bits = buf.bits;
        int fd = fd_from_maps(bits);
        ANativeWindow_unlockAndPost(win);

        if (fd < 0) {
            LOGE("fd_from_maps returned -1 on attempt %d", attempt);
            continue;
        }

        /* deduplicate by bits pointer (stable across lock cycles) */
        bool dup_found = false;
        for (int i = 0; i < found; i++) {
            if (s->buf_bits[i] == bits) {
                dup_found = true;
                break;
            }
        }
        if (dup_found)
            continue;

        int dup_fd = dup(fd);
        if (dup_fd < 0)
            continue;

        s->buf_bits[found] = bits;
        s->dmabuf_fds[found] = dup_fd;
        s->dmabuf_infos[found].stride = buf.stride * 4;
        s->dmabuf_infos[found].format = PIXEL_FORMAT_RGBA_8888;
        s->dmabuf_infos[found].modifier = 0;
        s->dmabuf_infos[found].offset = 0;
        LOGI("  buf[%d]: bits=%p fd=%d dup=%d %dx%d stride=%d",
             found, bits, fd, dup_fd, buf.width, buf.height, buf.stride);
        found++;
    }

    if (found < target) {
        LOGE("only collected %d/%d", found, target);
        for (int i = 0; i < found; i++) {
            close(s->dmabuf_fds[i]);
            s->dmabuf_fds[i] = -1;
        }
        return -1;
    }

    s->buf_count = found;
    LOGI("collected %d dma-bufs", found);
    return 0;
}

static void cleanup_dmabufs(struct consumer_state *s)
{
    for (int i = 0; i < s->buf_count; i++) {
        if (s->dmabuf_fds[i] >= 0) {
            close(s->dmabuf_fds[i]);
            s->dmabuf_fds[i] = -1;
        }
    }
    s->buf_count = 0;
}

static int do_connect(struct consumer_state *s)
{
    const char *sock = "/data/local/tmp/display_daemon.sock";

    if (s->ctx) {
        disconnect(s->ctx);
        s->ctx = NULL;
    }
    cleanup_dmabufs(s);

    ANativeWindow *win = s->window;
    s->screen_w = ANativeWindow_getWidth(win);
    s->screen_h = ANativeWindow_getHeight(win);

    ANativeWindow_setBuffersGeometry(win, s->screen_w, s->screen_h,
                                     AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM);

    int min_undequeued = 0;
    api.query(win, ANATIVEWINDOW_QUERY_MIN_UNDEQUEUED_BUFFERS, &min_undequeued);
    int total = min_undequeued + 2;
    if (total > MAX_COLLECT_BUFS)
        total = MAX_COLLECT_BUFS;

    api.setBufferCount(win, total);

    s->buf_count = total;
    if (collect_dmabufs(s) < 0)
        return -1;

    LOGI("connecting to %s (%dx%d, %d bufs)", sock,
         s->screen_w, s->screen_h, s->buf_count);

    if (connect_to_deamon(&s->ctx, sock) < 0) {
        LOGE("connect_to_deamon failed");
        return -1;
    }

    set_screen_info(s->ctx, s->screen_w, s->screen_h,
                    PIXEL_FORMAT_RGBA_8888, 0);
    push_dmabufs(s->ctx, s->dmabuf_fds, s->dmabuf_infos, s->buf_count);

    s->need_reconnect = false;
    LOGI("connected");
    return 0;
}

static void on_fallback(void *userdata)
{
    struct consumer_state *s = userdata;
    LOGI("fallback triggered");
    s->need_reconnect = true;
}

static void *render_thread_func(void *arg)
{
    struct consumer_state *s = arg;
    LOGI("render thread started");

    while (s->running) {
        if (s->need_reconnect) {
            LOGI("reconnecting...");
            if (do_connect(s) < 0) {
                usleep(500000);
                continue;
            }
            set_fallback_callback(s->ctx, on_fallback, s);
        }

        if (!s->ctx) {
            usleep(100000);
            continue;
        }

        ANativeWindow_Buffer buf;
        if (ANativeWindow_lock(s->window, &buf, NULL) != 0) {
            usleep(16000);
            continue;
        }

        int idx = -1;
        for (int i = 0; i < s->buf_count; i++) {
            if (s->buf_bits[i] == buf.bits) {
                idx = i;
                break;
            }
        }

        if (idx < 0) {
            ANativeWindow_unlockAndPost(s->window);
            usleep(16000);
            continue;
        }

        if (select_dmabuf(s->ctx, idx) < 0 || refresh_done(s->ctx) < 0) {
            ANativeWindow_unlockAndPost(s->window);
            usleep(16000);
            continue;
        }

        ANativeWindow_unlockAndPost(s->window);
    }

    LOGI("render thread stopped");
    return NULL;
}

/* ---------- JNI ---------- */

JNIEXPORT void JNICALL
Java_com_anland_consumer_MainActivity_nativeStart(
    JNIEnv *env, jobject thiz, jobject surface)
{
    if (!api_loaded) {
        if (anw_api_load(&api) < 0) {
            LOGE("failed to load ANativeWindow hidden API");
            return;
        }
        api_loaded = true;
    }

    pthread_mutex_lock(&g_state.lock);

    if (g_state.running) {
        g_state.running = false;
        pthread_mutex_unlock(&g_state.lock);
        pthread_join(g_state.render_thread, NULL);
        pthread_mutex_lock(&g_state.lock);
    }

    if (g_state.ctx) {
        disconnect(g_state.ctx);
        g_state.ctx = NULL;
    }
    motion_has_last = false;
    motion_has_last = false;
    cleanup_dmabufs(&g_state);

    if (g_state.window) {
        ANativeWindow_release(g_state.window);
        g_state.window = NULL;
    }

    g_state.window = ANativeWindow_fromSurface(env, surface);
    if (!g_state.window) {
        LOGE("ANativeWindow_fromSurface failed");
        pthread_mutex_unlock(&g_state.lock);
        return;
    }

    g_state.running = true;
    g_state.need_reconnect = true;
    pthread_create(&g_state.render_thread, NULL, render_thread_func, &g_state);

    pthread_mutex_unlock(&g_state.lock);
}

JNIEXPORT void JNICALL
Java_com_anland_consumer_MainActivity_nativeStop(
    JNIEnv *env, jobject thiz)
{
    pthread_mutex_lock(&g_state.lock);

    if (g_state.running) {
        g_state.running = false;
        pthread_mutex_unlock(&g_state.lock);
        pthread_join(g_state.render_thread, NULL);
        pthread_mutex_lock(&g_state.lock);
    }

    if (g_state.ctx) {
        disconnect(g_state.ctx);
        g_state.ctx = NULL;
    }
    cleanup_dmabufs(&g_state);

    if (g_state.window) {
        ANativeWindow_release(g_state.window);
        g_state.window = NULL;
    }

    pthread_mutex_unlock(&g_state.lock);
}

JNIEXPORT void JNICALL
Java_com_anland_consumer_MainActivity_nativeSendTouch(
    JNIEnv *env, jobject thiz, jint action, jfloat x, jfloat y, jint pointer_id)
{
    if (!g_state.ctx)
        return;
    struct InputEvent ev = {
        .type = INPUT_TYPE_TOUCH,
        .touch = { .action = action, .x = x, .y = y, .pointer_id = pointer_id },
    };
    push_input_event(g_state.ctx, &ev);
}

JNIEXPORT void JNICALL
Java_com_anland_consumer_MainActivity_nativeSendTouchFrame(
    JNIEnv *env, jobject thiz)
{
    if (!g_state.ctx)
        return;
    struct InputEvent ev = {
        .type = INPUT_TYPE_TOUCH_FRAME,
    };
    push_input_event(g_state.ctx, &ev);
}

JNIEXPORT void JNICALL
Java_com_anland_consumer_MainActivity_nativeSendKey(
    JNIEnv *env, jobject thiz, jint action, jint keycode)
{
    if (!g_state.ctx)
        return;
    struct InputEvent ev = {
        .type = INPUT_TYPE_KEY,
        .key = { .action = action, .keycode = keycode },
    };
    push_input_event(g_state.ctx, &ev);
}

JNIEXPORT void JNICALL
Java_com_anland_consumer_MainActivity_nativeSendMouseMotion(
    JNIEnv *env, jobject thiz, jfloat x, jfloat y, jfloat dx, jfloat dy)
{
    if (!g_state.ctx)
        return;

    if (dx == 0.0f && dy == 0.0f && motion_has_last) {
        dx = x - motion_last_x;
        dy = y - motion_last_y;
    }

    motion_last_x = x;
    motion_last_y = y;
    motion_has_last = true;

    struct InputEvent ev = {
        .type = INPUT_TYPE_POINTER_MOTION,
        .pointer_motion = { .x = x, .y = y, .dx = dx, .dy = dy },
    };
    push_input_event(g_state.ctx, &ev);
}

JNIEXPORT void JNICALL
Java_com_anland_consumer_MainActivity_nativeSendMouseButton(
    JNIEnv *env, jobject thiz, jint button, jboolean pressed)
{
    if (!g_state.ctx)
        return;
    struct InputEvent ev = {
        .type = INPUT_TYPE_POINTER_BUTTON,
        .pointer_button = { .button = button, .pressed = pressed ? 1 : 0 },
    };
    push_input_event(g_state.ctx, &ev);
}

JNIEXPORT void JNICALL
Java_com_anland_consumer_MainActivity_nativeSendMouseScroll(
    JNIEnv *env, jobject thiz, jint axis, jfloat value)
{
    if (!g_state.ctx)
        return;
    struct InputEvent ev = {
        .type = INPUT_TYPE_POINTER_AXIS,
        .pointer_axis = { .axis = axis, .value = value, .discrete = 0 },
    };
    push_input_event(g_state.ctx, &ev);
}
