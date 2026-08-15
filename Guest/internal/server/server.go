package server

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/glassdock/glassdock/guest/internal/api"
	"github.com/glassdock/glassdock/guest/internal/backend"
	"github.com/glassdock/glassdock/guest/internal/protocol"
)

type Server struct {
	backend      *backend.Backend
	agentVersion string
	waitsMu      sync.Mutex
	waits        map[string]*exitWait
}

type exitWait struct {
	done     chan struct{}
	code     uint32
	exitedAt time.Time
	err      error
}

func New(b *backend.Backend, version string) *Server {
	return &Server{backend: b, agentVersion: version, waits: make(map[string]*exitWait)}
}

func (s *Server) registerWait(id string) *exitWait {
	state := &exitWait{done: make(chan struct{})}
	s.waitsMu.Lock()
	s.waits[id] = state
	s.waitsMu.Unlock()
	return state
}

func (s *Server) monitor(ctx context.Context, id string, state *exitWait, w *protocol.Writer) {
	go func() {
		state.code, state.exitedAt, state.err = s.backend.Wait(ctx, id)
		close(state.done)
		s.waitsMu.Lock()
		if s.waits[id] == state {
			delete(s.waits, id)
		}
		s.waitsMu.Unlock()
		if state.err != nil {
			return
		}
		payload, _ := protocol.NewPayload(api.ContainerExitEvent{ID: id, ExitCode: state.code, ExitedAt: state.exitedAt})
		_ = w.Write(protocol.Envelope{ID: 0, Kind: protocol.KindEvent, Method: api.EventContainerExit, Payload: payload})
	}()
}

func (s *Server) wait(ctx context.Context, id string) (uint32, time.Time, error) {
	s.waitsMu.Lock()
	state := s.waits[id]
	s.waitsMu.Unlock()
	if state == nil {
		return s.backend.Wait(ctx, id)
	}
	select {
	case <-ctx.Done():
		return 0, time.Time{}, ctx.Err()
	case <-state.done:
		return state.code, state.exitedAt, state.err
	}
}

func (s *Server) Serve(ctx context.Context, listener net.Listener) error {
	go func() { <-ctx.Done(); _ = listener.Close() }()
	for {
		conn, err := listener.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		go s.serveConnection(ctx, conn)
	}
}

func (s *Server) serveConnection(ctx context.Context, conn net.Conn) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	defer conn.Close()
	r, w := protocol.NewReader(conn), protocol.NewWriter(conn)
	inFlight := make(chan struct{}, 256)
	var requestMu sync.Mutex
	requestCancels := make(map[uint64]context.CancelFunc)
	for {
		request, err := r.Read()
		if err != nil {
			if !errors.Is(err, io.EOF) {
				_ = writeError(w, 1, "bad_frame", err)
			}
			return
		}
		if request.Kind == protocol.KindCancel {
			requestMu.Lock()
			cancel := requestCancels[request.ID]
			requestMu.Unlock()
			if cancel != nil {
				cancel()
			}
			continue
		}
		select {
		case inFlight <- struct{}{}:
		default:
			_ = writeError(w, request.ID, "too_many_requests", errors.New("connection request limit reached"))
			continue
		}
		requestCtx, requestCancel := context.WithCancel(ctx)
		requestMu.Lock()
		requestCancels[request.ID] = requestCancel
		requestMu.Unlock()
		go func() {
			defer func() { <-inFlight }()
			defer requestCancel()
			defer func() {
				requestMu.Lock()
				delete(requestCancels, request.ID)
				requestMu.Unlock()
			}()
			s.handle(requestCtx, request, w)
		}()
	}
}

