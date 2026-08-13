package api

import "time"

const Version = "1"

const (
	MethodPing                    = "ping"
	MethodVersion                 = "version"
	MethodEngineSync              = "engine.sync"
	MethodImagePull               = "image.pull"
	MethodImageList               = "image.list"
	MethodImageInspect            = "image.inspect"
	MethodImageDelete             = "image.delete"
	MethodImagePrune              = "image.prune"
	MethodImageTag                = "image.tag"
	MethodContainerList           = "container.list"
	MethodContainerInspect        = "container.inspect"
	MethodContainerLogs           = "container.logs"
	MethodContainerCreate         = "container.create"
	MethodContainerStart          = "container.start"
	MethodContainerWait           = "container.wait"
	MethodContainerKill           = "container.kill"
	MethodContainerDelete         = "container.delete"
	MethodContainerExec           = "container.exec"
	MethodContainerAttach         = "container.attach"
	MethodContainerMetadataUpdate = "container.metadata.update"
	MethodBindInvalidate          = "bind.invalidate"
	EventContainerExit            = "container.exit"
	EventBindWriteBarrier         = "bind.write.barrier"
)

type ImagePullRequest struct {
	Reference   string `json:"reference"`
	Snapshotter string `json:"snapshotter,omitempty"`
	Platform    string `json:"platform,omitempty"`
	Username    string `json:"username,omitempty"`
	Secret      string `json:"secret,omitempty"`
}
type ImageResponse struct {
	Name   string `json:"name"`
	Digest string `json:"digest"`
}
type ImageRequest struct {
	Reference string `json:"reference"`
}
type ImageDeleteRequest struct {
	Reference string `json:"reference"`
	Force     bool   `json:"force,omitempty"`
}
type ImagePruneRequest struct {
	All bool `json:"all,omitempty"`
}
type ImageTagRequest struct {
	Source string `json:"source"`
	Target string `json:"target"`
}
type Image struct {
	ID           string            `json:"id"`
	Digest       string            `json:"digest"`
	References   []string          `json:"references"`
	CreatedAt    time.Time         `json:"createdAt"`
	Size         int64             `json:"size"`
	Labels       map[string]string `json:"labels,omitempty"`
	RootFSLayers []string          `json:"rootfsLayers,omitempty"`
}
type ImageListResponse struct {
	Images []Image `json:"images"`
}
type ImageDeleteResponse struct {
	Deleted   []string `json:"deleted,omitempty"`
	Untagged  []string `json:"untagged,omitempty"`
	Reclaimed int64    `json:"reclaimed,omitempty"`
}

type Empty struct{}
type BindInvalidateRequest struct {
	Paths     []string `json:"paths,omitempty"`
	All       bool     `json:"all,omitempty"`
	BarrierID string   `json:"barrierId,omitempty"`
}
type BindWriteBarrierEvent struct {
	BarrierID string   `json:"barrierId"`
	Paths     []string `json:"paths"`
}
type PingResponse struct {
	OK bool `json:"ok"`
}
type VersionResponse struct {
	Protocol   string `json:"protocol"`
	Agent      string `json:"agent"`
	Containerd string `json:"containerd"`
}
type IDRequest struct {
	ID string `json:"id"`
}
type PublishedPort struct {
	ContainerPort uint16 `json:"containerPort"`
	GuestPort     uint16 `json:"guestPort,omitempty"`
	Protocol      string `json:"protocol,omitempty"`
	HostSource    string `json:"hostSource,omitempty"`
}
type ContainerKillRequest struct {
	ID     string `json:"id"`
	Signal uint32 `json:"signal,omitempty"`
}
type ContainerCreateRequest struct {
	ID             string            `json:"id"`
	Image          string            `json:"image"`
	Args           []string          `json:"args,omitempty"`
	Entrypoint     *[]string         `json:"entrypoint,omitempty"`
	Cmd            *[]string         `json:"cmd,omitempty"`
	Env            []string          `json:"env,omitempty"`
	Cwd            string            `json:"cwd,omitempty"`
	User           string            `json:"user,omitempty"`
	Labels         map[string]string `json:"labels,omitempty"`
	Hostname       string            `json:"hostname,omitempty"`
	ReadonlyRootfs bool              `json:"readonlyRootfs,omitempty"`
	Mounts         []Mount           `json:"mounts,omitempty"`
	Network        Network           `json:"network,omitempty"`
	PublishedPorts []PublishedPort   `json:"publishedPorts,omitempty"`
	AutoRemove     bool              `json:"autoRemove,omitempty"`
	Snapshotter    string            `json:"snapshotter,omitempty"`
	Runtime        string            `json:"runtime,omitempty"`
	RuntimeBinary  string            `json:"runtimeBinary,omitempty"`
	Metadata       ContainerMetadata `json:"metadata,omitempty"`
}

