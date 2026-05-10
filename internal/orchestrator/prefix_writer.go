package orchestrator

import (
	"bytes"
	"io"
	"sync"
)

// prefixWriter prefixes every line written through it with a fixed
// byte slice and forwards to an underlying writer. Used to label
// each service's stdout/stderr in `pkf up` so the user can tell
// which `node ...` line came from which service when the dev stack
// runs db + api + web concurrently.
//
// Partial lines are buffered until the trailing newline arrives, so
// a `printf("hello")` followed by `printf(" world\n")` shows up as
// `[svc] hello world` in one piece.
type prefixWriter struct {
	prefix []byte
	w      io.Writer
	mu     sync.Mutex
	buf    []byte
}

func newPrefixWriter(prefix string, w io.Writer) *prefixWriter {
	return &prefixWriter{prefix: []byte(prefix), w: w}
}

func (p *prefixWriter) Write(b []byte) (int, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.buf = append(p.buf, b...)
	for {
		i := bytes.IndexByte(p.buf, '\n')
		if i < 0 {
			break
		}
		if _, err := p.w.Write(p.prefix); err != nil {
			return 0, err
		}
		if _, err := p.w.Write(p.buf[:i+1]); err != nil {
			return 0, err
		}
		p.buf = p.buf[i+1:]
	}
	return len(b), nil
}

// flush writes any buffered partial line, with a synthesized newline
// so the prefix-followed-by-text invariant holds. Called when the
// service exits so its final, possibly newline-less, log line is not
// dropped.
func (p *prefixWriter) flush() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if len(p.buf) == 0 {
		return nil
	}
	if _, err := p.w.Write(p.prefix); err != nil {
		return err
	}
	if _, err := p.w.Write(p.buf); err != nil {
		return err
	}
	if _, err := p.w.Write([]byte{'\n'}); err != nil {
		return err
	}
	p.buf = p.buf[:0]
	return nil
}
