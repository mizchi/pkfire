//go:build unix

// Process-group lifecycle helpers used by Runner to clean up grandchildren
// when a task's context is cancelled. Without this, `bash -c "node …"`
// would leak the node child after pkf SIGTERMs the bash parent — a real
// problem for `pkf up`-style long-running services.
package runner

import (
	"os/exec"
	"syscall"
)

// setProcessGroup makes cmd a process-group leader so a single signal to
// the negative pgid reaches every descendant.
func setProcessGroup(cmd *exec.Cmd) {
	if cmd.SysProcAttr == nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{}
	}
	cmd.SysProcAttr.Setpgid = true
}

// terminateProcessGroup sends SIGTERM to every process in pid's group.
// pid is the leader's pid (which equals its pgid because of Setpgid).
func terminateProcessGroup(pid int) error {
	return syscall.Kill(-pid, syscall.SIGTERM)
}

// killProcessGroup escalates to SIGKILL after the SIGTERM grace period.
func killProcessGroup(pid int) error {
	return syscall.Kill(-pid, syscall.SIGKILL)
}
