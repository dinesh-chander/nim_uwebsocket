/*
 * Authored by Alex Hultman, 2018-2021.
 * Intellectual property of third-party.

 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at

 *     http://www.apache.org/licenses/LICENSE-2.0

 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "libusockets.h"
#include "internal/internal.h"
#include <stdlib.h>

#ifdef LIBUS_USE_GCD

/* Loops */
struct us_loop_t *us_create_loop(void *hint, void (*wakeup_cb)(struct us_loop_t *loop), void (*pre_cb)(struct us_loop_t *loop), void (*post_cb)(struct us_loop_t *loop), unsigned int ext_size) {
    struct us_loop_t *loop = (struct us_loop_t *) malloc(sizeof(struct us_loop_t) + ext_size);
    if (!loop) {
        return 0;
    }

    loop->gcd_queue = hint ? (dispatch_queue_t) hint : dispatch_get_main_queue();
    loop->num_polls = 0;

    if (!us_internal_loop_data_init(loop, wakeup_cb, pre_cb, post_cb)) {
        free(loop);
        return 0;
    }

    // why not call integrate here? instead of in run

    return loop;
}

void us_loop_free(struct us_loop_t *loop) {
    us_internal_loop_data_free(loop);
    
    // free queue if different from main

    free(loop);
}

/* We don't actually need to include CoreFoundation as we only need one single function,
 * It will be up to the user to link to CoreFoundation, however that should be automatic in most use cases */
extern void CFRunLoopRun();
extern void CFRunLoopStop(void *rl);
extern void *CFRunLoopGetCurrent();

void us_loop_run(struct us_loop_t *loop) {
    us_loop_integrate(loop);

    /* We are absolutely not compatible with dispatch_main,
     * However every real application should run with CoreFoundation,
     * Foundation or Cocoa as the main loop, driving dispatch anyways */
    CFRunLoopRun();

    /* I guess "fallthrough" polls should be added to another run mode than the default one to fall through */
}

void us_loop_stop(struct us_loop_t *loop) {
    (void) loop;
    CFRunLoopStop(CFRunLoopGetCurrent());
}

void gcd_read_handler(void *p) {
    struct us_poll_t *poll = (struct us_poll_t *) p;
    if (!poll || poll->closed) {
        return;
    }
    struct us_loop_t *loop = poll ? poll->loop : 0;
    if (loop) {
        us_internal_loop_pre(loop);
    }
    us_internal_dispatch_ready_poll(poll, 0, LIBUS_SOCKET_READABLE);
    if (loop) {
        us_internal_loop_post(loop);
    }
}

void gcd_write_handler(void *p) {
    struct us_poll_t *poll = (struct us_poll_t *) p;
    if (!poll || poll->closed) {
        return;
    }
    struct us_loop_t *loop = poll ? poll->loop : 0;
    if (loop) {
        us_internal_loop_pre(loop);
    }
    us_internal_dispatch_ready_poll(poll, 0, LIBUS_SOCKET_WRITABLE);
    if (loop) {
        us_internal_loop_post(loop);
    }
}

void gcd_poll_cancel_handler(void *p) {
    struct us_poll_t *poll = (struct us_poll_t *) p;
    if (!poll) {
        return;
    }
    poll->cancelled_sources++;
    if (poll->cancelled_sources >= 2) {
        free(poll);
    }
}

/* Polls */
void us_poll_init(struct us_poll_t *p, LIBUS_SOCKET_DESCRIPTOR fd, int poll_type) {
    p->poll_type = poll_type;
    p->fd = fd;
    p->loop = 0;
    p->closed = 0;
    p->cancelled_sources = 0;

    /* I guess these are already activated? */
    p->gcd_read = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, p->fd, 0, dispatch_get_main_queue());
    dispatch_set_context(p->gcd_read, p);
    dispatch_source_set_event_handler_f(p->gcd_read, gcd_read_handler);
    dispatch_source_set_cancel_handler_f(p->gcd_read, gcd_poll_cancel_handler);

    p->gcd_write = dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE, p->fd, 0, dispatch_get_main_queue());
    dispatch_set_context(p->gcd_write, p);
    dispatch_source_set_event_handler_f(p->gcd_write, gcd_write_handler);
    dispatch_source_set_cancel_handler_f(p->gcd_write, gcd_poll_cancel_handler);
}

void us_poll_free(struct us_poll_t *p, struct us_loop_t *loop) {
    if (!p || p->closed) {
        return;
    }
    p->closed = 1;
    us_poll_change(p, loop, LIBUS_SOCKET_READABLE | LIBUS_SOCKET_WRITABLE);
    dispatch_source_cancel(p->gcd_read);
    dispatch_release(p->gcd_read);
    dispatch_source_cancel(p->gcd_write);
    dispatch_release(p->gcd_write);
    if (loop) {
        loop->num_polls--;
    }
}

