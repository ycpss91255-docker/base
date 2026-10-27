package main

// Typed subset of base's setup.toml schema (dist/setup.toml). Every field
// is a pointer so a layer that does not mention a key (nil) stays distinct
// from a layer that sets it to its zero value ("" / false / 0 / []).

type Config struct {
	Project     *Project           `toml:"project" json:"project,omitempty"`
	Image       *Image             `toml:"image" json:"image,omitempty"`
	Build       *Build             `toml:"build" json:"build,omitempty"`
	Deploy      *Deploy            `toml:"deploy" json:"deploy,omitempty"`
	Lifecycle   *Lifecycle         `toml:"lifecycle" json:"lifecycle,omitempty"`
	GUI         *GUI               `toml:"gui" json:"gui,omitempty"`
	Network     *Network           `toml:"network" json:"network,omitempty"`
	Security    *Security          `toml:"security" json:"security,omitempty"`
	Resources   *Resources         `toml:"resources" json:"resources,omitempty"`
	Environment *map[string]string `toml:"environment" json:"environment,omitempty"`
	Logging     *Logging           `toml:"logging" json:"logging,omitempty"`
	Volumes     *[]Volume          `toml:"volumes" json:"volumes,omitempty"`
}

type Project struct {
	Name *string `toml:"name" json:"name,omitempty"`
}

type Image struct {
	Rules *[]ImageRule `toml:"rules" json:"rules,omitempty"`
}

type ImageRule struct {
	Rule *string `toml:"rule" json:"rule,omitempty"`
}

type Build struct {
	TargetArch *string     `toml:"target_arch" json:"target_arch,omitempty"`
	Network    *string     `toml:"network" json:"network,omitempty"`
	Args       *[]BuildArg `toml:"args" json:"args,omitempty"`
}

type BuildArg struct {
	Key   *string `toml:"key" json:"key,omitempty"`
	Value *string `toml:"value" json:"value,omitempty"`
}

type Deploy struct {
	GPUMode         *string `toml:"gpu_mode" json:"gpu_mode,omitempty"`
	GPUCount        *string `toml:"gpu_count" json:"gpu_count,omitempty"`
	GPUCapabilities *string `toml:"gpu_capabilities" json:"gpu_capabilities,omitempty"`
	GPURuntime      *string `toml:"gpu_runtime" json:"gpu_runtime,omitempty"`
	DRIGroups       *string `toml:"dri_groups" json:"dri_groups,omitempty"`
}

type Lifecycle struct {
	Restart *string `toml:"restart" json:"restart,omitempty"`
	Init    *bool   `toml:"init" json:"init,omitempty"`
}

type GUI struct {
	Mode *string `toml:"mode" json:"mode,omitempty"`
}

type Network struct {
	Mode        *string `toml:"mode" json:"mode,omitempty"`
	IPC         *string `toml:"ipc" json:"ipc,omitempty"`
	PID         *string `toml:"pid" json:"pid,omitempty"`
	NetworkName *string `toml:"network_name" json:"network_name,omitempty"`
	Ports       *[]Port `toml:"ports" json:"ports,omitempty"`
}

type Port struct {
	Host      *int64 `toml:"host" json:"host,omitempty"`
	Container *int64 `toml:"container" json:"container,omitempty"`
}

type Security struct {
	Privileged *bool  `toml:"privileged" json:"privileged,omitempty"`
	CapAdd     *[]Cap `toml:"cap_add" json:"cap_add,omitempty"`
}

type Cap struct {
	Cap *string `toml:"cap" json:"cap,omitempty"`
}

type Resources struct {
	ShmSize *string `toml:"shm_size" json:"shm_size,omitempty"`
}

type Logging struct {
	Driver           *string `toml:"driver" json:"driver,omitempty"`
	MaxSize          *string `toml:"max_size" json:"max_size,omitempty"`
	MaxFile          *int64  `toml:"max_file" json:"max_file,omitempty"`
	Compress         *bool   `toml:"compress" json:"compress,omitempty"`
	LocalPath        *string `toml:"local_path" json:"local_path,omitempty"`
	ContainerLogKeep *int64  `toml:"container_log_keep" json:"container_log_keep,omitempty"`
	ContainerLogDays *int64  `toml:"container_log_days" json:"container_log_days,omitempty"`
	Transcript       *bool   `toml:"wrapper_transcript" json:"wrapper_transcript,omitempty"`
	TranscriptKeep   *int64  `toml:"wrapper_transcript_keep" json:"wrapper_transcript_keep,omitempty"`
	TranscriptDays   *int64  `toml:"wrapper_transcript_days" json:"wrapper_transcript_days,omitempty"`
}

type Volume struct {
	Source *string `toml:"source" json:"source,omitempty"`
	Target *string `toml:"target" json:"target,omitempty"`
	Mode   *string `toml:"mode" json:"mode,omitempty"`
}
