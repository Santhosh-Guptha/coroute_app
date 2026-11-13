'use strict';
/**
 * Round 8 jobs: what a handler can throw to steer the queue.
 *   RetryLater(ms)   retry after ms (counts as an attempt, like any error, but with the given delay)
 *   Defer(ms)        not now (no budget, upstream backoff): run again after ms WITHOUT spending an attempt
 *   PermanentError   never retry: straight to the dead-letter queue
 * Any other error is retried with exponential backoff and jitter until maxAttempts, then dead-lettered.
 */
class RetryLater extends Error {
  constructor(ms, message = 'retry later') { super(message); this.name = 'RetryLater'; this.retryInMs = Math.max(0, Number(ms) || 0); }
}
class Defer extends Error {
  constructor(ms, message = 'deferred') { super(message); this.name = 'Defer'; this.deferMs = Math.max(0, Number(ms) || 0); }
}
class PermanentError extends Error {
  constructor(message = 'permanent failure', code = 'PERMANENT') { super(message); this.name = 'PermanentError'; this.code = code; }
}

module.exports = { RetryLater, Defer, PermanentError };