void us_poll_start(struct us_poll_t *p, struct us_loop_t *loop, int events) {
    p->loop = loop;
    p->events = events;

    if (events & LIBUS_SOCKET_READABLE) {
        dispatch_resume(p->gcd_read);
    }

    if (events & LIBUS_SOCKET_WRITABLE) {
        dispatch_resume(p->gcd_write);
    }
}

void us_poll_change(struct us_poll_t *p, struct us_loop_t *loop, int events) {
    int old_events = p->events;

    if ((old_events & LIBUS_SOCKET_READABLE) != (events & LIBUS_SOCKET_READABLE)) {
        if (old_events & LIBUS_SOCKET_READABLE) {
            dispatch_suspend(p->gcd_read);
        } else {
            dispatch_resume(p->gcd_read);
        }
    }

    if ((old_events & LIBUS_SOCKET_WRITABLE) != (events & LIBUS_SOCKET_WRITABLE)) {
        if (old_events & LIBUS_SOCKET_WRITABLE) {
            dispatch_suspend(p->gcd_write);
        } else {
            dispatch_resume(p->gcd_write);
        }
    }

    p->events = events;
}

void us_poll_stop(struct us_poll_t *p, struct us_loop_t *loop) {
    if (p->events & LIBUS_SOCKET_READABLE) {
        dispatch_suspend(p->gcd_read);
    }

    if (p->events & LIBUS_SOCKET_WRITABLE) {
        dispatch_suspend(p->gcd_write);
    }

    p->events = 0;
}

int us_poll_events(struct us_poll_t *p) {
    return p->events;
}

void *us_poll_ext(struct us_poll_t *p) {
    return p + 1;
}

unsigned int us_internal_accept_poll_event(struct us_poll_t *p) {
    //printf("us_internal_accept_poll_event\n");
    return 0;
}

int us_internal_poll_type(struct us_poll_t *p) {
    return p->poll_type & 3;
}

void us_internal_poll_set_type(struct us_poll_t *p, int poll_type) {
    p->poll_type = poll_type;
}

LIBUS_SOCKET_DESCRIPTOR us_poll_fd(struct us_poll_t *p) {
    return p->fd;
}

struct us_poll_t *us_create_poll(struct us_loop_t *loop, int fallthrough, unsigned int ext_size) {
    struct us_poll_t *poll = (struct us_poll_t *) malloc(sizeof(struct us_poll_t) + ext_size);
    if (!poll) {
        return 0;
    }

    if (!fallthrough) {
        loop->num_polls++;
    }

    return poll;
}

struct us_poll_t *us_poll_resize(struct us_poll_t *p, struct us_loop_t *loop, unsigned int ext_size) {
    int events = us_poll_events(p);

    struct us_poll_t *new_p = realloc(p, sizeof(struct us_poll_t) + ext_size);
    if (!new_p) {
        return 0;
    }
    if (p != new_p) {
        dispatch_set_context(new_p->gcd_read, new_p);
        dispatch_set_context(new_p->gcd_write, new_p);
    }
    new_p->loop = loop;
    new_p->events = events;

    return new_p;
}

/* Timers */
void gcd_timer_handler(void *t) {
    struct us_internal_callback_t *internal_cb = (struct us_internal_callback_t *) t;
    struct us_loop_t *loop = internal_cb ? internal_cb->loop : 0;

    if (loop) {
        us_internal_loop_pre(loop);
    }
    if (internal_cb && !internal_cb->closed && internal_cb->cb) {
        internal_cb->cb(t);
    }
    if (loop) {
        us_internal_loop_post(loop);
    }
}

void gcd_timer_cancel_handler(void *t) {
    free(t);
}

struct us_timer_t *us_create_timer(struct us_loop_t *loop, int fallthrough, unsigned int ext_size) {
    struct us_internal_callback_t *cb = malloc(sizeof(struct us_internal_callback_t) + sizeof(dispatch_source_t) + ext_size);
    if (!cb) {
        return 0;
    }

    cb->loop = loop;
    cb->cb_expects_the_loop = 0;
    cb->closed = 0;
    /* Reuse leave_poll_ready as a small activation flag for GCD timers.
     * Dispatch sources must be activated before release, but timer sources
     * created for loop internals can be closed before us_timer_set is called.
     */
    cb->leave_poll_ready = 0;

    dispatch_source_t *gcd_timer = (dispatch_source_t *) (cb + 1);

    *gcd_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (!(*gcd_timer)) {
        free(cb);
        return 0;
    }
    dispatch_source_set_event_handler_f(*gcd_timer, gcd_timer_handler);
    dispatch_source_set_cancel_handler_f(*gcd_timer, gcd_timer_cancel_handler);
    dispatch_set_context(*gcd_timer, cb);

    if (fallthrough) {
        //uv_unref((uv_handle_t *) uv_timer);
    }

    return (struct us_timer_t *) cb;
}

void *us_timer_ext(struct us_timer_t *timer) {
    struct us_internal_callback_t *cb = (struct us_internal_callback_t *) timer;
    return ((char *)(cb + 1)) + sizeof(dispatch_source_t);
}

