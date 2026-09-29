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
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/uio.h>

#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif

#ifndef MSG_MORE
#define MSG_MORE 0
#endif

static int us_internal_nonnegative_len(int length) {
    return length > 0 ? length : 0;
}

static char *us_internal_socket_write_buffer(struct us_socket_t *s, int length) {
    if (!s || length <= 0) {
        return 0;
    }
    if (length <= (int) sizeof(s->sendBuf)) {
        return s->sendBuf;
    }
    if ((size_t) length > s->write_buf_capacity) {
        char *next = realloc(s->write_buf, (size_t) length);
        if (!next) {
            return 0;
        }
        s->write_buf = next;
        s->write_buf_capacity = (size_t) length;
    }
    return s->write_buf;
}

static int us_internal_socket_send_flags(int msg_more) {
    return MSG_NOSIGNAL | (msg_more ? MSG_MORE : 0);
}

static int us_internal_socket_would_block(int error) {
    return error == EAGAIN || error == EWOULDBLOCK;
}

static int us_internal_socket_can_queue_fallback(struct us_socket_t *s) {
    if (!s || s->dd < 0 || !s->context || !s->context->loop) {
        return 0;
    }
    if (io_uring_sq_space_left(&s->context->loop->ring) == 0) {
        io_uring_submit(&s->context->loop->ring);
    }
    return io_uring_sq_space_left(&s->context->loop->ring) > 0;
}

static int us_internal_socket_handle_direct_write_error(struct us_socket_t *s) {
    if (!s || !s->context) {
        return 0;
    }
    if (s->context->on_close) {
        s->context->on_close(s, 0, 0);
    }
    us_socket_close_connecting(0, s);
    return 0;
}

static int us_internal_socket_try_direct_send(struct us_socket_t *s, const char *data, int length, int msg_more, int *written_out) {
    if (written_out) {
        *written_out = 0;
    }
    if (!s || s->fd < 0 || !data || length <= 0 || !written_out) {
        return 0;
    }

    ssize_t written;
    do {
        written = send(s->fd, data, (size_t) length, us_internal_socket_send_flags(msg_more));
    } while (written < 0 && errno == EINTR);

    if (written > 0) {
        *written_out = written > INT32_MAX ? INT32_MAX : (int) written;
        return 0;
    }
    if (written < 0 && !us_internal_socket_would_block(errno)) {
        return -1;
    }
    return 0;
}

static int us_internal_socket_try_direct_writev(struct us_socket_t *s, struct iovec *iov, int iovcnt, int msg_more, int *written_out) {
    if (written_out) {
        *written_out = 0;
    }
    if (!s || s->fd < 0 || !iov || iovcnt <= 0 || !written_out) {
        return 0;
    }
#ifdef IOV_MAX
    if (iovcnt > IOV_MAX) {
        return 0;
    }
#endif
    for (int i = 0; i < iovcnt; i++) {
        if (iov[i].iov_len > 0 && !iov[i].iov_base) {
            return 0;
        }
    }

    struct msghdr msg;
    memset(&msg, 0, sizeof(msg));
    msg.msg_iov = iov;
    msg.msg_iovlen = (size_t) iovcnt;

    ssize_t written;
    do {
        written = sendmsg(s->fd, &msg, us_internal_socket_send_flags(msg_more));
    } while (written < 0 && errno == EINTR);

    if (written > 0) {
        *written_out = written > INT32_MAX ? INT32_MAX : (int) written;
        return 0;
    }
    if (written < 0 && !us_internal_socket_would_block(errno)) {
        return -1;
    }
    return 0;
}

static int us_internal_iov_total_matches(struct iovec *iov, int iovcnt, int total_length) {
    if (!iov || iovcnt <= 0 || total_length <= 0) {
        return 0;
    }

    int total = 0;
    for (int i = 0; i < iovcnt; i++) {
        if (iov[i].iov_len > (size_t) INT32_MAX) {
            return 0;
        }
        int entry_len = (int) iov[i].iov_len;
        if (entry_len < 0 || total > total_length - entry_len) {
            return 0;
        }
        total += entry_len;
    }
    return total == total_length;
}

