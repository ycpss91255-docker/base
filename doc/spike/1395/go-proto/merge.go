package main

// Layered merge per ADR-37: scalar keys merge key by key, an
// array-of-tables replaces whole, [environment] merges key by key.
// A nil pointer (absent) inherits; a non-nil pointer to "" / [] overrides.

func pick[T any](lo, hi *T) *T {
	if hi != nil {
		return hi
	}
	return lo
}

// sub merges two optional tables with f, allocating only when needed.
func sub[T any](lo, hi *T, f func(lo, hi *T) *T) *T {
	if lo == nil {
		return hi
	}
	if hi == nil {
		return lo
	}
	return f(lo, hi)
}

func merge(lo, hi *Config) *Config {
	out := &Config{}
	out.Project = sub(lo.Project, hi.Project, func(a, b *Project) *Project {
		return &Project{Name: pick(a.Name, b.Name)}
	})
	out.Image = sub(lo.Image, hi.Image, func(a, b *Image) *Image {
		return &Image{Rules: pick(a.Rules, b.Rules)}
	})
	out.Build = sub(lo.Build, hi.Build, func(a, b *Build) *Build {
		return &Build{TargetArch: pick(a.TargetArch, b.TargetArch), Network: pick(a.Network, b.Network), Args: pick(a.Args, b.Args)}
	})
	out.Deploy = sub(lo.Deploy, hi.Deploy, func(a, b *Deploy) *Deploy {
		return &Deploy{GPUMode: pick(a.GPUMode, b.GPUMode), GPUCount: pick(a.GPUCount, b.GPUCount),
			GPUCapabilities: pick(a.GPUCapabilities, b.GPUCapabilities), GPURuntime: pick(a.GPURuntime, b.GPURuntime),
			DRIGroups: pick(a.DRIGroups, b.DRIGroups)}
	})
	out.Lifecycle = sub(lo.Lifecycle, hi.Lifecycle, func(a, b *Lifecycle) *Lifecycle {
		return &Lifecycle{Restart: pick(a.Restart, b.Restart), Init: pick(a.Init, b.Init)}
	})
	out.GUI = sub(lo.GUI, hi.GUI, func(a, b *GUI) *GUI { return &GUI{Mode: pick(a.Mode, b.Mode)} })
	out.Network = sub(lo.Network, hi.Network, func(a, b *Network) *Network {
		return &Network{Mode: pick(a.Mode, b.Mode), IPC: pick(a.IPC, b.IPC), PID: pick(a.PID, b.PID),
			NetworkName: pick(a.NetworkName, b.NetworkName), Ports: pick(a.Ports, b.Ports)}
	})
	out.Security = sub(lo.Security, hi.Security, func(a, b *Security) *Security {
		return &Security{Privileged: pick(a.Privileged, b.Privileged), CapAdd: pick(a.CapAdd, b.CapAdd)}
	})
	out.Resources = sub(lo.Resources, hi.Resources, func(a, b *Resources) *Resources {
		return &Resources{ShmSize: pick(a.ShmSize, b.ShmSize)}
	})
	out.Logging = sub(lo.Logging, hi.Logging, func(a, b *Logging) *Logging {
		return &Logging{Driver: pick(a.Driver, b.Driver), MaxSize: pick(a.MaxSize, b.MaxSize),
			MaxFile: pick(a.MaxFile, b.MaxFile), Compress: pick(a.Compress, b.Compress),
			LocalPath: pick(a.LocalPath, b.LocalPath), ContainerLogKeep: pick(a.ContainerLogKeep, b.ContainerLogKeep),
			ContainerLogDays: pick(a.ContainerLogDays, b.ContainerLogDays), Transcript: pick(a.Transcript, b.Transcript),
			TranscriptKeep: pick(a.TranscriptKeep, b.TranscriptKeep), TranscriptDays: pick(a.TranscriptDays, b.TranscriptDays)}
	})
	out.Volumes = pick(lo.Volumes, hi.Volumes)
	// An explicit empty [environment] is kept (non-nil, empty) so get can
	// tell it from an absent table, matching toml-bridge's {}.
	if lo.Environment != nil || hi.Environment != nil {
		env := map[string]string{}
		for _, layer := range []*map[string]string{lo.Environment, hi.Environment} {
			if layer != nil {
				for k, v := range *layer {
					env[k] = v
				}
			}
		}
		out.Environment = &env
	}
	return out
}
