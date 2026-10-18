/*
 * Authored by Alex Hultman, 2018-2019.
 * Intellectual property of third-party.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#ifdef LIBUS_USE_IO_URING

#include "libusockets.h"
#include "internal/internal.h"
#include "internal.h"
#include <stdlib.h>
#include <string.h>

static int us_internal_socket_queue_connect(struct us_socket_t *s, LIBUS_SOCKET_DESCRIPTOR fd) {
    if (!s || !s->context || !s->context->loop || fd < 0) {
        return 0;
    }

    struct io_uring_sqe *sqe = us_internal_get_sqe(s->context->loop);
    if (!sqe) {
        return 0;
    }

    io_uring_prep_poll_add(sqe, fd, POLLOUT | POLLERR | POLLHUP);
    io_uring_sqe_set_data(sqe, (char *) s + SOCKET_CONNECT);
    s->connect_pending = 1;
    return 1;
}

/* Shared with SSL */

unsigned short us_socket_context_timestamp(int ssl, struct us_socket_context_t *context) {
    (void) ssl;
    return context ? context->timestamp : 0;
}

void us_listen_socket_close(int ssl, struct us_listen_socket_t *ls) {
    (void) ssl;
    if (!ls) {
        return;
    }
    if (ls->s.closed) {
        return;
    }

    struct us_socket_context_t *context = ls->s.context;
    struct us_loop_t *loop = context ? context->loop : 0;
    if (context) {
        us_internal_socket_context_unlink_listen_socket(context, ls);
    }
    if (ls->s.fd >= 0) {
        bsd_close_socket(ls->s.fd);
        ls->s.fd = -1;
    }
    ls->s.closed = 1;
    ls->s.prev = context ? (struct us_socket_t *) context : 0;
    ls->s.context = 0;

    if (loop && !ls->queued_for_free) {
        ls->next_closed = loop->closed_listen_head;
        loop->closed_listen_head = ls;
        ls->queued_for_free = 1;
    } else if (!loop && !ls->accept_pending) {
        free(ls);
    }
}

void us_socket_context_close(int ssl, struct us_socket_context_t *context) {
    (void) ssl;
    if (!context) {
        return;
    }

    struct us_listen_socket_t *ls = context->head_listen_sockets;
    while (ls) {
        struct us_listen_socket_t *next_ls = (struct us_listen_socket_t *) ls->s.next;
        us_listen_socket_close(ssl, ls);
        ls = next_ls;
    }

    struct us_socket_t *s = context->head_sockets;
    while (s) {
        struct us_socket_t *next_s = s->next;
        us_socket_close(ssl, s, 0, 0);
        s = next_s;
    }
}

void us_internal_socket_context_unlink_listen_socket(struct us_socket_context_t *context, struct us_listen_socket_t *ls) {
    if (!context || !ls) {
        return;
    }

    if (ls == (struct us_listen_socket_t *) context->iterator) {
        context->iterator = ls->s.next;
    }

    if (ls == context->head_listen_sockets) {
        context->head_listen_sockets = (struct us_listen_socket_t *) ls->s.next;
    }
    if (ls->s.prev) {
        ls->s.prev->next = ls->s.next;
    }
    if (ls->s.next) {
        ls->s.next->prev = ls->s.prev;
    }
    ls->s.prev = 0;
    ls->s.next = 0;
}

void us_internal_socket_context_unlink_socket(struct us_socket_context_t *context, struct us_socket_t *s) {
    if (!context || !s) {
        return;
    }

    if (s == context->iterator) {
        context->iterator = s->next;
    }

    if (s == context->head_sockets) {
        context->head_sockets = s->next;
    }
    if (s->prev) {
        s->prev->next = s->next;
    }
    if (s->next) {
        s->next->prev = s->prev;
    }
    s->prev = 0;
    s->next = 0;
}

struct us_socket_t *us_socket_context_adopt_socket(int ssl, struct us_socket_context_t *context, struct us_socket_t *s, int ext_size) {
    (void) ssl;
    (void) ext_size;
    if (!context || !s) {
        return 0;
    }
    us_internal_socket_context_link_socket(context, s);
    return s;
}