static int us_internal_copy_iov_remaining(char *buffer, struct iovec *iov, int iovcnt, int total_length, int skip) {
    if (!buffer || !iov || iovcnt <= 0 || total_length <= 0 || skip < 0 || skip > total_length) {
        return 0;
    }

    int copied = 0;
    int skip_remaining = skip;
    int target_length = total_length - skip;
    for (int i = 0; i < iovcnt && copied < target_length; i++) {
        size_t raw_len = iov[i].iov_len;
        int source_len = raw_len > (size_t) INT32_MAX ? INT32_MAX : (int) raw_len;
        if (source_len <= 0) {
            continue;
        }
        if (skip_remaining >= source_len) {
            skip_remaining -= source_len;
            continue;
        }
        if (!iov[i].iov_base) {
            return copied;
        }

        int source_offset = skip_remaining;
        skip_remaining = 0;
        int copy_len = source_len - source_offset;
        if (copy_len > target_length - copied) {
            copy_len = target_length - copied;
        }
        memcpy(buffer + copied, (char *) iov[i].iov_base + source_offset, (size_t) copy_len);
        copied += copy_len;
    }
    return copied;
}

static int us_internal_socket_submit_write(struct us_socket_t *s, char *buffer, int length, int msg_more) {
    if (!s || !buffer || length <= 0 || s->dd < 0 || !s->context || !s->context->loop) {
        return 0;
    }

    struct io_uring_sqe *sqe = us_internal_get_sqe(s->context->loop);
    if (!sqe) {
        return 0;
    }

    io_uring_prep_send(sqe, s->dd, buffer, (unsigned) length, msg_more ? MSG_MORE : 0);
    io_uring_sqe_set_flags(sqe, IOSQE_FIXED_FILE);
    io_uring_sqe_set_data(sqe, (char *) s + SOCKET_WRITE);
    s->write_pending = 1;
    s->write_drained_inline = 0;
    s->write_msg_more = msg_more ? 1 : 0;
    s->write_offset = 0;
    s->write_length = length;
    s->write_data = buffer;

    return length;
}

void us_internal_socket_free_write_buffer(struct us_socket_t *s) {
    if (!s) {
        return;
    }
    free(s->write_buf);
    s->write_buf = 0;
    s->write_buf_capacity = 0;
    s->write_data = 0;
}

static int us_internal_socket_is_marked_closed(struct us_socket_t *s) {
    if (!s || !s->context) {
        return 1;
    }
    return s->closed || s->prev == (struct us_socket_t *) s->context;
}

static void us_internal_socket_queue_close(struct us_socket_t *s) {
    if (!s || !s->context || !s->context->loop || s->dd < 0) {
        if (s && s->fd >= 0) {
            close(s->fd);
            s->fd = -1;
        }
        return;
    }
    if (s->fd >= 0) {
        close(s->fd);
        s->fd = -1;
    }
    int direct_slot = s->dd;
    s->dd = -1;
    us_internal_queue_close_direct(s->context->loop, direct_slot);
}

/* Shared with SSL */

int us_socket_local_port(int ssl, struct us_socket_t *s) {
    (void) ssl;
    if (s && s->fd >= 0) {
        struct bsd_addr_t addr;
        if (bsd_local_addr(s->fd, &addr) == 0) {
            return bsd_addr_get_port(&addr);
        }
    }
    return -1;
}

int us_socket_remote_port(int ssl, struct us_socket_t *s) {
    (void) ssl;
    if (s && s->fd >= 0) {
        struct bsd_addr_t addr;
        if (bsd_remote_addr(s->fd, &addr) == 0) {
            return bsd_addr_get_port(&addr);
        }
    }
    return -1;
}

void us_socket_shutdown_read(int ssl, struct us_socket_t *s) {
    (void) ssl;
    (void) s;
}

void us_socket_remote_address(int ssl, struct us_socket_t *s, char *buf, int *length) {
    (void) ssl;
    if (!s || !buf || !length || s->fd < 0) {
        if (length) {
            *length = 0;
        }
        return;
    }

    struct bsd_addr_t addr;
    if (bsd_remote_addr(s->fd, &addr) == 0 && *length >= bsd_addr_get_ip_length(&addr)) {
        *length = bsd_addr_get_ip_length(&addr);
        memcpy(buf, bsd_addr_get_ip(&addr), (size_t) *length);
    } else {
        *length = 0;
    }
}

