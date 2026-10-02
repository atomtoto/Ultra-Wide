#pragma once

#include <algorithm>
#include <dispatch/dispatch.h>
#include <exception>
#include <vector>

namespace uw {

// Synchronous, bounded workers for disjoint output tiles. Frames still finish
// in capture order so the weighted blend stays bit-for-bit deterministic.
// Exceptions must never unwind through a libdispatch callback.
template <class Body>
void ParallelFor(size_t count, size_t workerLimit, const Body &body) {
    if (!count) return;
    const size_t workers = std::max(size_t(1), std::min(count, workerLimit));
    if (workers == 1) {
        for (size_t index = 0; index < count; ++index) body(index);
        return;
    }
    struct Work {
        size_t count, workers;
        const Body &body;
        std::vector<std::exception_ptr> errors;
    } work{count, workers, body, std::vector<std::exception_ptr>(workers)};
    dispatch_apply_f(workers, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), &work,
        [](void *context, size_t worker) {
            auto &work = *static_cast<Work *>(context);
            try {
                for (size_t index = worker; index < work.count; index += work.workers) work.body(index);
            } catch (...) { work.errors[worker] = std::current_exception(); }
        });
    for (const auto &error : work.errors) {
        if (error) std::rethrow_exception(error);
    }
}

} // namespace uw
