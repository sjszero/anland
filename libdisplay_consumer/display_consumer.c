#define _GNU_SOURCE
#include "display_consumer.h"
#include "../common/socket_utils.h"

#include <errno.h>
#include <poll.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <unistd.h>

struct display_ctx {
    int      ctrl_fd;
    int      data_fd;
    int      buf_ready_efd;
    int      fence_fd;        /* read end of the dedicated render-done fence channel */
    int      shm_fd;
    volatile uint32_t *shm_ptr;
    uint32_t screen_w, screen_h;
    uint32_t pixel_format;
    bool     fallback;
    bool     buffer_pending;

    int              stored_fds[MAX_BUFS];
    struct buf_info  stored_infos[MAX_BUFS];
    int              stored_count;

    void (*fallback_cb)(void *);
    void (*exit_fallback_cb)(void *);
    void  *fallback_userdata;
    void  *exit_fallback_userdata;
};

static int create_shm(display_ctx *ctx)
{
    ctx->shm_fd = memfd_create("buf_select", MFD_CLOEXEC);
    if (ctx->shm_fd < 0)
        return -1;
    if (ftruncate(ctx->shm_fd, sizeof(uint32_t)) < 0) {
        close(ctx->shm_fd);
        ctx->shm_fd = -1;
        return -1;
    }
    ctx->shm_ptr = mmap(NULL, sizeof(uint32_t), PROT_READ | PROT_WRITE,
                        MAP_SHARED, ctx->shm_fd, 0);
    if (ctx->shm_ptr == MAP_FAILED) {
        ctx->shm_ptr = NULL;
        close(ctx->shm_fd);
        ctx->shm_fd = -1;
        return -1;
    }
    *ctx->shm_ptr = 0;
    return 0;
}

static int send_hello_fds(display_ctx *ctx)
{
    /* Two dedicated socketpairs:
     *   - data:  consumer->producer input/bufs (reverse direction reserved for future)
     *   - fence: producer->consumer render-done messages; the message itself is the
     *            "frame rendered" signal (no separate eventfd, no cross-channel ordering).
     * We keep the read ends and hand the write ends to the producer. The fd slot order
     * must match the producer's pickup_fds(): { buf_ready, fence, data, shm }. */
    int sv[2], fv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) < 0)
        return -1;
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fv) < 0) {
        close(sv[0]);
        close(sv[1]);
        return -1;
    }
    ctx->data_fd  = sv[0];
    ctx->fence_fd = fv[0];

    struct ctrl_msg hdr = { .type = CTRL_MSG_CONSUMER_HELLO, .size = 0 };
    int fds[4] = { ctx->buf_ready_efd, fv[1], sv[1], ctx->shm_fd };
    int ret = send_fds(ctx->ctrl_fd, &hdr, sizeof(hdr), fds, 4);
    close(sv[1]);
    close(fv[1]);
    return ret;
}

static void enter_fallback(display_ctx *ctx);

static int push_dmabufs_internal(display_ctx *ctx)
{
    if (ctx->stored_count <= 0)
        return 0;

    struct data_msg dhdr = {
        .type = DATA_MSG_BUFS_READY,
        .size = ctx->stored_count * sizeof(struct buf_info),
    };
    if (send_fds(ctx->data_fd, &dhdr, sizeof(dhdr),
                 ctx->stored_fds, ctx->stored_count) < 0) {
        enter_fallback(ctx);
        return -1;
    }
    if (send_all(ctx->data_fd, ctx->stored_infos,
                 ctx->stored_count * sizeof(struct buf_info)) < 0) {
        enter_fallback(ctx);
        return -1;
    }
    return 0;
}

static bool try_exit_fallback(display_ctx *ctx)
{
    struct pollfd pfd = { .fd = ctx->ctrl_fd, .events = POLLIN };
    if (poll(&pfd, 1, 0) > 0 && (pfd.revents & POLLIN)) {
        struct ctrl_msg hdr;
        if (recv_all(ctx->ctrl_fd, &hdr, sizeof(hdr)) == 0 &&
            hdr.type == CTRL_MSG_FDS_READY) {
            ctx->fallback = false;
            push_dmabufs_internal(ctx);
            if (ctx->exit_fallback_cb){
                ctx->exit_fallback_cb(ctx->exit_fallback_userdata);
            }
            return true;
        }
    }
    return false;
}