type ContainerStartRequest struct {
	ID             string          `json:"id"`
	PublishedPorts []PublishedPort `json:"publishedPorts,omitempty"`
}

type DockerPortBinding struct {
	ContainerPort uint16  `json:"containerPort"`
	Protocol      string  `json:"protocol,omitempty"`
	HostIP        string  `json:"hostIP,omitempty"`
	HostPort      *uint16 `json:"hostPort,omitempty"`
}

type ContainerMetadata struct {
	Name           string              `json:"name,omitempty"`
	Args           []string            `json:"args,omitempty"`
	Labels         map[string]string   `json:"labels,omitempty"`
	Terminal       bool                `json:"terminal,omitempty"`
	AutoRemove     bool                `json:"autoRemove,omitempty"`
	PortBindings   []DockerPortBinding `json:"portBindings,omitempty"`
	PublishedPorts []PublishedPort     `json:"publishedPorts,omitempty"`
	LifecycleState string              `json:"lifecycleState,omitempty"`
	LastExitCode   *uint32             `json:"lastExitCode,omitempty"`
}
type ContainerMetadataUpdateRequest struct {
	ID           string              `json:"id"`
	PortBindings []DockerPortBinding `json:"portBindings"`
}

// Mount maps directly to an OCI mount. Supported types are bind, tmpfs,
// proc, sysfs, devpts, and mqueue. A bind mount requires an absolute source.
type Mount struct {
	Source   string   `json:"source,omitempty"`
	Target   string   `json:"target"`
	Type     string   `json:"type"`
	Readonly bool     `json:"readonly,omitempty"`
	Options  []string `json:"options,omitempty"`
}

// Network selects the network namespace. Mode is host, private, or path.
// The path field is required only for path mode.
type Network struct {
	Mode string `json:"mode,omitempty"`
	Path string `json:"path,omitempty"`
}
type ContainerDeleteRequest struct {
	ID       string `json:"id"`
	Force    bool   `json:"force,omitempty"`
	Snapshot bool   `json:"snapshot,omitempty"`
}
type ContainerLogsRequest struct {
	ID     string `json:"id"`
	Stdout bool   `json:"stdout,omitempty"`
	Stderr bool   `json:"stderr,omitempty"`
}
type ContainerLogsResponse struct {
	Stdout    []byte `json:"stdout,omitempty"`
	Stderr    []byte `json:"stderr,omitempty"`
	Truncated bool   `json:"truncated,omitempty"`
}
type ContainerExecRequest struct {
	ID       string   `json:"id"`
	ExecID   string   `json:"execId"`
	Args     []string `json:"args"`
	Env      []string `json:"env,omitempty"`
	Cwd      string   `json:"cwd,omitempty"`
	User     string   `json:"user,omitempty"`
	Terminal bool     `json:"terminal,omitempty"`
}
type Container struct {
	ID             string            `json:"id"`
	Image          string            `json:"image"`
	Status         string            `json:"status"`
	PID            uint32            `json:"pid,omitempty"`
	ExitCode       *uint32           `json:"exitCode,omitempty"`
	CreatedAt      time.Time         `json:"createdAt"`
	PublishedPorts []PublishedPort   `json:"publishedPorts,omitempty"`
	Metadata       ContainerMetadata `json:"metadata,omitempty"`
}
type ContainerListResponse struct {
	Containers []Container `json:"containers"`
}
type ContainerResponse struct {
	Container Container `json:"container"`
}
type ContainerExitEvent struct {
	ID       string    `json:"id"`
	ExitCode uint32    `json:"exitCode"`
	ExitedAt time.Time `json:"exitedAt"`
}
