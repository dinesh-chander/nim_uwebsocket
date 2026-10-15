/*
 * Authored by Alex Hultman, 2018-2021.
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
#include <stdint.h>
#include <unistd.h>
#include <sys/timerfd.h>
#include <sys/eventfd.h>

struct io_uring_sqe *us_internal_get_sqe(struct us_loop_t *loop) {
    if (!loop) {
        return 0;
    }
    struct io_uring_sqe *sqe = io_uring_get_sqe(&loop->ring);
    if (!sqe) {
        io_uring_submit(&loop->ring);
        sqe = io_uring_get_sqe(&loop->ring);
    }
    return sqe;
}

static void us_internal_recycle_recv_buffer(struct us_loop_t *loop, int bid) {
    if (!loop || bid < 0 || bid >= BUFFERS_COUNT) {
        return;
    }
    io_uring_buf_ring_add(loop->buf_ring, loop->bufs[bid], MAX_MESSAGE_LEN, (unsigned short) bid, io_uring_buf_ring_mask(BUFFERS_COUNT), 0);
    io_uring_buf_ring_advance(loop->buf_ring, 1);
}

int us_internal_allocate_registered_fd_slot(struct us_loop_t *loop) {
    if (!loop) {
        return -1;
    }
    int start = loop->next_registered_fd_slot;
    if (start < 0 || start >= REGISTERED_FILES_COUNT) {
        start = 0;
    }
    for (int i = 0; i < REGISTERED_FILES_COUNT; i++) {
        int slot = (start + i) % REGISTERED_FILES_COUNT;
        if (!loop->registered_fd_slot_used[slot] && !loop->registered_fd_slot_closing[slot]) {
            loop->registered_fd_slot_used[slot] = 1;
            loop->next_registered_fd_slot = (slot + 1) % REGISTERED_FILES_COUNT;
            return slot;
        }
    }
    return -1;
}

void us_internal_mark_registered_fd_slot(struct us_loop_t *loop, int slot) {
    if (!loop || slot < 0 || slot >= REGISTERED_FILES_COUNT) {
        return;
    }
    loop->registered_fd_slot_used[slot] = 1;
    loop->registered_fd_slot_closing[slot] = 0;
    loop->registered_fd_slot_pending_close[slot] = 0;
    if (loop->next_registered_fd_slot == slot) {
        loop->next_registered_fd_slot = (slot + 1) % REGISTERED_FILES_COUNT;
    }
}

void us_internal_release_registered_fd_slot(struct us_loop_t *loop, int slot) {
    if (!loop || slot < 0 || slot >= REGISTERED_FILES_COUNT) {
        return;
    }
    loop->registered_fd_slot_used[slot] = 0;
    loop->registered_fd_slot_closing[slot] = 0;
    loop->registered_fd_slot_pending_close[slot] = 0;
}

static int us_internal_submit_close_direct(struct us_loop_t *loop, int slot) {
    if (!loop || slot < 0 || slot >= REGISTERED_FILES_COUNT) {
        return 0;
    }

    struct io_uring_sqe *sqe = us_internal_get_sqe(loop);
    if (!sqe) {
        return 0;
    }

    loop->registered_fd_slot_closing[slot] = 1;
    loop->registered_fd_slot_pending_close[slot] = 0;
    io_uring_prep_close_direct(sqe, slot);
    io_uring_sqe_set_data64(sqe, (((uint64_t) slot) << 3) | (uint64_t) SOCKET_CLOSE);
    return 1;
}

void us_internal_queue_close_direct(struct us_loop_t *loop, int slot) {
    if (!loop || slot < 0 || slot >= REGISTERED_FILES_COUNT) {
        return;
    }

    if (!loop->registered_fd_slot_used[slot]) {
        return;
    }

    if (loop->registered_fd_slot_closing[slot] && !loop->registered_fd_slot_pending_close[slot]) {
        return;
    }

    if (!us_internal_submit_close_direct(loop, slot)) {
        loop->registered_fd_slot_closing[slot] = 1;
        loop->registered_fd_slot_pending_close[slot] = 1;
    }
}

static void us_internal_flush_pending_close_direct(struct us_loop_t *loop) {
    if (!loop) {
        return;
    }

    for (int slot = 0; slot < REGISTERED_FILES_COUNT; slot++) {
        if (loop->registered_fd_slot_pending_close[slot]) {
            if (!us_internal_submit_close_direct(loop, slot)) {
                return;
            }
        }
    }
}

static void us_internal_complete_close_direct(struct us_loop_t *loop, int slot) {
    us_internal_release_registered_fd_slot(loop, slot);
}

static void us_internal_free_timer_immediate(struct us_timer_t *timer) {
    if (!timer) {
        return;
    }
    if (timer->fd >= 0) {
        close(timer->fd);
        timer->fd = -1;
    }
    free(timer);
}

static void us_internal_rearm_timer_fd(struct us_loop_t *loop, struct us_timer_t *t) {
    if (!loop || !t || t->fd < 0 || t->closed || t->pending) {
        return;
    }
    struct io_uring_sqe *sqe = us_internal_get_sqe(loop);
    if (!sqe) {
        return;
    }
    io_uring_prep_read(sqe, t->fd, &t->buf, 8, 0);
    io_uring_sqe_set_data(sqe, (char *) t + LOOP_TIMER);
    t->pending = 1;
}

static void us_internal_rearm_async_wakeup(struct us_loop_t *loop) {
    if (!loop || loop->async_wakeup_fd < 0) {
        return;
    }
    struct io_uring_sqe *sqe = us_internal_get_sqe(loop);
    if (!sqe) {
        return;
    }
    io_uring_prep_read(sqe, loop->async_wakeup_fd, &loop->async_wakeup_buf, 8, 0);
    io_uring_sqe_set_data(sqe, (char *) loop + ASYNC_WAKEUP);
}

void us_internal_arm_socket_read(struct us_loop_t *loop, struct us_socket_t *s) {
    if (!loop || !s || s->closed || s->read_pending || s->dd < 0) {
        return;
    }
    struct io_uring_sqe *sqe = us_internal_get_sqe(loop);
    if (!sqe) {
        return;
    }
    io_uring_prep_recv_multishot(sqe, s->dd, 0, 0, 0);
    io_uring_sqe_set_flags(sqe, IOSQE_BUFFER_SELECT | IOSQE_FIXED_FILE);
    sqe->buf_group = loop->buf_group_id;
    io_uring_sqe_set_data(sqe, (char *) s + SOCKET_READ);
    s->read_pending = 1;
}

int us_internal_arm_listen_socket(struct us_listen_socket_t *listen_s) {
    if (!listen_s || listen_s->s.closed || !listen_s->s.context || !listen_s->s.context->loop || listen_s->s.fd < 0) {
        return 0;
    }

    struct io_uring_sqe *sqe = us_internal_get_sqe(listen_s->s.context->loop);
    if (!sqe) {
        listen_s->accept_pending = 0;
        return 0;
    }

    io_uring_prep_multishot_accept(sqe, listen_s->s.fd, 0, 0, SOCK_NONBLOCK | SOCK_CLOEXEC);
    io_uring_sqe_set_data(sqe, (char *) listen_s + LISTEN_SOCKET_ACCEPT);
    listen_s->accept_pending = 1;
    return 1;
}

static void us_internal_arm_inactive_listen_sockets(struct us_loop_t *loop) {
    if (!loop) {
        return;
    }

    for (struct us_socket_context_t *context = loop->head; context; context = context->next) {
        for (struct us_listen_socket_t *listen_s = context->head_listen_sockets; listen_s; listen_s = (struct us_listen_socket_t *) listen_s->s.next) {
            if (!listen_s->accept_pending) {
                if (!us_internal_arm_listen_socket(listen_s)) {
                    return;
                }
            }
        }
    }
}

void us_internal_timer_sweep(struct us_loop_t *loop) {
    struct us_loop_t *loop_data = loop;
    for (loop_data->iterator = loop_data->head; loop_data->iterator; loop_data->iterator = loop_data->iterator->next) {
        struct us_socket_context_t *context = loop_data->iterator;
        context->global_tick++;
        unsigned char short_ticks = context->timestamp = context->global_tick % 240;
        unsigned char long_ticks = context->long_timestamp = (context->global_tick / 15) % 240;

        struct us_socket_t *s = context->head_sockets;
        while (s) {
            while (1) {
                if (short_ticks == s->timeout || long_ticks == s->long_timeout) {
                    break;
                }
                if ((s = s->next) == 0) {
                    goto next_context;
                }
            }

            context->iterator = s;

            if (short_ticks == s->timeout) {
                s->timeout = 255;
                if (context->on_socket_timeout) {
                    context->on_socket_timeout(s);
                }
            }

            if (context->iterator == s && long_ticks == s->long_timeout) {
                s->long_timeout = 255;
                if (context->on_socket_long_timeout) {
                    context->on_socket_long_timeout(s);
                }
            }

            if (s == context->iterator) {
                s = s->next;
            } else {
                s = context->iterator;
            }
        }

next_context:
        context->iterator = 0;
    }
}

void us_loop_run(struct us_loop_t *loop) {
    if (!loop) {
        return;
    }

    if (loop->timer) {
        us_timer_set(loop->timer, 0, LIBUS_TIMEOUT_GRANULARITY * 1000, LIBUS_TIMEOUT_GRANULARITY * 1000);
    }

    us_internal_rearm_async_wakeup(loop);

    while (loop->num_polls > 0) {
        us_internal_loop_pre(loop);
        us_internal_flush_pending_close_direct(loop);
        us_internal_arm_inactive_listen_sockets(loop);
        loop->wakeup_async_pending = 0;

        if (io_uring_submit_and_wait(&loop->ring, 1) < 0) {
            us_internal_free_closed_sockets(loop);
            us_internal_loop_post(loop);
            continue;
        }

        struct io_uring_cqe *cqe;
        unsigned head;
        unsigned count = 0;

        io_uring_for_each_cqe(&loop->ring, head, cqe) {
            count++;

            uintptr_t cqe_data = (uintptr_t) io_uring_cqe_get_data(cqe);
            int pointer_tag = (int) (cqe_data & (uintptr_t) 0x7ull);
            void *object = (void *) (cqe_data & (uintptr_t) 0xFFFFFFFFFFFFFFF8ull);

            if (pointer_tag == LISTEN_SOCKET_ACCEPT) {
                struct us_listen_socket_t *listen_s = object;
                if (listen_s && !(cqe->flags & IORING_CQE_F_MORE)) {
                    listen_s->accept_pending = 0;
                }
                if (!listen_s || listen_s->s.closed || !listen_s->s.context || cqe->res < 0) {
                    if (cqe->res >= 0) {
                        bsd_close_socket(cqe->res);
                    }
                    continue;
                }

                LIBUS_SOCKET_DESCRIPTOR accepted_fd = cqe->res;
                struct us_socket_context_t *context = listen_s->s.context;

                struct bsd_addr_t addr;
                int has_remote_addr = bsd_remote_addr(accepted_fd, &addr) == 0;
                char *addr_ip = has_remote_addr ? bsd_addr_get_ip(&addr) : 0;
                int addr_ip_length = has_remote_addr ? bsd_addr_get_ip_length(&addr) : 0;

                if (context->on_pre_open != 0 && context->on_pre_open(context, accepted_fd, addr_ip, addr_ip_length) != accepted_fd) {
                    bsd_close_socket(accepted_fd);
                    continue;
                }

                us_adopt_accepted_socket(0, context, accepted_fd, listen_s->socket_ext_size, addr_ip, addr_ip_length);
            } else if (pointer_tag == SOCKET_CLOSE) {
                int slot = (int) (cqe_data >> 3);
                us_internal_complete_close_direct(loop, slot);
            } else if (pointer_tag == SOCKET_READ) {
                struct us_socket_t *s = object;
                if (!s || !s->context) {
                    continue;
                }

                int bid = (cqe->flags & IORING_CQE_F_BUFFER) ? (cqe->flags >> 16) : -1;
                int has_buffer = bid >= 0 && bid < BUFFERS_COUNT && cqe->res != -ENOBUFS;
                if (!(cqe->flags & IORING_CQE_F_MORE)) {
                    s->read_pending = 0;
                }

                if (s->closed || s->prev == (struct us_socket_t *) s->context) {
                    if (has_buffer) {
                        us_internal_recycle_recv_buffer(loop, bid);
                    }
                    continue;
                }

                if (cqe->res == -ENOBUFS) {
                    if (!(cqe->flags & IORING_CQE_F_MORE)) {
                        us_internal_arm_socket_read(loop, s);
                    }
                    continue;
                }

                if (cqe->res <= 0) {
                    if (has_buffer) {
                        us_internal_recycle_recv_buffer(loop, bid);
                    }
                    if (cqe->res == 0 && s->context->on_end) {
                        s = s->context->on_end(s);
                    }
                    if (s && s->context && s->prev != (struct us_socket_t *) s->context && s->context->on_close) {
                        s = s->context->on_close(s, 0, 0);
                    }
                    if (s && s->context && s->prev != (struct us_socket_t *) s->context) {
                        us_socket_close_connecting(0, s);
                    }
                    continue;
                }

                if (s->context->on_data && bid >= 0 && bid < BUFFERS_COUNT) {
                    s->write_drained_inline = 0;
                    s = s->context->on_data(s, loop->bufs[bid], cqe->res);
                }

                if (has_buffer) {
                    us_internal_recycle_recv_buffer(loop, bid);
                }

                if (!s || !s->context || s->prev == (struct us_socket_t *) s->context || s->dd < 0) {
                    continue;
                }

                if (!(cqe->flags & IORING_CQE_F_MORE)) {
                    us_internal_arm_socket_read(loop, s);
                }
            } else if (pointer_tag == SOCKET_WRITE) {
                struct us_socket_t *s = object;
                if (!s || !s->context) {
                    continue;
                }
                if (s->closed || s->prev == (struct us_socket_t *) s->context) {
                    s->write_pending = 0;
                    s->write_offset = 0;
                    s->write_length = 0;
                    s->write_data = 0;
                    us_internal_queue_closed_socket(loop, s);
                    continue;
                }
                if (cqe->res < 0) {
                    s->write_pending = 0;
                    s->write_offset = 0;
                    s->write_length = 0;
                    s->write_data = 0;
                    if (s->context->on_close) {
                        s->context->on_close(s, 0, 0);
                    }
                    us_socket_close_connecting(0, s);
                } else if (cqe->res > 0 && cqe->res < (s->write_length - s->write_offset)) {
                    s->write_offset += cqe->res;
                    struct io_uring_sqe *sqe = us_internal_get_sqe(loop);
                    if (!sqe) {
                        s->write_pending = 0;
                        s->write_offset = 0;
                        s->write_length = 0;
                        s->write_data = 0;
                        if (s->context->on_close) {
                            s->context->on_close(s, 0, 0);
                        }
                        us_socket_close_connecting(0, s);
                        continue;
                    }
                    io_uring_prep_send(sqe, s->dd, s->write_data + s->write_offset,
                                       (unsigned) (s->write_length - s->write_offset),
                                       s->write_msg_more ? MSG_MORE : 0);
                    io_uring_sqe_set_flags(sqe, IOSQE_FIXED_FILE);
                    io_uring_sqe_set_data(sqe, (char *) s + SOCKET_WRITE);
                    s->write_pending = 1;
                } else if (s->context->on_writable) {
                    s->write_pending = 0;
                    s->write_offset = 0;
                    s->write_length = 0;
                    s->write_data = 0;
                    if (s->close_pending) {
                        bsd_shutdown_socket(s->fd);
                    } else {
                        s->context->on_writable(s);
                    }
                } else {
                    s->write_pending = 0;
                    s->write_offset = 0;
                    s->write_length = 0;
                    s->write_data = 0;
                    if (s->close_pending) {
                        bsd_shutdown_socket(s->fd);
                    }
                }
            } else if (pointer_tag == SOCKET_CONNECT) {
                struct us_socket_t *s = object;
                if (!s || !s->context) {
                    continue;
                }
                if (s->closed || s->prev == (struct us_socket_t *) s->context) {
                    s->connect_pending = 0;
                    us_internal_queue_closed_socket(loop, s);
                    continue;
                }
                int connect_error = 0;
                socklen_t connect_error_len = sizeof(connect_error);
                if (cqe->res < 0) {
                    connect_error = -cqe->res;
                } else if (s->fd < 0 || getsockopt(s->fd, SOL_SOCKET, SO_ERROR, &connect_error, &connect_error_len) != 0) {
                    connect_error = errno ? errno : ECONNABORTED;
                }
                s->connect_pending = 0;
                if (connect_error != 0) {
                    if (s->context->on_connect_error) {
                        s->context->on_connect_error(s, -connect_error);
                    }
                    us_socket_close_connecting(0, s);
                } else {
                    if (s->fd >= 0) {
                        close(s->fd);
                        s->fd = -1;
                    }
                    us_internal_arm_socket_read(loop, s);
                    if (s->context->on_open) {
                        s->context->on_open(s, 1, 0, 0);
                    }
                }
            } else if (pointer_tag == ASYNC_WAKEUP) {
                if (loop->wakeup_cb) {
                    loop->wakeup_cb(loop);
                }
                us_internal_rearm_async_wakeup(loop);
            } else if (pointer_tag == LOOP_TIMER) {
                struct us_timer_t *t = object;
                if (!t) {
                    continue;
                }
                t->pending = 0;
                if (t->closed) {
                    continue;
                }
                if (t->cb) {
                    t->cb(t);
                } else {
                    us_internal_timer_sweep(loop);
                }
                us_internal_rearm_timer_fd(loop, t);
            }
        }

        io_uring_cq_advance(&loop->ring, count);
        us_internal_flush_pending_close_direct(loop);
        us_internal_free_closed_sockets(loop);
        us_internal_free_closed_listen_sockets(loop);
        us_internal_free_closed_timers(loop);
        us_internal_loop_post(loop);
    }
}

struct us_timer_t *us_create_timer(struct us_loop_t *loop, int fallthrough, unsigned int ext_size) {
    struct us_timer_t *timer = calloc(1, sizeof(struct us_timer_t) + ext_size);
    if (!timer) {
        return 0;
    }

    timer->loop = loop;
    timer->fd = timerfd_create(CLOCK_REALTIME, TFD_NONBLOCK | TFD_CLOEXEC);
    timer->cb = 0;
    timer->fallthrough = fallthrough ? 1 : 0;
    if (timer->fd == -1) {
        free(timer);
        return 0;
    }

    if (!fallthrough && loop) {
        loop->num_polls++;
    }

    return timer;
}

void us_timer_set(struct us_timer_t *t, void (*cb)(struct us_timer_t *t), int ms, int repeat_ms) {
    if (!t || t->fd < 0 || !t->loop) {
        return;
    }

    t->cb = cb;

    struct itimerspec timer_spec = {
        {repeat_ms / 1000, (long) (repeat_ms % 1000) * 1000000L},
        {ms / 1000, (long) (ms % 1000) * 1000000L}
    };
    timerfd_settime(t->fd, 0, &timer_spec, 0);
    us_internal_rearm_timer_fd(t->loop, t);
}

void *us_timer_ext(struct us_timer_t *timer) {
    return timer ? (timer + 1) : 0;
}

void us_timer_close(struct us_timer_t *timer) {
    if (!timer) {
        return;
    }
    if (timer->closed) {
        return;
    }
    timer->closed = 1;
    struct us_loop_t *loop = timer->loop;
    if (!timer->fallthrough && loop && loop->num_polls > 0) {
        loop->num_polls--;
    }
    if (timer->fd >= 0) {
        close(timer->fd);
        timer->fd = -1;
    }
    if (loop && !timer->queued_for_free) {
        timer->next_closed = loop->closed_timer_head;
        loop->closed_timer_head = timer;
        timer->queued_for_free = 1;
    } else if (!timer->pending) {
        free(timer);
    }
}

struct us_loop_t *us_timer_loop(struct us_timer_t *t) {
    return t ? t->loop : 0;
}

void us_loop_free(struct us_loop_t *loop) {
    if (!loop) {
        return;
    }
    loop->num_polls = 0;
    us_internal_loop_data_free(loop);
    free(loop);
}

void us_loop_stop(struct us_loop_t *loop) {
    if (!loop) {
        return;
    }
    loop->num_polls = 0;
    us_wakeup_loop(loop);
}

int us_internal_loop_data_init(struct us_loop_t *loop, void (*wakeup_cb)(struct us_loop_t *loop),
    void (*pre_cb)(struct us_loop_t *loop), void (*post_cb)(struct us_loop_t *loop)) {
    if (!loop) {
        return 0;
    }
    loop->wakeup_cb = wakeup_cb;
    loop->pre_cb = pre_cb;
    loop->post_cb = post_cb;
    return 1;
}

struct us_loop_t *us_create_loop(void *hint, void (*wakeup_cb)(struct us_loop_t *loop), void (*pre_cb)(struct us_loop_t *loop), void (*post_cb)(struct us_loop_t *loop), unsigned int ext_size) {
    (void) hint;
    struct us_loop_t *loop = calloc(1, sizeof(struct us_loop_t) + (size_t) ext_size);
    if (!loop) {
        return 0;
    }

    loop->head = 0;
    loop->iterator = 0;
    loop->closed_head = 0;
    loop->closed_listen_head = 0;
    loop->closed_timer_head = 0;
    loop->num_polls = 1;
    loop->iteration_nr = 0;
    loop->wakeup_async_pending = 0;
    loop->next_registered_fd_slot = 0;
    loop->async_wakeup_fd = -1;
    memset(loop->registered_fd_slot_used, 0, sizeof(loop->registered_fd_slot_used));
    memset(loop->registered_fd_slot_closing, 0, sizeof(loop->registered_fd_slot_closing));
    memset(loop->registered_fd_slot_pending_close, 0, sizeof(loop->registered_fd_slot_pending_close));
    loop->buf_group_id = 1337;
    loop->wakeup_cb = wakeup_cb;
    loop->pre_cb = pre_cb;
    loop->post_cb = post_cb;
    loop->bufs = calloc(BUFFERS_COUNT, MAX_MESSAGE_LEN);
    if (!loop->bufs) {
        free(loop);
        return 0;
    }

    loop->timer = us_create_timer(loop, 1, 0);
    if (!loop->timer) {
        free(loop->bufs);
        free(loop);
        return 0;
    }

    loop->async_wakeup_fd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
    if (loop->async_wakeup_fd == -1) {
        us_internal_free_timer_immediate(loop->timer);
        free(loop->bufs);
        free(loop);
        return 0;
    }

    struct io_uring_params params;
    memset(&params, 0, sizeof(params));
    params.flags = IORING_SETUP_COOP_TASKRUN | IORING_SETUP_SINGLE_ISSUER;
    if (io_uring_queue_init_params(LIBUS_IO_URING_ENTRIES, &loop->ring, &params) < 0) {
        close(loop->async_wakeup_fd);
        us_internal_free_timer_immediate(loop->timer);
        free(loop->bufs);
        free(loop);
        return 0;
    }

    if (io_uring_register_files_sparse(&loop->ring, REGISTERED_FILES_COUNT) != 0) {
        io_uring_queue_exit(&loop->ring);
        close(loop->async_wakeup_fd);
        us_internal_free_timer_immediate(loop->timer);
        free(loop->bufs);
        free(loop);
        return 0;
    }

    io_uring_register_ring_fd(&loop->ring);

    struct io_uring_buf_reg reg;
    memset(&reg, 0, sizeof(reg));
    void *buf_ring_mem = 0;
    if (posix_memalign(&buf_ring_mem, 1024 * 4, sizeof(struct io_uring_buf) * BUFFERS_COUNT) != 0) {
        io_uring_queue_exit(&loop->ring);
        close(loop->async_wakeup_fd);
        us_internal_free_timer_immediate(loop->timer);
        free(loop->bufs);
        free(loop);
        return 0;
    }
    reg.ring_addr = (__u64) (uintptr_t) buf_ring_mem;
    reg.ring_entries = BUFFERS_COUNT;
    reg.bgid = loop->buf_group_id;
    loop->buf_ring = (struct io_uring_buf_ring *) buf_ring_mem;

    if (io_uring_register_buf_ring(&loop->ring, &reg, 0) != 0) {
        free(loop->buf_ring);
        loop->buf_ring = 0;
        io_uring_queue_exit(&loop->ring);
        close(loop->async_wakeup_fd);
        us_internal_free_timer_immediate(loop->timer);
        free(loop->bufs);
        free(loop);
        return 0;
    }

    io_uring_buf_ring_init(loop->buf_ring);
    for (int i = 0; i < BUFFERS_COUNT; i++) {
        io_uring_buf_ring_add(loop->buf_ring, loop->bufs[i], MAX_MESSAGE_LEN, (unsigned short) i, io_uring_buf_ring_mask(BUFFERS_COUNT), (int) i);
    }
    io_uring_buf_ring_advance(loop->buf_ring, BUFFERS_COUNT);

    return loop;
}

void us_internal_loop_data_free(struct us_loop_t *loop) {
    if (!loop) {
        return;
    }
    us_internal_free_closed_sockets(loop);
    us_internal_free_closed_listen_sockets(loop);
    us_internal_free_closed_timers(loop);
    if (loop->timer) {
        us_internal_free_timer_immediate(loop->timer);
        loop->timer = 0;
    }
    if (loop->async_wakeup_fd >= 0) {
        close(loop->async_wakeup_fd);
        loop->async_wakeup_fd = -1;
    }
    if (loop->buf_ring) {
        free(loop->buf_ring);
        loop->buf_ring = 0;
    }
    if (loop->bufs) {
        free(loop->bufs);
        loop->bufs = 0;
    }
    io_uring_queue_exit(&loop->ring);
    while (loop->closed_head) {
        struct us_socket_t *next = loop->closed_head->next;
        us_internal_socket_free_write_buffer(loop->closed_head);
        free(loop->closed_head);
        loop->closed_head = next;
    }
    while (loop->closed_listen_head) {
        struct us_listen_socket_t *next = loop->closed_listen_head->next_closed;
        free(loop->closed_listen_head);
        loop->closed_listen_head = next;
    }
    while (loop->closed_timer_head) {
        struct us_timer_t *next = loop->closed_timer_head->next_closed;
        free(loop->closed_timer_head);
        loop->closed_timer_head = next;
    }
}

void us_wakeup_loop(struct us_loop_t *loop) {
    if (!loop || loop->async_wakeup_fd < 0) {
        return;
    }
    uint64_t one = 1;
    int written = write(loop->async_wakeup_fd, &one, 8);
    (void) written;
}

void us_internal_loop_link(struct us_loop_t *loop, struct us_socket_context_t *context) {
    if (!loop || !context) {
        return;
    }
    context->next = loop->head;
    context->prev = 0;
    if (loop->head) {
        loop->head->prev = context;
    }
    loop->head = context;
}

void us_internal_loop_unlink(struct us_loop_t *loop, struct us_socket_context_t *context) {
    if (!loop || !context) {
        return;
    }

    if (context == loop->iterator) {
        loop->iterator = context->next;
    }
    if (context == loop->head) {
        loop->head = context->next;
    }
    if (context->prev) {
        context->prev->next = context->next;
    }
    if (context->next) {
        context->next->prev = context->prev;
    }
    context->prev = 0;
    context->next = 0;

    if (!loop->head) {
        loop->num_polls = 0;
    }
}

void us_internal_handle_low_priority_sockets(struct us_loop_t *loop) {
    (void) loop;
}

void us_internal_queue_closed_socket(struct us_loop_t *loop, struct us_socket_t *s) {
    if (!loop || !s || s->queued_for_free) {
        return;
    }
    s->next = loop->closed_head;
    loop->closed_head = s;
    s->queued_for_free = 1;
}

void us_internal_free_closed_sockets(struct us_loop_t *loop) {
    if (!loop) {
        return;
    }
    struct us_socket_t *s = loop->closed_head;
    loop->closed_head = 0;
    struct us_socket_t *keep = 0;
    while (s) {
        struct us_socket_t *next = s->next;
        if (s->read_pending || s->write_pending || s->connect_pending) {
            s->next = keep;
            keep = s;
            s = next;
            continue;
        }
        us_internal_socket_free_write_buffer(s);
        free(s);
        s = next;
    }
    loop->closed_head = keep;
}

void us_internal_free_closed_listen_sockets(struct us_loop_t *loop) {
    if (!loop) {
        return;
    }
    struct us_listen_socket_t *ls = loop->closed_listen_head;
    loop->closed_listen_head = 0;
    struct us_listen_socket_t *keep = 0;
    while (ls) {
        struct us_listen_socket_t *next = ls->next_closed;
        if (ls->accept_pending) {
            ls->next_closed = keep;
            keep = ls;
            ls = next;
            continue;
        }
        free(ls);
        ls = next;
    }
    loop->closed_listen_head = keep;
}

void us_internal_free_closed_timers(struct us_loop_t *loop) {
    if (!loop) {
        return;
    }
    struct us_timer_t *timer = loop->closed_timer_head;
    loop->closed_timer_head = 0;
    struct us_timer_t *keep = 0;
    while (timer) {
        struct us_timer_t *next = timer->next_closed;
        if (timer->pending) {
            timer->next_closed = keep;
            keep = timer;
            timer = next;
            continue;
        }
        free(timer);
        timer = next;
    }
    loop->closed_timer_head = keep;
}

long long us_loop_iteration_number(struct us_loop_t *loop) {
    return loop ? loop->iteration_nr : 0;
}

void us_internal_loop_pre(struct us_loop_t *loop) {
    if (loop) {
        loop->iteration_nr++;
        if (loop->pre_cb) {
            loop->pre_cb(loop);
        }
    }
}

void us_internal_loop_post(struct us_loop_t *loop) {
    if (loop && loop->post_cb) {
        loop->post_cb(loop);
    }
}

void us_loop_integrate(struct us_loop_t *loop) {
    if (loop && loop->num_polls == 0) {
        loop->num_polls = 1;
    }
}

void *us_loop_ext(struct us_loop_t *loop) {
    return loop ? (loop + 1) : 0;
}

#endif
