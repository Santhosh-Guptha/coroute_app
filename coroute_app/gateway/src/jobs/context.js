'use strict';
/**
 * Round 8 jobs: "am I running inside a job handler?" (AsyncLocalStorage). A producer that is already running on a
 * worker (a campaign tick, a nightly batch) does its work directly instead of enqueueing another job for it.
 */
const { AsyncLocalStorage } = require('node:async_hooks');

const als = new AsyncLocalStorage();

/** Runs fn with the job context set (the worker calls this around every handler). */
function runInJob(job, fn) { return als.run({ jobId: job && job.jobId, type: job && job.type }, fn); }

/** The current job ({ jobId, type }) or null. */
function currentJob() { return als.getStore() || null; }

/** True inside a job handler. */
function inJob() { return !!als.getStore(); }

module.exports = { runInJob, currentJob, inJob };
