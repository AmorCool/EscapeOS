package unicorn

/*
#include <stdint.h>
#include "unicorn.h"

// Forward declaration matching cgo's generated export of goHookTrampoline. cgo
// maps the Go signature (unsafe.Pointer, uint64, uint32, uintptr) to the C
// prototype (void*, uint64_t, uint32_t, uintptr_t). The real definition is
// emitted by cgo into _cgo_export.h; this declaration must match it exactly or
// the C compiler will report conflicting types for goHookTrampoline.
extern void goHookTrampoline(void *engine, uint64_t address, uint32_t size, uintptr_t user_data);

static inline void *sap_hook_trampoline(void) {
	return (void *)(uintptr_t)goHookTrampoline;
}
*/
import "C"

import (
	"errors"
	"sync"
	"sync/atomic"
	"unsafe"
)

const hookCode = 1 << 2

type CodeHook func(address uint64, size uint32)

type hookState struct {
	mu  sync.Mutex
	ids map[uintptr]struct{}
}

type Hook struct {
	mu     sync.Mutex
	engine *Engine
	// uc_hook is typedef'd to size_t in the Unicorn API — an opaque INTEGER
	// handle, not a pointer. Keep it as the C type so uc_hook_del type-checks
	// without any unsafe.Pointer conversion (which is invalid for integers).
	handle C.uc_hook
	id     uintptr
}

var (
	codeHookID        atomic.Uint64
	codeHookCallbacks sync.Map
)

// goHookTrampoline is the C-callable entry point Unicorn invokes for each
// instruction in the hooked range. It dispatches to the Go callback registered
// under the supplied user_data (a hook id). It must not panic.
//
//export goHookTrampoline
func goHookTrampoline(engine unsafe.Pointer, address uint64, size uint32, userData uintptr) {
	callback, ok := codeHookCallbacks.Load(userData)
	if ok {
		callback.(CodeHook)(address, size)
	}
}

// AddCodeHook registers callback for instructions whose start address is in the
// inclusive range [begin, end]. The callback is retained until the Hook or
// Engine is closed; it runs through a C ABI trampoline and must not panic.
func (e *Engine) AddCodeHook(begin, end uint64, callback CodeHook) (*Hook, error) {
	handle, done, err := e.beginOperation()
	if err != nil {
		return nil, err
	}

	defer done()

	if callback == nil {
		return nil, errors.New("unicorn code hook callback is nil")
	}

	id := uintptr(codeHookID.Add(1))
	if id == 0 {
		id = uintptr(codeHookID.Add(1))
	}

	codeHookCallbacks.Store(id, callback)

	// uc_hook_add is variadic (uc_engine*, uc_hook*, int type, void* callback,
	// void* user_data, ...) and cgo cannot call variadic C functions, so this
	// goes through the fixed-arity sap_uc_hook_add wrapper in unicorn.h.
	var hookHandle C.uc_hook
	if cerr := C.sap_uc_hook_add(
		handle,
		&hookHandle,
		C.int(hookCode),
		C.sap_hook_trampoline(),
		unsafe.Pointer(id),
		C.uint64_t(begin),
		C.uint64_t(end),
	); cerr != 0 {
		codeHookCallbacks.Delete(id)

		return nil, e.err(int32(cerr))
	}

	e.hooks.mu.Lock()
	if e.hooks.ids == nil {
		e.hooks.ids = make(map[uintptr]struct{})
	}

	e.hooks.ids[id] = struct{}{}
	e.hooks.mu.Unlock()

	return &Hook{engine: e, handle: hookHandle, id: id}, nil
}

func (h *Hook) Close() error {
	if h == nil {
		return nil
	}

	h.mu.Lock()
	defer h.mu.Unlock()

	if h.engine == nil {
		return nil
	}

	engine := h.engine
	handle, done, err := engine.beginOperation()

	if err == nil {
		err = engine.err(int32(C.uc_hook_del(handle, h.handle)))

		done()

		if err != nil {
			return err
		}
	} else if !errors.Is(err, errEngineClosed) {
		return err
	}

	codeHookCallbacks.Delete(h.id)
	engine.hooks.mu.Lock()
	delete(engine.hooks.ids, h.id)
	engine.hooks.mu.Unlock()

	h.engine = nil
	h.handle = 0
	h.id = 0

	return nil
}

func (e *Engine) clearCodeHooks() {
	e.hooks.mu.Lock()
	defer e.hooks.mu.Unlock()

	for id := range e.hooks.ids {
		codeHookCallbacks.Delete(id)
	}

	clear(e.hooks.ids)
}