struct us_socket_context_t *us_socket_context(int ssl, struct us_socket_t *s) {
    (void) ssl;
    return s ? s->context : 0;
}

void us_socket_timeout(int ssl, struct us_socket_t *s, unsigned int seconds) {
    (void) ssl;
    if (!s || !s->context) {
        return;
    }
    if (seconds) {
        s->timeout = ((unsigned int) s->context->timestamp + ((seconds + 3) >> 2)) % 240;
    } else {
        s->timeout = 255;
    }
}

void us_socket_long_timeout(int ssl, struct us_socket_t *s, unsigned int minutes) {
    (void) ssl;
    if (!s || !s->context) {
        return;
    }
    if (minutes) {
        s->long_timeout = ((unsigned int) s->context->long_timestamp + minutes) % 240;
    } else {
        s->long_timeout = 255;
    }
}

void us_socket_flush(int ssl, struct us_socket_t *s) {
    (void) ssl;
    (void) s;
}

void us_socket_cork(int ssl, struct us_socket_t *s) {
    (void) ssl;
    (void) s;
}

void us_socket_uncork(int ssl, struct us_socket_t *s) {
    (void) ssl;
    (void) s;
}

int us_socket_is_closed(int ssl, struct us_socket_t *s) {
    (void) ssl;
    return us_internal_socket_is_marked_closed(s);
}

int us_socket_is_established(int ssl, struct us_socket_t *s) {
    (void) ssl;
    return s && !us_internal_socket_is_marked_closed(s);
}

struct us_socket_t *us_socket_close_connecting(int ssl, struct us_socket_t *s) {
    (void) ssl;
    if (!s || us_internal_socket_is_marked_closed(s)) {
        return s;
    }

    struct us_socket_context_t *context = s->context;
    if (context) {
        us_internal_socket_context_unlink_socket(context, s);
        s->next = 0;
        s->prev = (struct us_socket_t *) context;
        s->closed = 1;
        s->write_drained_inline = 0;
        if (context->loop) {
            us_internal_queue_closed_socket(context->loop, s);
        }
    }

    us_internal_socket_queue_close(s);
    return s;
}

int us_socket_write2(int ssl, struct us_socket_t *s, const char *header, int header_length, const char *payload, int payload_length) {
    (void) ssl;
    if (!s || us_internal_socket_is_marked_closed(s) || s->close_pending) {
        return 0;
    }

    if (!header) {
        header_length = 0;
    }
    if (!payload) {
        payload_length = 0;
    }
    header_length = us_internal_nonnegative_len(header_length);
    payload_length = us_internal_nonnegative_len(payload_length);
    if (header_length > INT32_MAX - payload_length) {
        return 0;
    }
    int total_length = header_length + payload_length;
    if (total_length <= 0) {
        return 0;
    }
    if (s->write_pending) {
        return 0;
    }

    struct iovec chunks[2];
    int iovcnt = 0;
    if (header && header_length > 0) {
        chunks[iovcnt].iov_base = (char *) header;
        chunks[iovcnt].iov_len = (size_t) header_length;
        iovcnt++;
    }
    if (payload && payload_length > 0) {
        chunks[iovcnt].iov_base = (char *) payload;
        chunks[iovcnt].iov_len = (size_t) payload_length;
        iovcnt++;
    }

    char *buffer = us_internal_socket_write_buffer(s, total_length);
    if (!buffer) {
        return 0;
    }

    int direct_written = 0;
    if (us_internal_socket_can_queue_fallback(s)) {
        if (us_internal_socket_try_direct_writev(s, chunks, iovcnt, 0, &direct_written) < 0) {
            return us_internal_socket_handle_direct_write_error(s);
        }
        if (direct_written >= total_length) {
            s->write_drained_inline = 1;
            return direct_written;
        }
    }

    int copied = us_internal_copy_iov_remaining(buffer, chunks, iovcnt, total_length, direct_written);
    int scheduled = us_internal_socket_submit_write(s, buffer, copied, 0);
    return scheduled > 0 ? direct_written + scheduled : direct_written;
}

int us_socket_write2_unchecked(struct us_socket_t *s, const char *header, int header_length, const char *payload, int payload_length) {
    return us_socket_write2(0, s, header, header_length, payload, payload_length);
}