void us_timer_close(struct us_timer_t *t) {
    struct us_internal_callback_t *internal_cb = (struct us_internal_callback_t *) t;
    if (!internal_cb || internal_cb->closed) {
        return;
    }
    internal_cb->closed = 1;
    dispatch_source_t *gcd_timer = (dispatch_source_t *) (internal_cb + 1);
    if (*gcd_timer) {
        if (!internal_cb->leave_poll_ready) {
            dispatch_activate(*gcd_timer);
            internal_cb->leave_poll_ready = 1;
        }
        dispatch_source_cancel(*gcd_timer);
        dispatch_release(*gcd_timer);
        *gcd_timer = 0;
    } else {
        free(internal_cb);
    }
}

void us_timer_set(struct us_timer_t *t, void (*cb)(struct us_timer_t *t), int ms, int repeat_ms) {
    struct us_internal_callback_t *internal_cb = (struct us_internal_callback_t *) t;

    internal_cb->cb = (void(*)(struct us_internal_callback_t *)) cb;
    if (internal_cb->closed) {
        return;
    }

    dispatch_source_t *gcd_timer = (dispatch_source_t *) (internal_cb + 1);
    uint64_t start_nanos = (uint64_t)ms * 1000000;
    uint64_t repeat_nanos = repeat_ms > 0 ? (uint64_t)repeat_ms * 1000000 : DISPATCH_TIME_FOREVER;
    dispatch_source_set_timer(*gcd_timer,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)start_nanos),
        repeat_nanos, 0);
    if (!internal_cb->leave_poll_ready) {
        dispatch_activate(*gcd_timer);
        internal_cb->leave_poll_ready = 1;
    }
}

struct us_loop_t *us_timer_loop(struct us_timer_t *t) {
    struct us_internal_callback_t *internal_cb = (struct us_internal_callback_t *) t;

    return internal_cb->loop;
}

/* Asyncs */
void async_handler(void *c) {
    struct us_internal_callback_t *internal_cb = (struct us_internal_callback_t *) c;

    internal_cb->cb((struct us_internal_callback_t *) internal_cb->loop);
}

void gcd_async_dispatch_handler(void *c) {
    struct us_internal_callback_t *internal_cb = (struct us_internal_callback_t *) c;
    struct us_loop_t *loop = internal_cb ? internal_cb->loop : 0;
    if (loop) {
        us_internal_loop_pre(loop);
    }
    us_internal_dispatch_ready_poll((struct us_poll_t *) c, 0, LIBUS_SOCKET_READABLE);
    if (loop) {
        us_internal_loop_post(loop);
    }
}

void gcd_async_cancel_handler(void *c) {
    free(c);
}

struct us_internal_async *us_internal_create_async(struct us_loop_t *loop, int fallthrough, unsigned int ext_size) {
    struct us_internal_callback_t *cb = malloc(sizeof(struct us_internal_callback_t) + sizeof(dispatch_source_t) + ext_size);
    if (!cb) {
        return 0;
    }

    cb->loop = loop;
    cb->cb_expects_the_loop = 1;
    cb->leave_poll_ready = 1;
    cb->p.events = LIBUS_SOCKET_READABLE;
    cb->p.fd = -1;
    cb->p.loop = loop;
    cb->p.poll_type = POLL_TYPE_CALLBACK;
    cb->p.gcd_read = 0;
    cb->p.gcd_write = 0;

    dispatch_source_t *gcd_async = (dispatch_source_t *) (cb + 1);
    *gcd_async = dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_ADD, 0, 0, dispatch_get_main_queue());
    if (!(*gcd_async)) {
        free(cb);
        return 0;
    }
    dispatch_source_set_event_handler_f(*gcd_async, gcd_async_dispatch_handler);
    dispatch_source_set_cancel_handler_f(*gcd_async, gcd_async_cancel_handler);
    dispatch_set_context(*gcd_async, cb);
    dispatch_activate(*gcd_async);

    if (fallthrough) {
        //uv_unref((uv_handle_t *) uv_timer);
    }

    return (struct us_internal_async *) cb;
}

void us_internal_async_close(struct us_internal_async *a) {
    struct us_internal_callback_t *cb = (struct us_internal_callback_t *) a;
    dispatch_source_t *gcd_async = (dispatch_source_t *) (cb + 1);
    if (*gcd_async) {
        dispatch_source_cancel(*gcd_async);
        dispatch_release(*gcd_async);
        *gcd_async = 0;
    } else {
        free(cb);
    }
}

void us_internal_async_set(struct us_internal_async *a, void (*cb)(struct us_internal_async *)) {
    struct us_internal_callback_t *internal_cb = (struct us_internal_callback_t *) a;

    internal_cb->cb = (void (*)(struct us_internal_callback_t *)) cb;
}

void us_internal_async_wakeup(struct us_internal_async *a) {
    struct us_internal_callback_t *internal_cb = (struct us_internal_callback_t *) a;
    dispatch_source_t *gcd_async = (dispatch_source_t *) (internal_cb + 1);
    if (*gcd_async) {
        dispatch_source_merge_data(*gcd_async, 1);
    }
}

#endif