static void enter_fallback(display_ctx *ctx)
{
    if (ctx->fallback)
        return;
    ctx->fallback = true;
    ctx->buffer_pending = false;

    if (ctx->data_fd >= 0)         { close(ctx->data_fd);         ctx->data_fd = -1; }
    if (ctx->buf_ready_efd >= 0)   { close(ctx->buf_ready_efd);   ctx->buf_ready_efd = -1; }
    if (ctx->fence_fd >= 0)        { close(ctx->fence_fd);        ctx->fence_fd = -1; }
    if (ctx->shm_ptr) { munmap((void *)ctx->shm_ptr, sizeof(uint32_t)); ctx->shm_ptr = NULL; }
    if (ctx->shm_fd >= 0)         { close(ctx->shm_fd);           ctx->shm_fd = -1; }

    /* buf_ready_efd stays an eventfd (consumer->producer pacing signal); fence_fd is
     * (re)created as a socketpair inside send_hello_fds(). */
    ctx->buf_ready_efd = eventfd(0, EFD_CLOEXEC);
    if (create_shm(ctx) < 0) {
        if (ctx->fallback_cb)
            ctx->fallback_cb(ctx->fallback_userdata);
        return;
    }
    send_hello_fds(ctx);

    if (ctx->fallback_cb)
        ctx->fallback_cb(ctx->fallback_userdata);
}

int connect_to_deamon(display_ctx **out, const char *socket_path)
{
    display_ctx *ctx = calloc(1, sizeof(*ctx));
    if (!ctx)
        return -1;

    ctx->ctrl_fd = -1;
    ctx->data_fd = -1;
    ctx->buf_ready_efd = -1;
    ctx->fence_fd = -1;
    ctx->shm_fd = -1;
    ctx->shm_ptr = NULL;
    ctx->fallback = true;

    ctx->ctrl_fd = connect_unix(socket_path);
    if (ctx->ctrl_fd < 0)
        goto fail;

    /* buf_ready_efd is the consumer->producer pacing eventfd; fence_fd is created as a
     * socketpair inside send_hello_fds(). */
    ctx->buf_ready_efd = eventfd(0, EFD_CLOEXEC);
    if (ctx->buf_ready_efd < 0)
        goto fail;

    if (create_shm(ctx) < 0)
        goto fail;

    if (send_hello_fds(ctx) < 0)
        goto fail;

    *out = ctx;
    return 0;

fail:
    if (ctx->shm_ptr) munmap((void *)ctx->shm_ptr, sizeof(uint32_t));
    if (ctx->shm_fd >= 0)         close(ctx->shm_fd);
    if (ctx->ctrl_fd >= 0)         close(ctx->ctrl_fd);
    if (ctx->data_fd >= 0)         close(ctx->data_fd);
    if (ctx->buf_ready_efd >= 0)   close(ctx->buf_ready_efd);
    if (ctx->fence_fd >= 0)        close(ctx->fence_fd);
    free(ctx);
    return -1;
}

void disconnect(display_ctx *ctx)
{
    if (!ctx)
        return;
    if (ctx->shm_ptr) munmap((void *)ctx->shm_ptr, sizeof(uint32_t));
    if (ctx->shm_fd >= 0)         close(ctx->shm_fd);
    if (ctx->ctrl_fd >= 0)         close(ctx->ctrl_fd);
    if (ctx->data_fd >= 0)         close(ctx->data_fd);
    if (ctx->buf_ready_efd >= 0)   close(ctx->buf_ready_efd);
    if (ctx->fence_fd >= 0)        close(ctx->fence_fd);
    free(ctx);
}

