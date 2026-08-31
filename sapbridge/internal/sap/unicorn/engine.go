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

// NOTE: the `library` type lives in library.go — do not redeclare it here.

// Engine owns a Unicorn x86-64 emulator. handle is kept as a typed *C.uc_engine
// (not a uintptr) so that (a) cgo type-checks every call, and (b) we never have
// to reconstruct a pointer from an integer. Storing it as uintptr and doing
// (*C.uc_engine)(unsafe.Pointer(&handle)) is wrong twice over: it is a type
// error for uc_open (which wants uc_engine**) and, where it does type-check, it
// yields the ADDRESS of the handle variable rather than the engine pointer it
// holds — a silent runtime bug.
type Engine struct {
	handle    *C.uc_engine
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

	lib, err := loadLibrary(ctx)
	if err != nil {
		return nil, fmt.Errorf("load Unicorn: %w", err)
	}

	if err := ctx.Err(); err != nil {
		_ = lib.close()

		return nil, fmt.Errorf("create Unicorn engine: %w", err)
	}

	engine := &Engine{
		library:   lib,
		closeDone: make(chan struct{}),
	}

	var major, minor C.uint
	_ = C.uc_version(&major, &minor)

	if uint32(major) != 2 || uint32(minor) != 1 {
		_ = lib.close()

		return nil, fmt.Errorf("unsupported Unicorn API version %d.%d", uint32(major), uint32(minor))
	}

	// uc_open(uc_arch arch, uc_mode mode, uc_engine **uc):
	//   - arch/mode are enums, so they must be converted with C.uc_arch / C.uc_mode
	//     (passing C.int is a type error).
	//   - the out-param is uc_engine**, so pass &eng for a local *C.uc_engine.
	//     Using &engine.handle would hand C a pointer into the Go struct.
	var eng *C.uc_engine
	if cerr := C.uc_open(C.uc_arch(archX86), C.uc_mode(mode64), &eng); cerr != 0 {
		_ = lib.close()

		return nil, fmt.Errorf("create x86-64 emulator: %w", engine.err(int32(cerr)))
	}
	engine.handle = eng

	if err := configureEngine(engine); err != nil {
		_ = C.uc_close(engine.handle)
		_ = lib.close()

		return nil, err
	}

	runtime.SetFinalizer(engine, func(engine *Engine) {
		_ = engine.Close()
	})

	return engine, nil
}

// uc_mem_map(uc_engine*, uint64_t address, size_t size, uint32_t perms)
// NOTE: `size` is size_t — C.uint64_t is a distinct type on macOS and will not
// type-check.
func (e *Engine) MemMap(address, size uint64) error {
	handle, done, err := e.beginOperation()
	if err != nil {
		return err
	}

	defer done()

	return e.err(int32(C.uc_mem_map(handle, C.uint64_t(address), C.size_t(size), C.uint32_t(protAll))))
}

// uc_mem_unmap(uc_engine*, uint64_t address, size_t size)
func (e *Engine) MemUnmap(address, size uint64) error {
	handle, done, err := e.beginOperation()
	if err != nil {
		return err
	}

	defer done()

	return e.err(int32(C.uc_mem_unmap(handle, C.uint64_t(address), C.size_t(size))))
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

	cerr := C.uc_mem_read(handle, C.uint64_t(address), unsafe.Pointer(&data[0]), C.size_t(size))

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

	return e.err(int32(C.uc_mem_read(handle, C.uint64_t(address), unsafe.Pointer(&data[0]), C.size_t(len(data)))))
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

	return e.err(int32(C.uc_mem_write(handle, C.uint64_t(address), unsafe.Pointer(&data[0]), C.size_t(len(data)))))
}

func (e *Engine) RegRead(register int) (uint64, error) {
	handle, done, err := e.beginOperation()
	if err != nil {
		return 0, err
	}
	defer done()

	var value uint64

	cerr := C.uc_reg_read(handle, C.int(register), unsafe.Pointer(&value))

	return value, e.err(int32(cerr))
}

func (e *Engine) RegWrite(register int, value uint64) error {
	handle, done, err := e.beginOperation()
	if err != nil {
		return err
	}
	defer done()

	return e.err(int32(C.uc_reg_write(handle, C.int(register), unsafe.Pointer(&value))))
}

func (e *Engine) Start(begin, end uint64) error {
	handle, done, err := e.beginOperation()
	if err != nil {
		return err
	}
	defer done()

	return e.err(int32(C.uc_emu_start(handle, C.uint64_t(begin), C.uint64_t(end), 0, 0)))
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

	if cerr := C.uc_emu_start(handle, C.uint64_t(begin), C.uint64_t(end), C.uint64_t(microseconds), C.size_t(instructionLimit)); cerr != 0 {
		return e.err(int32(cerr))
	}

	var timedOut uint64
	if cerr := C.sap_uc_query(handle, C.int(queryTimeout), (*C.uint64_t)(unsafe.Pointer(&timedOut))); cerr != 0 {
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

	return e.err(int32(C.uc_emu_stop(handle)))
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
	e.handle = nil
	e.library = library{}
	e.stateMu.Unlock()

	var errs []error

	if handle != nil {
		if cerr := C.uc_close(handle); cerr != 0 {
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

func (e *Engine) beginOperation() (*C.uc_engine, func(), error) {
	if e == nil {
		return nil, nil, errEngineClosed
	}

	e.stateMu.Lock()
	defer e.stateMu.Unlock()

	if e.closing || e.handle == nil {
		return nil, nil, errEngineClosed
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