func decode[T any](request protocol.Envelope) (T, error) {
	var value T
	if len(request.Payload) == 0 {
		return value, nil
	}
	err := json.Unmarshal(request.Payload, &value)
	return value, err
}
func writePayload(w *protocol.Writer, id uint64, value any) error {
	p, err := protocol.NewPayload(value)
	if err != nil {
		return err
	}
	return w.Write(protocol.Envelope{ID: id, Kind: protocol.KindResponse, Payload: p})
}
func writeError(w *protocol.Writer, id uint64, code string, err error) error {
	return w.Write(protocol.Envelope{ID: id, Kind: protocol.KindResponse, Error: &protocol.Error{Code: code, Message: err.Error()}})
}

func (s *Server) handle(ctx context.Context, request protocol.Envelope, w *protocol.Writer) {
	fail := func(code string, err error) { _ = writeError(w, request.ID, code, err) }
	switch request.Method {
	case api.MethodPing:
		_ = writePayload(w, request.ID, api.PingResponse{OK: true})
	case api.MethodVersion:
		version, err := s.backend.Version(ctx)
		if err != nil {
			fail("containerd", err)
			return
		}
		_ = writePayload(w, request.ID, api.VersionResponse{Protocol: api.Version, Agent: s.agentVersion, Containerd: version})
	case api.MethodEngineSync:
		syscall.Sync()
		_ = writePayload(w, request.ID, api.Empty{})
	case api.MethodImagePull:
		body, err := decode[api.ImagePullRequest](request)
		if err != nil {
			fail("invalid_argument", err)
			return
		}
		image, err := s.backend.Pull(ctx, body)
		if err != nil {
			fail("containerd", err)
			return
		}
		syscall.Sync()
		_ = writePayload(w, request.ID, image)
	case api.MethodImageList:
		items, err := s.backend.Images(ctx)
		if err != nil {
			fail("containerd", err)
			return
		}
		_ = writePayload(w, request.ID, api.ImageListResponse{Images: items})
	case api.MethodImageInspect:
		body, err := decode[api.ImageRequest](request)
		if err != nil {
			fail("invalid_argument", err)
			return
		}
		image, err := s.backend.Image(ctx, body.Reference)
		if err != nil {
			fail("not_found", err)
			return
		}
		_ = writePayload(w, request.ID, image)
	case api.MethodImageDelete:
		body, err := decode[api.ImageDeleteRequest](request)
		if err != nil {
			fail("invalid_argument", err)
			return
		}
		result, err := s.backend.DeleteImage(ctx, body)
		if err != nil {
			fail("containerd", err)
			return
		}
		syscall.Sync()
		_ = writePayload(w, request.ID, result)
	case api.MethodImagePrune:
		body, err := decode[api.ImagePruneRequest](request)
		if err != nil {
			fail("invalid_argument", err)
			return
		}
		result, err := s.backend.PruneImages(ctx, body)
		if err != nil {
			fail("containerd", err)
			return
		}
		syscall.Sync()
		_ = writePayload(w, request.ID, result)
	case api.MethodImageTag:
		body, err := decode[api.ImageTagRequest](request)
		if err != nil {
			fail("invalid_argument", err)
			return
		}
		image, err := s.backend.TagImage(ctx, body)
		if err != nil {
			fail("containerd", err)
			return
		}
		syscall.Sync()
		_ = writePayload(w, request.ID, image)
	case api.MethodContainerList:
		items, err := s.backend.List(ctx)
		if err != nil {
			fail("containerd", err)
			return
		}
		_ = writePayload(w, request.ID, api.ContainerListResponse{Containers: items})
	case api.MethodContainerInspect:
		body, err := decode[api.IDRequest](request)
		if err != nil {
			fail("invalid_argument", err)
			return
		}
		item, err := s.backend.Inspect(ctx, body.ID)
		if err != nil {
			fail("containerd", err)
			return
		}
		_ = writePayload(w, request.ID, api.ContainerResponse{Container: item})
	case api.MethodContainerLogs:
		body, err := decode[api.ContainerLogsRequest](request)
		if err != nil {
			fail("invalid_argument", err)
			return
		}
		logs, err := s.backend.Logs(body)
		if err != nil {
			fail("containerd", err)
			return
		}
		_ = writePayload(w, request.ID, logs)
	case api.MethodContainerCreate:
		body, err := decode[api.ContainerCreateRequest](request)
		if err != nil {
			fail("invalid_argument", err)
			return
		}
		item, err := s.backend.Create(ctx, body)
		if err != nil {
			fail("containerd", err)
			return
		}
		_ = writePayload(w, request.ID, api.ContainerResponse{Container: item})
	case api.MethodContainerStart:
		body, err := decode[api.ContainerStartRequest](request)
		if err != nil {
			fail("invalid_argument", err)
			return
		}
		item, err := s.backend.Start(ctx, body)
		if err != nil {
			fail("containerd", err)
			return
		}
		syscall.Sync()
		state := s.registerWait(body.ID)
		_ = writePayload(w, request.ID, api.ContainerResponse{Container: item})
		s.monitor(context.Background(), body.ID, state, w)
	case api.MethodContainerWait:
		body, err := decode[api.IDRequest](request)
		if err != nil {
			fail("invalid_argument", err)
			return
		}
		code, exitedAt, err := s.wait(ctx, body.ID)
		if err != nil {
			fail("containerd", err)
			return
		}
		exitCode := int32(code)
		payload, _ := protocol.NewPayload(api.ContainerExitEvent{ID: body.ID, ExitCode: code, ExitedAt: exitedAt})
		_ = w.Write(protocol.Envelope{ID: request.ID, Kind: protocol.KindEnd, Payload: payload, ExitCode: &exitCode})
	case api.MethodContainerKill:
		body, err := decode[api.ContainerKillRequest](request)
		if err != nil {
			fail("invalid_argument", err)
			return
		}
		if err := s.backend.Kill(ctx, body.ID, body.Signal); err != nil {
			fail("containerd", err)
			return
		}
		_ = writePayload(w, request.ID, api.Empty{})
	case api.MethodContainerMetadataUpdate:
		body, err := decode[api.ContainerMetadataUpdateRequest](request)
		if err != nil {
			fail("invalid_argument", err)
			return
		}
		if err := s.backend.UpdateContainerMetadata(ctx, body); err != nil {
			fail("containerd", err)
			return
		}
		syscall.Sync()
		_ = writePayload(w, request.ID, api.Empty{})
	case api.MethodContainerDelete:
		body, err := decode[api.ContainerDeleteRequest](request)
		if err != nil {
			fail("invalid_argument", err)
			return
		}
		if err := s.backend.Delete(ctx, body); err != nil {
			fail("containerd", err)
			return
		}
		syscall.Sync()
		_ = writePayload(w, request.ID, api.Empty{})
	case api.MethodContainerExec:
		body, err := decode[api.ContainerExecRequest](request)
		if err != nil {
			fail("invalid_argument", err)
			return
		}
		code, err := s.backend.Exec(ctx, body, func(name string, data []byte) error {
			return w.Write(protocol.Envelope{ID: request.ID, Kind: protocol.KindStream, Stream: protocol.Stream(name), Data: data})
		})
		if err != nil {
			fail("containerd", err)
			return
		}
		_ = w.Write(protocol.Envelope{ID: request.ID, Kind: protocol.KindEnd, ExitCode: &code})
	case api.MethodContainerAttach:
		body, err := decode[api.ContainerLogsRequest](request)
		if err != nil {
			fail("invalid_argument", err)
			return
		}
		code, err := s.backend.Attach(ctx, body, func(name string, data []byte) error {
			return w.Write(protocol.Envelope{ID: request.ID, Kind: protocol.KindStream, Stream: protocol.Stream(name), Data: data})
		})
		if err != nil {
			fail("containerd", err)
			return
		}
		exitCode := int32(code)
		_ = w.Write(protocol.Envelope{ID: request.ID, Kind: protocol.KindEnd, ExitCode: &exitCode})
	default:
		fail("unknown_method", errors.New("unknown method "+strings.TrimSpace(request.Method)))
	}
}
