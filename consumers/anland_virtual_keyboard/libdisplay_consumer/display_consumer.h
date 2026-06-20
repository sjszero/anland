#ifndef DISPLAY_CONSUMER_H
#define DISPLAY_CONSUMER_H

#include <stdint.h>
#include "../common/protocol.h"

typedef struct display_ctx display_ctx;

int  connect_to_deamon(display_ctx **ctx, const char *socket_path);
void disconnect(display_ctx *ctx);
int  set_screen_info(display_ctx *ctx, uint32_t width, uint32_t height, uint32_t format, uint32_t refresh);
int  push_dmabufs(display_ctx *ctx, const int *fds, const struct buf_info *infos, int count);
int  select_dmabuf(display_ctx *ctx, int idx);
int  refresh_done(display_ctx *ctx);
int  push_input_event(display_ctx *ctx, const struct InputEvent *event);
int  set_fallback_callback(display_ctx *ctx, void (*on_fallback)(void *), void *userdata);

#endif