int set_screen_info(display_ctx *ctx, uint32_t width, uint32_t height, uint32_t format, uint32_t refresh)
{
    ctx->screen_w = width;
    ctx->screen_h = height;
    ctx->pixel_format = format;

    struct ctrl_msg hdr = { .type = CTRL_MSG_SCREEN_INFO, .size = sizeof(struct screen_info) };
    struct screen_info si = { .width = width, .height = height, .format = format, .refresh = refresh };
    uint8_t msg[sizeof(struct ctrl_msg) + sizeof(struct screen_info)];
    memcpy(msg, &hdr, sizeof(hdr));
    memcpy(msg + sizeof(hdr), &si, sizeof(si));
    return send_all(ctx->ctrl_fd, msg, sizeof(msg));
}

int push_dmabufs(display_ctx *ctx, const int *fds, const struct buf_info *infos, int count)
{
    memcpy(ctx->stored_fds, fds, count * sizeof(int));
    memcpy(ctx->stored_infos, infos, count * sizeof(struct buf_info));
    ctx->stored_count = count;

    if (ctx->fallback)
        return 0;

    int ret = push_dmabufs_internal(ctx);
    enter_fallback(ctx);
    return ret;
}

int select_dmabuf(display_ctx *ctx, int idx)
{
    if (ctx->fallback) {
        try_exit_fallback(ctx);
        if (ctx->fallback)
            return 0;
    }

    if (idx < 0 || idx >= ctx->stored_count)
        return -1;

    *ctx->shm_ptr = (uint32_t)idx;
    eventfd_t val = 1;
    eventfd_write(ctx->buf_ready_efd, val);
    ctx->buffer_pending = true;
    return 0;
}

/* Wait for the producer to finish the frame, then return its render-done fence so
 * the caller can hand it to ANativeWindow_queueBuffer (SurfaceFlinger waits on it
 * GPU-side before scanout). The producer sends exactly one message per frame on the
 * dedicated fence channel; the message itself is the "frame rendered" signal (no
 * separate eventfd, no cross-channel ordering) and the optional fence rides as
 * SCM_RIGHTS ancillary data. Returns the fence fd (caller owns it), or -1 if none /
 * on error. */
int refresh_done(display_ctx *ctx)
{
    if (!ctx->buffer_pending)
        return -1;

    /* Block (with a 5s safety timeout) on the fence channel: the arrival of the
     * producer's per-frame message is the render-done signal. Timeout / no POLLIN
     * (producer stalled or gone) -> fall back so the render thread never hangs. */
    struct pollfd pfd = { .fd = ctx->fence_fd, .events = POLLIN };
    int ret = poll(&pfd, 1, 5000);
    if (ret <= 0 || !(pfd.revents & POLLIN)) {
        enter_fallback(ctx);
        return -1;
    }
    ctx->buffer_pending = false;

    int rfence = -1;
    char b;
    struct iovec iov = { .iov_base = &b, .iov_len = 1 };
    union {
        char buf[CMSG_SPACE(sizeof(int))];
        struct cmsghdr align;
    } cmsg;
    struct msghdr msg = {
        .msg_iov = &iov,
        .msg_iovlen = 1,
        .msg_control = cmsg.buf,
        .msg_controllen = sizeof(cmsg.buf),
    };
    /* Non-blocking even though poll reported POLLIN: if a concurrent enter_fallback
     * (from a JNI input thread) swapped fence_fd between the poll and this recvmsg,
     * we get EAGAIN (n < 0) instead of reading a stale/foreign socket. A clean EOF
     * (n == 0) means the producer closed the channel -> fall back. No fence in the
     * message => queue with -1 ("ready now"). */
    ssize_t n = recvmsg(ctx->fence_fd, &msg, MSG_DONTWAIT);
    if (n == 0) {
        enter_fallback(ctx);
        return -1;
    }
    if (n > 0) {
        struct cmsghdr *c = CMSG_FIRSTHDR(&msg);
        if (c && c->cmsg_type == SCM_RIGHTS)
            memcpy(&rfence, CMSG_DATA(c), sizeof(int));
    }
    return rfence;
}

