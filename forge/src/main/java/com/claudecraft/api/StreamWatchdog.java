package com.claudecraft.api;

import java.io.Closeable;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Closes a streaming HTTP body when no data has arrived for too long.
 *
 * <p>{@link java.net.http.HttpRequest#timeout} only covers waiting for the response
 * headers, and a read blocked on an {@code ofInputStream()} body ignores thread
 * interrupts. Closing the body stream is the one thing that wakes the reader, which
 * then fails with an IOException; check {@link Watch#stalled()} to tell a stall from
 * other failures.
 */
final class StreamWatchdog {
    private static final ScheduledExecutorService TIMER =
            Executors.newSingleThreadScheduledExecutor(r -> {
                Thread t = new Thread(r, "ClaudeCraft-StreamWatchdog");
                t.setDaemon(true);
                return t;
            });

    private StreamWatchdog() {}

    /** Start watching {@code stream}; call {@link Watch#touch()} whenever data arrives. */
    static Watch watch(Closeable stream, long idleMillis) {
        return new Watch(stream, idleMillis);
    }

    static final class Watch implements AutoCloseable {
        private final AtomicLong lastActivity = new AtomicLong(System.nanoTime());
        private final long idleNanos;
        private final Closeable stream;
        private final ScheduledFuture<?> task;
        private volatile boolean stalled;

        private Watch(Closeable stream, long idleMillis) {
            this.stream = stream;
            this.idleNanos = TimeUnit.MILLISECONDS.toNanos(idleMillis);
            long period = Math.max(1000L, Math.min(5000L, idleMillis / 4));
            this.task = TIMER.scheduleWithFixedDelay(this::check, period, period,
                    TimeUnit.MILLISECONDS);
        }

        private void check() {
            if (stalled || System.nanoTime() - lastActivity.get() < idleNanos) return;
            stalled = true;
            task.cancel(false);
            try {
                stream.close();
            } catch (Exception ignored) {
            }
        }

        void touch() {
            lastActivity.set(System.nanoTime());
        }

        /** True once the watchdog closed the stream for being idle. */
        boolean stalled() {
            return stalled;
        }

        @Override
        public void close() {
            task.cancel(false);
        }
    }
}
