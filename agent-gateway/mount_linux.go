//go:build linux

package main

import "syscall"

// sysMount wraps syscall.Mount (only available on Linux).
func sysMount(source, target, fstype string) error {
	return syscall.Mount(source, target, fstype, 0, "")
}

// sysProcAttrForDeveloper returns SysProcAttr that spawns the process
// inside a user namespace with full UID/GID mapping (Sysbox/Podman model).
//
// The process runs as UID 1000 (developer) but has all capabilities
// within the namespace. This means ANY package manager (apt-get, pip,
// npm, cargo, gem, go, etc.) can install to system directories without
// sudo, wrappers, or per-tool configuration.
//
// Security: the microVM (libkrun hypervisor) is the security boundary.
// Capabilities inside the user namespace are scoped to the VM.
func sysProcAttrForDeveloper() *syscall.SysProcAttr {
	return &syscall.SysProcAttr{
		Cloneflags: syscall.CLONE_NEWUSER,
		UidMappings: []syscall.SysProcIDMap{
			{ContainerID: 0, HostID: 0, Size: 65536},
		},
		GidMappings: []syscall.SysProcIDMap{
			{ContainerID: 0, HostID: 0, Size: 65536},
		},
		Credential: &syscall.Credential{
			Uid: 1000,
			Gid: 1000,
		},
	}
}