int push_input_event(display_ctx *ctx, const struct InputEvent *event)
{
    if (ctx->fallback)
        return 0;

    struct data_msg hdr = { .type = DATA_MSG_INPUT_EVENT, .size = sizeof(struct InputEvent) };
    uint8_t msg[sizeof(struct data_msg) + sizeof(struct InputEvent)];
    memcpy(msg, &hdr, sizeof(hdr));
    memcpy(msg + sizeof(hdr), event, sizeof(*event));

    if (send_all(ctx->data_fd, msg, sizeof(msg)) < 0) {
        enter_fallback(ctx);
        return -1;
    }
    return 0;
}
int push_input_event_with_length(display_ctx *ctx, const struct InputEvent *event, void* payload, size_t size)
{
    if (ctx->fallback)
        return 0;

    struct data_msg hdr = { .type = DATA_MSG_INPUT_EVENT, .size = sizeof(struct InputEvent) };
    uint8_t *msg = (uint8_t *)malloc(sizeof(struct data_msg) + sizeof(struct InputEvent) + size);
    memcpy(msg, &hdr, sizeof(hdr));
    memcpy(msg + sizeof(hdr), event, sizeof(*event));
    memcpy(msg + sizeof(hdr) + sizeof(struct InputEvent), payload, size);

    if (send_all(ctx->data_fd, msg, sizeof(struct data_msg) + sizeof(struct InputEvent) + size) < 0) {
        free(msg);
        enter_fallback(ctx);
        return -1;
    }
    free(msg);
    return 0;
}
int poll_output_event(display_ctx *ctx, struct OutputEvent *event, int timeout_ms)
{
    if (ctx->fallback)
        return 0;

    struct pollfd pfd = { .fd = ctx->data_fd, .events = POLLIN };
    int ret = poll(&pfd, 1, timeout_ms);
    if (ret <= 0)
        return 0;

    if (pfd.revents & (POLLHUP | POLLERR)) {
        enter_fallback(ctx);
        return -1;
    }

    uint8_t msg_buf[sizeof(struct data_msg) + sizeof(struct OutputEvent)];
    ssize_t n = recv(ctx->data_fd, msg_buf, sizeof(msg_buf), MSG_PEEK);
    if (n < (ssize_t)sizeof(struct data_msg))
        return 0;

    struct data_msg hdr;
    memcpy(&hdr, msg_buf, sizeof(hdr));
    if (hdr.type != DATA_MSG_OUTPUT_EVENT)
        return 0;

    if (recv_all(ctx->data_fd, msg_buf, sizeof(struct data_msg) + sizeof(struct OutputEvent)) < 0)
        return -1;

    memcpy(event, msg_buf + sizeof(struct data_msg), sizeof(*event));
    return 1;
}
int poll_output_event_extend_data(display_ctx *ctx, void* payload, size_t size, int timeout_ms)
{
    if (ctx->fallback)
        return 0;

    struct pollfd pfd = { .fd = ctx->data_fd, .events = POLLIN };
    int ret = poll(&pfd, 1, timeout_ms);
    if (ret <= 0)
        return 0;

    if (pfd.revents & (POLLHUP | POLLERR)) {
        enter_fallback(ctx);
        return -1;
    }
    if (recv_all(ctx->data_fd, payload, size) < 0)
        return -1;
    return 1;
}
int set_fallback_callback(display_ctx *ctx, void (*on_fallback)(void *), void *userdata)
{
    ctx->fallback_cb = on_fallback;
    ctx->fallback_userdata = userdata;
    return 0;
}

int set_exit_fallback_callback(display_ctx *ctx, void (*on_exit_fallback)(void *), void *userdata)
{
    ctx->exit_fallback_cb = on_exit_fallback;
    ctx->exit_fallback_userdata = userdata;
    return 0;
}
int get_data_fd(display_ctx *ctx)
{
    return ctx->data_fd;
}
//用于处理未处理的变长payload事件
void handle_unhandled_event(display_ctx *ctx, const struct OutputEvent *event)
{
    switch (event->type)
    {
    case OUTPUT_TYPE_CLIPBOARD:
        //客户端发送了一个剪贴板事件，后续会有变长数据跟随，但是库调用者没有处理这个事件，所以我们需要把后续的变长数据读掉，避免阻塞
        if (event->clipboard.size > 0) {
            void* payload = malloc(event->clipboard.size);
            if (payload) {
                poll_output_event_extend_data(ctx, payload, event->clipboard.size, 1000);
                free(payload);
            }
        }
        break;
    default:
        break;
    }
}