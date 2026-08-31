package unicorn

/*
#cgo LDFLAGS: -lunicorn
#include "unicorn.h"
*/
import "C"

import (
	"context"
	"errors"
	"fmt"
	"runtime"
	"sync"
	"time"
	"unsafe"
)

const queryTimeout = 4

const (
	archX86 = 4
	mode64  = 8
	protAll = 7

	RegRAX = 35
	RegRCX = 38
	RegRDI = 39
	RegRDX = 40
	RegRIP = 41
	RegRSI = 43
	RegRSP = 44
	RegR8  = 106
	RegR9  = 107
)

var (
	errTimeout      = errors.New("unicorn emulation timed out")
	errEngineClosed = errors.New("unicorn engine is closed")
)

type library struct {
	handle uintptr
	close  func() error
}

type Engine struct {
	handle    uintptr
	library   library
	hooks     hookState
	stateMu   sync.Mutex
	active    sync.WaitGroup
	closing   bool
	closeDone chan struct{}
	closeErr  error
}

// openLibrary returns a no-op library handle. libunicorn is linked statically
// into the bridge via cgo, so there is nothing to dlopen at runtime.
func openLibrary(context.Context) (library, error) {
	return library{handle: 0, close: func() error { return nil }}, nil
}

func New(ctx context.Context) (*Engine, error) {
	return newEngine(ctx, openLibrary)
}

func newEngine(ctx context.Context, loadLibrary func(context.Context) (library, error)) (*Engine, error) {
	if ctx == nil {
		return nil, errors.New("unicorn context is nil")
	}

	if err := ctx.Err(); err != nil {
		return nil, fmt.Errorf("create Unicorn engine: %w", err)
	}

	library, err := loadLibrary(ctx)
	if err != nil {
		return nil, fmt.Errorf("load Unicorn: %w", err)
	}

	if err := ctx.Err(); err != nil {
		_ = library.close()

		return nil, fmt.Errorf("create Unicorn engine: %w", err)
	}

	engine := &Engine{
		library:   library,
		closeDone: make(chan struct{}),
	}

	var major, minor C.uint
	_ = C.uc_version(&major, &minor)

	if uint32(major) != 2 || uint32(minor) != 1 {
		_ = library.close()

		return nil, fmt.Errorf("unsupported Unicorn API version %d.%d", uint32(major), uint32(minor))
	}

	if cerr := C.uc_open(C.int(archX86), C.int(mode64), (*C.uc_engine)(unsafe.Pointer(&engine.handle))); cerr != 0 {
		_ = library.close()

		return nil, fmt.Errorf("create x86-64 emulator: %w", engine.err(int32(cerr)))
	}

	if err := configureEngine(engine); err != nil {
		_ = C.uc_close((*C.uc_engine)(unsafe.Pointer(&engine.handle)))
		_ = library.close()

		return nil, err
	}

	runtime.SetFinalizer(engine, func(engine *Engine) {
		_ = engine.Close()
	})

	return engine, nil
}

func (e *Engine) MemMap(address, size uint64) error {
	handle, done, err := e.beginOperation()
	if err != nil {
		return err
	}

	defer done()

	eng := (*C.uc_engine)(unsafe.Pointer(&handle))

	return e.err(int32(C.uc_mem_map(eng, C.uint64_t(address), C.uint64_t(size), C.uint32_t(protAll))))
}

func (e *Engine) MemUnmap(address, size uint64) error {
	handle, done, err := e.beginOperation()
	if err != nil {
		return err
	}

	defer done()

	eng := (*C.uc_engine)(unsafe.Pointer(&handle))

	return e.err(int32(C.uc_mem_unmap(eng, C.uint64_t(address), C.uint64_t(size))))
}

func (e *Engine) MemRead(address, size uint64) ([]byte, error) {
	handle, done, err := e.beginOperation()
	if err != nil {
		return nil, err
	}
	defer done()

	data := make([]byte, size)
	if len(data) == 0 {
		return data, nil
	}

	eng := (*C.uc_engine)(unsafe.Pointer(&handle))
	cerr := C.uc_mem_read(eng, C.uint64_t(address), unsafe.Pointer(&data[0]), C.size_t(size))

	return data, e.err(int32(cerr))
}

func (e *Engine) MemReadInto(data []byte, address uint64) error {
	handle, done, err := e.beginOperation()
	if err != nil {
		return err
	}
	defer done()

	if len(data) == 0 {
		return nil
	}

	eng := (*C.uc_engine)(unsafe.Pointer(&handle))

	return e.err(int32(C.uc_mem_read(eng, C.uint64_t(address), unsafe.Pointer(&data[0]), C.size_t(len(data)))))
}