void us_internal_socket_context_link_listen_socket(struct us_socket_context_t *context, struct us_listen_socket_t *ls) {
    if (!context || !ls) {
        return;
    }
    ls->s.context = context;
    ls->s.prev = 0;
    ls->s.next = (struct us_socket_t *) context->head_listen_sockets;
    if (context->head_listen_sockets) {
        context->head_listen_sockets->s.prev = &ls->s;
    }
    context->head_listen_sockets = ls;
}

void us_internal_socket_context_link_socket(struct us_socket_context_t *context, struct us_socket_t *s) {
    if (!context || !s) {
        return;
    }
    s->context = context;
    s->next = context->head_sockets;
    s->prev = 0;
    if (context->head_sockets) {
        context->head_sockets->prev = s;
    }
    context->head_sockets = s;
}

struct us_loop_t *us_socket_context_loop(int ssl, struct us_socket_context_t *context) {
    (void) ssl;
    return context ? context->loop : 0;
}

/* Not shared with SSL */

void *us_socket_context_find_server_name_userdata(int ssl, struct us_socket_context_t *context, const char *hostname_pattern) {
    (void) ssl;
    (void) context;
    (void) hostname_pattern;
    return 0;
}

void *us_socket_server_name_userdata(int ssl, struct us_socket_t *s) {
    (void) ssl;
    (void) s;
    return 0;
}

void us_socket_context_add_server_name(int ssl, struct us_socket_context_t *context, const char *hostname_pattern, struct us_socket_context_options_t options, void *user) {
    (void) ssl;
    (void) context;
    (void) hostname_pattern;
    (void) options;
    (void) user;
}

void us_socket_context_remove_server_name(int ssl, struct us_socket_context_t *context, const char *hostname_pattern) {
    (void) ssl;
    (void) context;
    (void) hostname_pattern;
}

void us_socket_context_on_server_name(int ssl, struct us_socket_context_t *context, void (*cb)(struct us_socket_context_t *, const char *hostname)) {
    (void) ssl;
    (void) context;
    (void) cb;
}

void *us_socket_context_get_native_handle(int ssl, struct us_socket_context_t *context) {
    (void) ssl;
    (void) context;
    return 0;
}

struct us_socket_context_t *us_create_socket_context(int ssl, struct us_loop_t *loop, int context_ext_size, struct us_socket_context_options_t options) {
    (void) ssl;
    (void) options;

    if (!loop) {
        return 0;
    }

    struct us_socket_context_t *context = malloc((size_t) context_ext_size + sizeof(struct us_socket_context_t));
    if (!context) {
        return 0;
    }
    memset(context, 0, (size_t) context_ext_size + sizeof(struct us_socket_context_t));

    context->loop = loop;
    context->head_sockets = 0;
    context->head_listen_sockets = 0;
    context->iterator = 0;
    context->prev = 0;
    context->next = 0;
    context->timestamp = 0;
    context->long_timestamp = 0;
    context->global_tick = 0;
    context->on_pre_open = 0;
    context->on_open = 0;
    context->on_data = 0;
    context->on_writable = 0;
    context->on_close = 0;
    context->on_socket_timeout = 0;
    context->on_socket_long_timeout = 0;
    context->on_end = 0;
    context->on_connect_error = 0;

    us_internal_loop_link(loop, context);
    return context;
}

void us_socket_context_free(int ssl, struct us_socket_context_t *context) {
    (void) ssl;
    if (!context) {
        return;
    }
    us_internal_loop_unlink(context->loop, context);
    free(context);
}

struct us_listen_socket_t *us_socket_context_listen(int ssl, struct us_socket_context_t *context, const char *host, int port, int options, int socket_ext_size) {
    (void) ssl;
    if (!context || !context->loop) {
        return 0;
    }

    LIBUS_SOCKET_DESCRIPTOR listen_fd = bsd_create_listen_socket(host, port, options);
    if (listen_fd == LIBUS_SOCKET_ERROR) {
        return 0;
    }

    struct us_listen_socket_t *listen_s = calloc(1, sizeof(struct us_listen_socket_t));
    if (!listen_s) {
        bsd_close_socket(listen_fd);
        return 0;
    }
    listen_s->s.context = context;
    listen_s->s.timeout = 255;
    listen_s->s.long_timeout = 255;
    listen_s->s.fd = listen_fd;
    listen_s->s.dd = -1;
    listen_s->socket_ext_size = socket_ext_size;
    us_internal_socket_context_link_listen_socket(context, listen_s);