int us_socket_writev_n(int ssl, struct us_socket_t *s, struct iovec *iov, int iovcnt, int total_length) {
    (void) ssl;
    if (!s || !iov || iovcnt <= 0 || us_internal_socket_is_marked_closed(s) || s->close_pending || total_length <= 0) {
        return 0;
    }

    if (s->write_pending) {
        return 0;
    }

    char *buffer = us_internal_socket_write_buffer(s, total_length);
    if (!buffer) {
        return 0;
    }

    int direct_written = 0;
    if (us_internal_iov_total_matches(iov, iovcnt, total_length) && us_internal_socket_can_queue_fallback(s)) {
        if (us_internal_socket_try_direct_writev(s, iov, iovcnt, 0, &direct_written) < 0) {
            return us_internal_socket_handle_direct_write_error(s);
        }
        if (direct_written >= total_length) {
            s->write_drained_inline = 1;
            return direct_written;
        }
    }

    int copied = us_internal_copy_iov_remaining(buffer, iov, iovcnt, total_length, direct_written);
    int scheduled = us_internal_socket_submit_write(s, buffer, copied, 0);
    return scheduled > 0 ? direct_written + scheduled : direct_written;
}

char *us_socket_send_buffer(int ssl, struct us_socket_t *s) {
    (void) ssl;
    return s ? s->sendBuf : 0;
}

struct us_socket_t *us_socket_close(int ssl, struct us_socket_t *s, int code, void *reason) {
    (void) ssl;
    if (!s || us_internal_socket_is_marked_closed(s)) {
        return s;
    }
    if (s->close_pending) {
        return s;
    }
    if (s->write_pending) {
        s->close_pending = 1;
        return s;
    }
    if (s->write_drained_inline) {
        s->write_drained_inline = 0;
        s->close_pending = 1;
        if (s->fd >= 0) {
            bsd_shutdown_socket(s->fd);
        }
        return s;
    }

    struct us_socket_context_t *context = s->context;
    us_socket_close_connecting(ssl, s);
    if (context && context->on_close) {
        return context->on_close(s, code, reason);
    }
    return s;
}

/* Not shared with SSL */

void *us_socket_get_native_handle(int ssl, struct us_socket_t *s) {
    (void) ssl;
    if (!s || s->fd < 0) {
        return 0;
    }
    return (void *) (uintptr_t) s->fd;
}

int us_socket_write(int ssl, struct us_socket_t *s, const char *data, int length, int msg_more) {
    (void) ssl;
    if (!s || !data || us_internal_socket_is_marked_closed(s) || s->close_pending || length <= 0) {
        return 0;
    }
    if (s->write_pending) {
        return 0;
    }

    char *buffer = us_internal_socket_write_buffer(s, length);
    if (!buffer) {
        return 0;
    }

    int direct_written = 0;
    if (us_internal_socket_can_queue_fallback(s)) {
        if (us_internal_socket_try_direct_send(s, data, length, msg_more, &direct_written) < 0) {
            return us_internal_socket_handle_direct_write_error(s);
        }
        if (direct_written >= length) {
            s->write_drained_inline = 1;
            return direct_written;
        }
    }

    int remaining = length - direct_written;
    if (data != buffer && data && remaining > 0) {
        memcpy(buffer, data + direct_written, (size_t) remaining);
    }

    int scheduled = us_internal_socket_submit_write(s, buffer, remaining, msg_more);
    return scheduled > 0 ? direct_written + scheduled : direct_written;
}

void *us_socket_ext(int ssl, struct us_socket_t *s) {
    (void) ssl;
    return s ? (s + 1) : 0;
}

int us_socket_is_shut_down(int ssl, struct us_socket_t *s) {
    (void) ssl;
    return us_internal_socket_is_marked_closed(s) || (s && s->close_pending);
}

void us_socket_shutdown(int ssl, struct us_socket_t *s) {
    (void) ssl;
    if (!s || us_internal_socket_is_marked_closed(s) || s->close_pending) {
        return;
    }
    s->close_pending = 1;
    if (s->write_pending) {
        return;
    }
    bsd_shutdown_socket(s->fd);
}

#endif
