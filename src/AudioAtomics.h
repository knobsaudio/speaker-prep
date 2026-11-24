//
//  AudioAtomics.h
//  SpeakerPrep
//

#ifndef AudioAtomics_h
#define AudioAtomics_h

#include <stdatomic.h>
#include <stdint.h>

_Static_assert(sizeof(_Atomic(int32_t)) == sizeof(int32_t), "atomic size mismatch");
_Static_assert(_Alignof(_Atomic(int32_t)) == _Alignof(int32_t), "atomic align mismatch");

static inline int32_t atomicLoadInt32(const int32_t *ptr) {
    return atomic_load_explicit((const _Atomic(int32_t) *)ptr, memory_order_acquire);
}

static inline void atomicStoreInt32(int32_t *ptr, int32_t value) {
    atomic_store_explicit((_Atomic(int32_t) *)ptr, value, memory_order_release);
}

#endif