    if (!us_internal_arm_listen_socket(listen_s)) {
        us_listen_socket_close(ssl, listen_s);
        return 0;
    }

    return listen_s;
}

struct us_listen_socket_t *us_socket_context_listen_unix(int ssl, struct us_socket_context_t *context, const char *path, int options, int socket_ext_size) {
    (void) ssl;
    if (!context || !context->loop) {
        return 0;
    }

    LIBUS_SOCKET_DESCRIPTOR listen_fd = bsd_create_listen_socket_unix(path, options);
    if (listen_fd == LIBUS_SOCKET_ERROR) {
        return 0;
    }

    struct us_listen_socket_t *listen_s = calloc(1, sizeof(struct us_listen_socket_t));
    if (!listen_s) {
        bsd_close_socket(listen_fd);
        return 0;
    }
    listen_s->s.context = context;
    listen_s->s.timeout = 255;
    listen_s->s.long_timeout = 255;
    listen_s->s.fd = listen_fd;
    listen_s->s.dd = -1;
    listen_s->socket_ext_size = socket_ext_size;
    us_internal_socket_context_link_listen_socket(context, listen_s);

    if (!us_internal_arm_listen_socket(listen_s)) {
        us_listen_socket_close(ssl, listen_s);
        return 0;
    }

    return listen_s;
}

struct us_socket_t *us_socket_context_connect(int ssl, struct us_socket_context_t *context, const char *host, int port, const char *source_host, int options, int socket_ext_size) {
    (void) ssl;
    if (!context || !context->loop) {
        return 0;
    }

    LIBUS_SOCKET_DESCRIPTOR fd = bsd_create_connect_socket(host, port, source_host, options);
    if (fd == LIBUS_SOCKET_ERROR) {
        return 0;
    }
    bsd_socket_nodelay(fd, 1);

    struct us_socket_t *s = calloc(1, sizeof(struct us_socket_t) + (size_t) socket_ext_size);
    if (!s) {
        bsd_close_socket(fd);
        return 0;
    }

    int direct_slot = us_internal_allocate_registered_fd_slot(context->loop);
    if (direct_slot < 0) {
        bsd_close_socket(fd);
        free(s);
        return 0;
    }

    if (io_uring_register_files_update(&context->loop->ring, (unsigned) direct_slot, &fd, 1) < 0) {
        bsd_close_socket(fd);
        us_internal_release_registered_fd_slot(context->loop, direct_slot);
        free(s);
        return 0;
    }

    s->context = context;
    s->timeout = 255;
    s->long_timeout = 255;
    s->fd = fd;
    s->dd = direct_slot;
    us_internal_socket_context_link_socket(context, s);

    if (!us_internal_socket_queue_connect(s, fd)) {
        us_socket_close_connecting(ssl, s);
        return 0;
    }
    return s;
}

struct us_socket_t *us_socket_context_connect_unix(int ssl, struct us_socket_context_t *context, const char *server_path, int options, int socket_ext_size) {
    (void) ssl;
    if (!context || !context->loop) {
        return 0;
    }

    LIBUS_SOCKET_DESCRIPTOR fd = bsd_create_connect_socket_unix(server_path, options);
    if (fd == LIBUS_SOCKET_ERROR) {
        return 0;
    }

    struct us_socket_t *s = calloc(1, sizeof(struct us_socket_t) + (size_t) socket_ext_size);
    if (!s) {
        bsd_close_socket(fd);
        return 0;
    }

    int direct_slot = us_internal_allocate_registered_fd_slot(context->loop);
    if (direct_slot < 0) {
        bsd_close_socket(fd);
        free(s);
        return 0;
    }

    if (io_uring_register_files_update(&context->loop->ring, (unsigned) direct_slot, &fd, 1) < 0) {
        bsd_close_socket(fd);
        us_internal_release_registered_fd_slot(context->loop, direct_slot);
        free(s);
        return 0;
    }

    s->context = context;
    s->timeout = 255;
    s->long_timeout = 255;
    s->fd = fd;
    s->dd = direct_slot;
    us_internal_socket_context_link_socket(context, s);

    if (!us_internal_socket_queue_connect(s, fd)) {
        us_socket_close_connecting(ssl, s);
        return 0;
    }
    return s;
}