func (e *Engine) MemWrite(address uint64, data []byte) error {
	handle, done, err := e.beginOperation()
	if err != nil {
		return err
	}
	defer done()

	if len(data) == 0 {
		return nil
	}

	eng := (*C.uc_engine)(unsafe.Pointer(&handle))

	return e.err(int32(C.uc_mem_write(eng, C.uint64_t(address), unsafe.Pointer(&data[0]), C.size_t(len(data)))))
}

func (e *Engine) RegRead(register int) (uint64, error) {
	handle, done, err := e.beginOperation()
	if err != nil {
		return 0, err
	}
	defer done()

	var value uint64

	eng := (*C.uc_engine)(unsafe.Pointer(&handle))
	cerr := C.uc_reg_read(eng, C.int(register), unsafe.Pointer(&value))

	return value, e.err(int32(cerr))
}

func (e *Engine) RegWrite(register int, value uint64) error {
	handle, done, err := e.beginOperation()
	if err != nil {
		return err
	}
	defer done()

	eng := (*C.uc_engine)(unsafe.Pointer(&handle))

	return e.err(int32(C.uc_reg_write(eng, C.int(register), unsafe.Pointer(&value))))
}

func (e *Engine) Start(begin, end uint64) error {
	handle, done, err := e.beginOperation()
	if err != nil {
		return err
	}
	defer done()

	eng := (*C.uc_engine)(unsafe.Pointer(&handle))

	return e.err(int32(C.uc_emu_start(eng, C.uint64_t(begin), C.uint64_t(end), 0, 0)))
}

func (e *Engine) StartBounded(begin, end uint64, timeout time.Duration, instructionLimit uint64) error {
	if timeout <= 0 {
		return errors.New("unicorn timeout must be positive")
	}

	microseconds := uint64(timeout / time.Microsecond)
	if microseconds == 0 {
		microseconds = 1
	}

	handle, done, err := e.beginOperation()
	if err != nil {
		return err
	}
	defer done()

	eng := (*C.uc_engine)(unsafe.Pointer(&handle))

	if cerr := C.uc_emu_start(eng, C.uint64_t(begin), C.uint64_t(end), C.uint64_t(microseconds), C.size_t(instructionLimit)); cerr != 0 {
		return e.err(int32(cerr))
	}

	var timedOut uint64
	if cerr := C.sap_uc_query(eng, C.int(queryTimeout), (*C.uint64_t)(unsafe.Pointer(&timedOut))); cerr != 0 {
		return fmt.Errorf("query Unicorn timeout: %w", e.err(int32(cerr)))
	}

	if timedOut != 0 {
		return fmt.Errorf("%w after %s", errTimeout, timeout)
	}

	return nil
}

func (e *Engine) Stop() error {
	handle, done, err := e.beginOperation()
	if err != nil {
		return err
	}
	defer done()

	eng := (*C.uc_engine)(unsafe.Pointer(&handle))

	return e.err(int32(C.uc_emu_stop(eng)))
}

func (e *Engine) Close() error {
	if e == nil {
		return nil
	}

	e.stateMu.Lock()
	if e.closing {
		done := e.closeDone
		e.stateMu.Unlock()
		<-done
		e.stateMu.Lock()
		err := e.closeErr
		e.stateMu.Unlock()

		return err
	}

	e.closing = true
	e.stateMu.Unlock()

	runtime.SetFinalizer(e, nil)
	e.active.Wait()
	e.clearCodeHooks()

	e.stateMu.Lock()
	handle := e.handle
	loadedLibrary := e.library
	e.handle = 0
	e.library = library{}
	e.stateMu.Unlock()

	var errs []error

	if handle != 0 {
		eng := (*C.uc_engine)(unsafe.Pointer(&handle))
		if cerr := C.uc_close(eng); cerr != 0 {
			errs = append(errs, e.err(int32(cerr)))
		}
	}

	if loadedLibrary.close != nil {
		if err := loadedLibrary.close(); err != nil {
			errs = append(errs, err)
		}
	}

	closeErr := errors.Join(errs...)

	e.stateMu.Lock()
	e.closeErr = closeErr
	close(e.closeDone)
	e.stateMu.Unlock()

	return closeErr
}

func (e *Engine) beginOperation() (uintptr, func(), error) {
	if e == nil {
		return 0, nil, errEngineClosed
	}

	e.stateMu.Lock()
	defer e.stateMu.Unlock()

	if e.closing || e.handle == 0 {
		return 0, nil, errEngineClosed
	}

	e.active.Add(1)

	return e.handle, e.active.Done, nil
}

func (e *Engine) err(code int32) error {
	if code == 0 {
		return nil
	}

	message := "unknown error"
	if description := C.GoString(C.uc_strerror(C.uc_err(code))); description != "" {
		message = description
	}

	return fmt.Errorf("unicorn error %d: %s", code, message)
}