struct us_socket_context_t *us_create_child_socket_context(int ssl, struct us_socket_context_t *context, int context_ext_size) {
    struct us_socket_context_options_t opt = {0};
    return us_create_socket_context(ssl, context ? context->loop : 0, context_ext_size, opt);
}

struct us_socket_t *us_adopt_accepted_socket(int ssl, struct us_socket_context_t *context, LIBUS_SOCKET_DESCRIPTOR accepted_fd,
    unsigned int socket_ext_size, char *addr_ip, int addr_ip_length) {
    (void) ssl;
    if (!context || !context->loop) {
        return 0;
    }

    struct us_socket_t *s = calloc(1, sizeof(struct us_socket_t) + (size_t) socket_ext_size);
    if (!s) {
        bsd_close_socket(accepted_fd);
        return 0;
    }

    int direct_slot = us_internal_allocate_registered_fd_slot(context->loop);
    if (direct_slot < 0) {
        bsd_close_socket(accepted_fd);
        free(s);
        return 0;
    }

    if (io_uring_register_files_update(&context->loop->ring, (unsigned) direct_slot, &accepted_fd, 1) < 0) {
        bsd_close_socket(accepted_fd);
        us_internal_release_registered_fd_slot(context->loop, direct_slot);
        free(s);
        return 0;
    }

    bsd_socket_nodelay(accepted_fd, 1);

    s->context = context;
    s->timeout = 255;
    s->long_timeout = 255;
    s->fd = accepted_fd;
    s->dd = direct_slot;
    us_internal_socket_context_link_socket(context, s);
    us_internal_arm_socket_read(context->loop, s);

    if (context->on_open) {
        context->on_open(s, 0, addr_ip, addr_ip_length);
    }
    return s;
}

void us_socket_context_on_pre_open(int ssl, struct us_socket_context_t *context, LIBUS_SOCKET_DESCRIPTOR (*on_pre_open)(struct us_socket_context_t *context, LIBUS_SOCKET_DESCRIPTOR fd, char *ip, int ip_length)) {
    (void) ssl;
    if (context) {
        context->on_pre_open = on_pre_open;
    }
}

void us_socket_context_on_open(int ssl, struct us_socket_context_t *context, struct us_socket_t *(*on_open)(struct us_socket_t *s, int is_client, char *ip, int ip_length)) {
    (void) ssl;
    if (context) {
        context->on_open = on_open;
    }
}

void us_socket_context_on_close(int ssl, struct us_socket_context_t *context, struct us_socket_t *(*on_close)(struct us_socket_t *s, int code, void *reason)) {
    (void) ssl;
    if (context) {
        context->on_close = on_close;
    }
}

void us_socket_context_on_data(int ssl, struct us_socket_context_t *context, struct us_socket_t *(*on_data)(struct us_socket_t *s, char *data, int length)) {
    (void) ssl;
    if (context) {
        context->on_data = on_data;
    }
}

void us_socket_context_on_writable(int ssl, struct us_socket_context_t *context, struct us_socket_t *(*on_writable)(struct us_socket_t *s)) {
    (void) ssl;
    if (context) {
        context->on_writable = on_writable;
    }
}

void us_socket_context_on_long_timeout(int ssl, struct us_socket_context_t *context, struct us_socket_t *(*on_long_timeout)(struct us_socket_t *)) {
    (void) ssl;
    if (context) {
        context->on_socket_long_timeout = on_long_timeout;
    }
}

void us_socket_context_on_timeout(int ssl, struct us_socket_context_t *context, struct us_socket_t *(*on_timeout)(struct us_socket_t *)) {
    (void) ssl;
    if (context) {
        context->on_socket_timeout = on_timeout;
    }
}

void us_socket_context_on_end(int ssl, struct us_socket_context_t *context, struct us_socket_t *(*on_end)(struct us_socket_t *)) {
    (void) ssl;
    if (context) {
        context->on_end = on_end;
    }
}

void us_socket_context_on_connect_error(int ssl, struct us_socket_context_t *context, struct us_socket_t *(*on_connect_error)(struct us_socket_t *s, int code)) {
    (void) ssl;
    if (context) {
        context->on_connect_error = on_connect_error;
    }
}

void *us_socket_context_ext(int ssl, struct us_socket_context_t *context) {
    (void) ssl;
    return context ? (context + 1) : 0;
}

#endif
